import Foundation

/// Runs on-device transcription and, when allowed, the remote one beside it, and picks exactly one text.
///
/// - On-device always runs, in parallel, so a slow or dead server never delays dictation by more than
///   `resultBudget`, and by no more than `unresolvedProbeGrace` when the server has not even answered the probe.
/// - Remote text is used only if it arrives inside `resultBudget` of the recording ending. Late text is dropped and
///   its upload cancelled, so nothing can replace text that was already delivered.
/// - A probe slower than `probeThreshold`, or any failure, falls back to the on-device text.
struct RemoteTranscriptionOrchestrator: Sendable {
    typealias Probe = @Sendable () async -> RemoteProbeOutcome
    typealias Upload = @Sendable (URL) async throws -> String
    typealias Prewarm = @Sendable () async -> Void
    typealias Log = @Sendable (String) -> Void
    typealias Invalidate = @Sendable () async -> Void
    /// Waits this many seconds, throwing if cancelled. Every wait the orchestrator schedules goes through here, so a
    /// test can record the delays and release them by hand instead of racing the wall clock.
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    enum Source: Sendable, Equatable { case onDevice, remote }

    struct Outcome: Sendable, Equatable {
        let text: String
        let source: Source
    }

    private enum Event: Sendable {
        case local(Result<String, any Error>)
        case probeResolved
        case remoteDone(String?)
        case deadline
        case graceExpired
    }

    let timing: RemoteTranscriptionTiming
    let probe: Probe
    let upload: Upload
    let prewarm: Prewarm
    let log: Log
    let invalidateProbe: Invalidate
    let sleep: Sleep

    init(
        timing: RemoteTranscriptionTiming = .standard,
        probe: @escaping Probe,
        upload: @escaping Upload,
        prewarm: @escaping Prewarm = {},
        log: @escaping Log = { _ in },
        invalidateProbe: @escaping Invalidate = {},
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.timing = timing
        self.probe = probe
        self.upload = upload
        self.prewarm = prewarm
        self.log = log
        self.invalidateProbe = invalidateProbe
        self.sleep = sleep
    }

    /// Call when recording starts, so the probe has an answer by the time it ends. Sends nothing for a request that
    /// could never use the server.
    func prewarmIfEligible(context: RemoteRequestContext) async {
        guard RemoteTranscriptionPolicy.eligibility(for: context) == .eligible else { return }
        await prewarm()
    }

    func transcribe(
        audioURL: URL,
        context: RemoteRequestContext,
        local: @escaping @Sendable () async throws -> String
    ) async throws -> Outcome {
        guard RemoteTranscriptionPolicy.eligibility(for: context) == .eligible else {
            return Outcome(text: try await local(), source: .onDevice)
        }

        let (stream, events) = AsyncStream<Event>.makeStream()
        let budget = timing.resultBudget
        let grace = timing.unresolvedProbeGrace
        let threshold = timing.probeThreshold
        let (probe, upload, log, invalidateProbe, sleep) = (self.probe, self.upload, self.log, self.invalidateProbe, self.sleep)

        let localTask = Task {
            do { events.yield(.local(.success(try await local()))) } catch { events.yield(.local(.failure(error))) }
        }
        let remoteTask = Task {
            let outcome = await probe()
            events.yield(.probeResolved)
            guard !Task.isCancelled, outcome.isFast(threshold: threshold) else {
                events.yield(.remoteDone(nil))
                return
            }
            do {
                let raw = try await upload(audioURL)
                guard !Task.isCancelled else { return }
                guard let text = RemoteTranscriptText.clean(raw) else {
                    log("remote transcription failed: \(RemoteTranscriptionError.unusableResponse.logCategory)")
                    events.yield(.remoteDone(nil))
                    return
                }
                events.yield(.remoteDone(text))
            } catch {
                guard !Task.isCancelled else { return }
                log("remote transcription failed: \(Self.category(of: error))")
                await invalidateProbe()
                events.yield(.remoteDone(nil))
            }
        }
        let deadlineTask = Task {
            try? await sleep(budget)
            if !Task.isCancelled { events.yield(.deadline) }
        }
        var graceTask: Task<Void, Never>?
        defer {
            localTask.cancel()
            remoteTask.cancel()
            deadlineTask.cancel()
            graceTask?.cancel()
            events.finish()
        }

        var localResult: Result<String, any Error>?
        var remoteIsOver = false
        var probeIsResolved = false
        for await event in stream {
            switch event {
            case .probeResolved:
                probeIsResolved = true
            case .remoteDone(let text):
                guard !remoteIsOver else { continue }
                if let text { return Outcome(text: text, source: .remote) }
                remoteIsOver = true
            case .deadline:
                // The probe passed, yet no text came in time: the cached verdict is stale.
                if !remoteIsOver, probeIsResolved { Task { await invalidateProbe() } }
                remoteIsOver = true
            case .local(let result):
                localResult = result
                if !remoteIsOver, !probeIsResolved {
                    graceTask = Task {
                        try? await sleep(grace)
                        if !Task.isCancelled { events.yield(.graceExpired) }
                    }
                }
            case .graceExpired:
                if !probeIsResolved { remoteIsOver = true }
            }
            if remoteIsOver, let localResult {
                return Outcome(text: try localResult.get(), source: .onDevice)
            }
        }
        throw CancellationError()
    }

    /// Typed errors say what went wrong; anything else is named by type only, since its description can carry a URL.
    private static func category(of error: any Error) -> String {
        if let typed = error as? RemoteTranscriptionError { return typed.logCategory }
        return String(describing: type(of: error))
    }
}
