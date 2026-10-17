import Foundation

/// Collects new lines from the on-device log, keeps them in a durable queue, and sends them in numbered batches.
///
/// Everything outside the engine is injected: the clock, the disk (`DiagnosticsStateStore`) and the network
/// (`DiagnosticsTransport`). The engine never reads a wall clock, never opens a socket and never touches UIKit, so
/// the whole failure matrix runs in plain unit tests.
///
/// Delivery rules:
/// - **Nothing leaves while the gate is closed**, and closing it (toggle off, endpoint removed or unacknowledged)
///   deletes the queue and every other trace of progress.
/// - **A log line is queued once.** Lines are identified by a hash of their text (see ``DiagnosticsLogParser``), kept
///   in a bounded `seen` list, so rewriting or trimming the log changes nothing.
/// - **A batch is sealed before its first send** with an id and a sequence number, and that exact batch is resent
///   until the server answers with a 2xx (or 409, "already have it"). The id doubles as the `Idempotency-Key`.
///   Events leave the disk only on that answer, so a kill mid-send loses nothing.
/// - **Failures back off** (30 s doubling to 15 min) and the wait is persisted, so a relaunch honors it.
/// - **A wrong key or a missing route stops the uploader** instead of retrying until the battery notices.
actor DiagnosticsUploadEngine {
    private let store: any DiagnosticsStateStore
    private let transport: any DiagnosticsTransport
    private let clock: any DiagnosticsClock
    private let deviceInfo: @Sendable () -> DiagnosticsDeviceInfo
    private let config: DiagnosticsEngineConfig

    private var state: DiagnosticsUploadState?
    private var isRunning = false

    init(
        store: any DiagnosticsStateStore,
        transport: any DiagnosticsTransport,
        clock: any DiagnosticsClock,
        deviceInfo: @escaping @Sendable () -> DiagnosticsDeviceInfo,
        config: DiagnosticsEngineConfig = .standard
    ) {
        self.store = store
        self.transport = transport
        self.clock = clock
        self.deviceInfo = deviceInfo
        self.config = config
        state = store.load()
    }

    // MARK: Entry points

    /// One pass: check the gate, collect new log lines, and send what is queued.
    ///
    /// `backfill` is the Send now button: it also queues the lines that were already in the log when diagnostics was
    /// switched on (the ones not yet sent), and it ignores a backoff or a stopped state for this one attempt.
    func run(
        settings: DiagnosticsRunSettings,
        logText: String,
        trigger: DiagnosticsFlushTrigger,
        backfill: Bool = false
    ) async -> DiagnosticsFlushReport {
        let decision = DiagnosticsGate.decide(
            enabled: settings.enabled,
            endpointHost: settings.endpoint?.host,
            endpointLooksPrivate: settings.endpoint?.looksPrivate ?? false,
            acknowledgedHost: settings.acknowledgedHost
        )
        if case .blocked(let reason) = decision {
            disableAndClear()
            return .blocked(reason)
        }
        guard let endpoint = settings.endpoint, !isRunning else { return .idle }
        isRunning = true
        defer { isRunning = false }

        let now = clock.now()
        let parsed = DiagnosticsLogParser.parse(logText)
        var next = state ?? DiagnosticsUploadState()
        applyTarget(to: &next, endpoint: endpoint, parsed: parsed)
        collect(into: &next, parsed: parsed, backfill: backfill, now: now)
        prune(&next, now: now)
        commit(next)
        return await flush(trigger: trigger, force: backfill)
    }

    /// Toggle off, endpoint removed, or a public endpoint nobody acknowledged: forget everything. Does nothing, and
    /// writes nothing, when there was nothing.
    func disableAndClear() {
        guard state != nil else { return }
        state = nil
        store.clear()
    }

    /// "Reset device id": events queued under the old id do not follow the new one, and the sequence starts over.
    /// The seen list stays, so the old log is not queued again under the new id.
    func resetIdentity() {
        guard var next = state else { return }
        next.queue = []
        next.inFlight = nil
        next.nextSeq = 1
        next.droppedEvents = 0
        next.droppedFields = 0
        next.rejectedEvents = 0
        next.failures = 0
        next.retryNotBefore = nil
        next.stopped = nil
        next.lastError = nil
        commit(next)
    }

    func status() -> DiagnosticsUploadStatus {
        let current = state ?? DiagnosticsUploadState()
        return DiagnosticsUploadStatus(
            queuedEvents: current.queue.count + (current.inFlight?.events.count ?? 0),
            lastUploadAt: current.lastUploadAt,
            stopped: current.stopped,
            lastError: current.lastError,
            retryNotBefore: current.retryNotBefore
        )
    }

    // MARK: Target

    /// First run: start from now. A new endpoint: the queue was gathered for another server and is discarded, and
    /// the log is not backfilled. A new key at the same endpoint: keep the queue, lift the stop.
    private func applyTarget(to next: inout DiagnosticsUploadState, endpoint: DiagnosticsEndpoint, parsed: DiagnosticsLogParseResult) {
        let record = DiagnosticsTargetRecord(endpoint: endpoint.url, keyFingerprint: endpoint.keyFingerprint)
        guard let current = next.target else {
            next.target = record
            next.baseline = parsed.lines.map(\.id)
            return
        }
        if current.endpoint != record.endpoint {
            next.queue = []
            next.inFlight = nil
            next.droppedEvents = 0
            next.droppedFields = 0
            next.rejectedEvents = 0
            next.failures = 0
            next.retryNotBefore = nil
            next.stopped = nil
            next.lastError = nil
            next.seen = []
            next.baseline = parsed.lines.map(\.id)
            next.target = record
        } else if current.keyFingerprint != record.keyFingerprint {
            next.failures = 0
            next.retryNotBefore = nil
            next.stopped = nil
            next.lastError = nil
            next.target = record
        }
    }

    // MARK: Collecting

    private func collect(into next: inout DiagnosticsUploadState, parsed: DiagnosticsLogParseResult, backfill: Bool, now: Date) {
        var seen = Set(next.seen)
        let baseline = Set(next.baseline)
        for line in parsed.lines where !seen.contains(line.id) {
            if baseline.contains(line.id), !backfill { continue }
            seen.insert(line.id)
            next.seen.append(line.id)
            let result = DiagnosticsSanitizer.sanitize(line)
            next.droppedFields += result.droppedFields
            guard let event = result.event else {
                next.rejectedEvents += 1
                continue
            }
            let bytes = (try? JSONEncoder().encode(event).count) ?? 0
            next.queue.append(DiagnosticsQueuedEvent(event: event, queuedAt: now, bytes: bytes + 1))
        }
        if next.seen.count > config.seenLimit {
            next.seen.removeFirst(next.seen.count - config.seenLimit)
        }
        // A baseline line that has left the log can never come back.
        let present = Set(parsed.lines.map(\.id))
        let sent = Set(next.seen)
        next.baseline = next.baseline.filter { present.contains($0) && !sent.contains($0) }
    }

    /// Age and size caps. A queue stamp in the future (the clock moved backwards) is young, never old.
    private func prune(_ next: inout DiagnosticsUploadState, now: Date) {
        let expired: (Date) -> Bool = { now.timeIntervalSince($0) > self.config.maxAge }
        if let batch = next.inFlight, expired(batch.sealedAt) {
            next.droppedEvents += batch.events.count + batch.droppedEvents
            next.droppedFields += batch.droppedFields
            next.rejectedEvents += batch.rejectedEvents
            next.inFlight = nil
        }
        let before = next.queue.count
        next.queue.removeAll { expired($0.queuedAt) }
        next.droppedEvents += before - next.queue.count

        var bytes = next.queue.reduce(0) { $0 + $1.bytes } + (next.inFlight?.events.reduce(0) { $0 + $1.bytes } ?? 0)
        var dropped = 0
        while bytes > config.maxQueueBytes, let oldest = next.queue.first {
            bytes -= oldest.bytes
            next.queue.removeFirst()
            dropped += 1
        }
        next.droppedEvents += dropped
    }

    // MARK: Sending

    private func flush(trigger: DiagnosticsFlushTrigger, force: Bool) async -> DiagnosticsFlushReport {
        guard var current = state else { return .idle }
        if force {
            current.stopped = nil
            current.retryNotBefore = nil
            commit(current)
        } else if let stopped = current.stopped {
            return .stopped(stopped)
        }

        var batches = 0
        var events = 0
        while batches < config.maxBatchesPerFlush {
            guard var working = state else { break }
            if working.inFlight == nil {
                guard !working.queue.isEmpty else { break }
                seal(&working)
                commit(working)
            }
            let now = clock.now()
            if let wait = remainingBackoff(&working, now: now), wait > 0 {
                commit(working)
                return .backingOff(until: now.addingTimeInterval(wait))
            }
            guard let batch = working.inFlight else { break }

            guard let target = working.target else { break }
            let result = await transport.send(body: envelope(for: batch, trigger: trigger).encoded(), batchID: batch.id, target: target)
            // The user may have switched diagnostics off, or changed the endpoint, while the request was out.
            guard var after = state, after.inFlight?.id == batch.id else { return .idle }
            let outcome = handle(result, batch: batch, state: &after, now: clock.now())
            commit(after)
            switch outcome {
            case .acknowledged:
                batches += 1
                events += batch.events.count
            case .finished(let report):
                return report
            }
        }
        return batches == 0 ? .idle : .sent(batches: batches, events: events)
    }

    private enum Outcome {
        case acknowledged
        case finished(DiagnosticsFlushReport)
    }

    private func handle(_ result: DiagnosticsTransportResult, batch: DiagnosticsSealedBatch, state: inout DiagnosticsUploadState, now: Date) -> Outcome {
        switch result {
        case .cancelled:
            return .finished(.interrupted)
        case .networkFailure(let code):
            return .finished(backOff(&state, now: now, error: "network_\(code)"))
        case .status(let status):
            switch status {
            case 200..<300, 409:
                state.inFlight = nil
                state.failures = 0
                state.retryNotBefore = nil
                state.lastError = nil
                state.lastUploadAt = now
                return .acknowledged
            case 401, 403:
                return .finished(stop(&state, .keyRejected, status: status))
            case 300..<400, 404, 405:
                return .finished(stop(&state, .routeMissing, status: status))
            case 408, 429, 500..<600:
                return .finished(backOff(&state, now: now, error: "status_\(status)"))
            default:
                // The server read the batch and refused it. Resending the same bytes cannot help, and holding it
                // would block everything behind it, so it is dropped, counted, and reported in the next batch.
                state.inFlight = nil
                state.droppedEvents += batch.events.count + batch.droppedEvents
                state.droppedFields += batch.droppedFields
                state.rejectedEvents += batch.rejectedEvents
                return .finished(backOff(&state, now: now, error: "status_\(status)"))
            }
        }
    }

    private func stop(_ state: inout DiagnosticsUploadState, _ reason: DiagnosticsStopReason, status: Int) -> DiagnosticsFlushReport {
        state.stopped = reason
        state.lastError = "status_\(status)"
        return .stopped(reason)
    }

    private func backOff(_ state: inout DiagnosticsUploadState, now: Date, error: String) -> DiagnosticsFlushReport {
        state.failures += 1
        state.retryNotBefore = now.addingTimeInterval(backoff(forFailures: state.failures))
        state.lastError = error
        return .failed(error)
    }

    /// 30 s, doubling, capped at 15 min.
    private func backoff(forFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(config.maxBackoff, config.baseBackoff * Double(1 << min(failures - 1, 10)))
    }

    /// Seconds left of the wait. A stored deadline further away than one backoff step can only come from a clock
    /// that moved backwards, so it is replaced by a fresh single wait: a wrong clock costs one wait, never a lockout.
    private func remainingBackoff(_ state: inout DiagnosticsUploadState, now: Date) -> TimeInterval? {
        guard let deadline = state.retryNotBefore else { return nil }
        let step = backoff(forFailures: max(state.failures, 1))
        var remaining = deadline.timeIntervalSince(now)
        if remaining > step {
            state.retryNotBefore = now.addingTimeInterval(step)
            remaining = step
        }
        return remaining
    }

    private func seal(_ state: inout DiagnosticsUploadState) {
        let take = Array(state.queue.prefix(config.maxBatchEvents))
        state.queue.removeFirst(take.count)
        state.inFlight = DiagnosticsSealedBatch(
            id: UUID().uuidString,
            seq: state.nextSeq,
            sealedAt: clock.now(),
            droppedEvents: state.droppedEvents,
            droppedFields: state.droppedFields,
            rejectedEvents: state.rejectedEvents,
            events: take
        )
        state.nextSeq += 1
        state.droppedEvents = 0
        state.droppedFields = 0
        state.rejectedEvents = 0
    }

    /// Device fields are checked against the same rules as log values, so an unexpected string (a device name, an
    /// unknown thermal word) becomes `unknown` instead of going out.
    private func envelope(for batch: DiagnosticsSealedBatch, trigger: DiagnosticsFlushTrigger) -> DiagnosticsEnvelope {
        let device = deviceInfo()
        func checked(_ value: String, _ rule: DiagnosticsValueRule) -> String { rule.accepts(value) ? value : "unknown" }
        return DiagnosticsEnvelope(
            batchID: batch.id,
            seq: batch.seq,
            sentAt: DiagnosticsLogFormat.timestamp(clock.now()),
            deviceID: checked(device.deviceID, .uuid),
            appVersion: checked(device.appVersion, .version),
            appBuild: checked(device.appBuild, .version),
            iosVersion: checked(device.iosVersion, .version),
            deviceModel: checked(device.deviceModel, .hardwareModel),
            thermalState: checked(device.thermalState, .oneOf(Set(ThermalLevel.allCases.map(\.rawValue)))),
            trigger: trigger,
            droppedEvents: batch.droppedEvents,
            droppedFields: batch.droppedFields,
            rejectedEvents: batch.rejectedEvents,
            events: batch.events.map(\.event)
        )
    }

    private func commit(_ next: DiagnosticsUploadState) {
        state = next
        store.save(next)
    }
}
