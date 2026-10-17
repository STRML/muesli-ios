import XCTest
@testable import DiagnosticsKit

/// Every test is one row of the failure matrix in the pull request. Time comes from `ManualClock` and the network
/// from `ScriptedTransport`, so nothing here reads the wall clock or opens a socket.
final class DiagnosticsUploadEngineTests: XCTestCase {
    private let studio = DiagnosticsEndpoint(
        url: Fixture.endpointURL, host: "studio.tail13013.ts.net", looksPrivate: true, keyFingerprint: "k1"
    )

    private func on(_ endpoint: DiagnosticsEndpoint? = nil) -> DiagnosticsRunSettings {
        DiagnosticsRunSettings(enabled: true, endpoint: endpoint ?? studio, acknowledgedHost: nil)
    }

    private struct Rig {
        var store = MemoryStateStore()
        var transport = ScriptedTransport()
        var clock = ManualClock()
        var config = DiagnosticsEngineConfig.standard
        var engine: DiagnosticsUploadEngine { Fixture.engine(store: store, transport: transport, clock: clock, config: config) }
    }

    private func run(
        _ engine: DiagnosticsUploadEngine,
        _ log: String,
        settings: DiagnosticsRunSettings? = nil,
        trigger: DiagnosticsFlushTrigger = .timer,
        backfill: Bool = false
    ) async -> DiagnosticsFlushReport {
        await engine.run(settings: settings ?? on(), logText: log, trigger: trigger, backfill: backfill)
    }

    // MARK: Opt-in

    func testToggleOffSendsNothingAndQueuesNothing() async {
        let rig = Rig()
        let engine = rig.engine
        let report = await run(engine, Fixture.numbered(20), settings: DiagnosticsRunSettings(enabled: false, endpoint: studio, acknowledgedHost: nil))
        XCTAssertEqual(report, .blocked(.toggleOff))
        XCTAssertTrue(rig.transport.sent.isEmpty)
        XCTAssertEqual(rig.store.saveCount, 0, "a disabled uploader must not even create state")
        XCTAssertNil(rig.store.load())
        let queued = await engine.status().queuedEvents
        XCTAssertEqual(queued, 0)
    }

    func testTurningOnStartsFromNowWithNoBackfillOfTheOldLog() async {
        let rig = Rig()
        let engine = rig.engine
        let before = Fixture.numbered(5)
        let first = await run(engine, before)
        XCTAssertEqual(first, .idle)
        XCTAssertTrue(rig.transport.sent.isEmpty)

        let after = before + Fixture.line(10, "intent.stop", ["request": "04fcc3fc"]) + "\n"
        let second = await run(engine, after)
        XCTAssertEqual(second, .sent(batches: 1, events: 1))
        XCTAssertEqual(rig.transport.sent.flatMap(\.envelope.events).map(\.name), ["intent.stop"])
    }

    func testSendNowBackfillsTheBufferMinusWhatWasAlreadySent() async {
        let rig = Rig()
        let engine = rig.engine
        let before = Fixture.numbered(5)
        _ = await run(engine, before)
        let after = before + Fixture.line(10, "intent.stop", ["request": "04fcc3fc"]) + "\n"
        _ = await run(engine, after)
        XCTAssertEqual(rig.transport.sent.count, 1)

        let manual = await run(engine, after, trigger: .manual, backfill: true)
        XCTAssertEqual(manual, .sent(batches: 1, events: 5))
        let ids = rig.transport.sent.flatMap(\.envelope.events).map(\.id)
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6, "Send now must not resend the event that already went")

        let again = await run(engine, after, trigger: .manual, backfill: true)
        XCTAssertEqual(again, .idle)
    }

    func testTurningOffWithAQueueClearsTheQueueAndAllState() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(7))
        let queued = await engine.status().queuedEvents
        XCTAssertEqual(queued, 7)

        let off = await run(engine, Fixture.numbered(7), settings: DiagnosticsRunSettings(enabled: false, endpoint: studio, acknowledgedHost: nil))
        XCTAssertEqual(off, .blocked(.toggleOff))
        XCTAssertNil(rig.store.load(), "the persisted queue is gone, not just paused")
        let after = await engine.status().queuedEvents
        XCTAssertEqual(after, 0)
    }

    func testAPublicLookingEndpointSendsNothingUntilTheHostIsAcknowledged() async {
        let rig = Rig()
        let engine = rig.engine
        let publicEndpoint = DiagnosticsEndpoint(url: "https://logs.example.com/v1/diagnostics", host: "logs.example.com", looksPrivate: false, keyFingerprint: "k1")
        let blocked = await run(engine, Fixture.numbered(3), settings: DiagnosticsRunSettings(enabled: true, endpoint: publicEndpoint, acknowledgedHost: nil))
        XCTAssertEqual(blocked, .blocked(.publicEndpointNotAcknowledged))
        XCTAssertTrue(rig.transport.sent.isEmpty)
        XCTAssertNil(rig.store.load())

        let acknowledged = DiagnosticsRunSettings(enabled: true, endpoint: publicEndpoint, acknowledgedHost: "logs.example.com")
        _ = await run(engine, Fixture.numbered(3), settings: acknowledged)
        let more = Fixture.numbered(3) + Fixture.line(9, "intent.stop", ["request": "04fcc3fc"]) + "\n"
        let sent = await run(engine, more, settings: acknowledged)
        XCTAssertEqual(sent, .sent(batches: 1, events: 1))
    }

    func testRemovingTheEndpointClearsTheQueue() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(3))
        let noEndpoint = await run(engine, Fixture.numbered(3), settings: DiagnosticsRunSettings(enabled: true, endpoint: nil, acknowledgedHost: nil))
        XCTAssertEqual(noEndpoint, .blocked(.noEndpoint))
        XCTAssertNil(rig.store.load())
    }

    // MARK: Network and server responses

    func testAnUnreachableEndpointQueuesAndRetriesTheSameBatchAfterTheBackoff() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1004))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(4)
        let first = await run(engine, log)
        XCTAssertEqual(first, .failed("network_-1004"))
        let status = await engine.status()
        XCTAssertEqual(status.queuedEvents, 4)
        XCTAssertEqual(status.lastError, "network_-1004")

        // Still inside the wait: no second request.
        let waiting = await run(engine, log)
        XCTAssertEqual(waiting, .backingOff(until: rig.clock.now().addingTimeInterval(30)))
        XCTAssertEqual(rig.transport.sent.count, 1)

        rig.clock.advance(31)
        rig.transport.setFallback(.status(200))
        let retried = await run(engine, log)
        XCTAssertEqual(retried, .sent(batches: 1, events: 4))
        XCTAssertEqual(rig.transport.sent.count, 2)
        XCTAssertEqual(rig.transport.sent[0].batchID, rig.transport.sent[1].batchID)
        XCTAssertEqual(rig.transport.sent[0].envelope.events.map(\.id), rig.transport.sent[1].envelope.events.map(\.id))
        XCTAssertEqual(rig.transport.sent[0].target, DiagnosticsTargetRecord(endpoint: Fixture.endpointURL, keyFingerprint: "k1"))
        let after = await engine.status()
        XCTAssertEqual(after.queuedEvents, 0)
        XCTAssertEqual(after.lastUploadAt, rig.clock.now())
        XCTAssertNil(after.lastError)
    }

    func testAirplaneModeQueuesAndDoesNotLoopTightly() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(2)
        for _ in 0..<10 { _ = await run(engine, log) }
        XCTAssertEqual(rig.transport.sent.count, 1, "ten passes inside one wait are one request")
        let queued = await engine.status().queuedEvents
        XCTAssertEqual(queued, 2)
    }

    func testA401StopsTheUploaderAndSurfacesItUntilTheKeyChanges() async {
        let rig = Rig()
        rig.transport.setFallback(.status(401))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(3)
        let first = await run(engine, log)
        XCTAssertEqual(first, .stopped(.keyRejected))
        let status = await engine.status()
        XCTAssertEqual(status.stopped, .keyRejected)
        XCTAssertEqual(status.queuedEvents, 3, "the events wait; a stopped uploader does not discard them")

        rig.clock.advance(3600)
        let still = await run(engine, log)
        XCTAssertEqual(still, .stopped(.keyRejected))
        XCTAssertEqual(rig.transport.sent.count, 1, "no retries against a rejected key")

        rig.transport.setFallback(.status(200))
        var newKey = studio
        newKey.keyFingerprint = "k2"
        let resumed = await run(engine, log, settings: on(newKey))
        XCTAssertEqual(resumed, .sent(batches: 1, events: 3))
    }

    func testA403AlsoStopsAsKeyRejected() async {
        let rig = Rig()
        rig.transport.setFallback(.status(403))
        let engine = rig.engine
        _ = await run(engine, "")
        let report = await run(engine, Fixture.numbered(1))
        XCTAssertEqual(report, .stopped(.keyRejected))
    }

    func testAMissingRouteStopsInsteadOfBackingOffLikeAServerError() async {
        for status in [404, 405] {
            let rig = Rig()
            rig.transport.setFallback(.status(status))
            let engine = rig.engine
            _ = await run(engine, "")
            let report = await run(engine, Fixture.numbered(1))
            XCTAssertEqual(report, .stopped(.routeMissing), "status \(status)")
            let stopped = await engine.status().stopped
            XCTAssertEqual(stopped, .routeMissing)
        }
    }

    func testSendNowRetriesAStoppedUploaderOnce() async {
        let rig = Rig()
        rig.transport.setFallback(.status(404))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(2)
        _ = await run(engine, log)
        rig.transport.setFallback(.status(200))
        let report = await run(engine, log, trigger: .manual, backfill: true)
        XCTAssertEqual(report, .sent(batches: 1, events: 2))
        let stopped = await engine.status().stopped
        XCTAssertNil(stopped)
    }

    func testServerErrorsBackOffExponentiallyAndCap() async {
        let rig = Rig()
        rig.transport.setFallback(.status(503))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(1)
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            _ = await run(engine, log)
            let until = await engine.status().retryNotBefore
            waits.append(until!.timeIntervalSince(rig.clock.now()))
            rig.clock.advance(waits.last! + 1)
        }
        XCTAssertEqual(waits, [30, 60, 120, 240, 480, 900, 900, 900])
    }

    func testRetryAfterLengthensTheWaitAndIsCapped() async {
        let rig = Rig()
        rig.transport.setFallback(.deferred(status: 429, retryAfter: 120))
        let engine = rig.engine
        _ = await run(engine, "")
        let first = await run(engine, Fixture.numbered(1))
        XCTAssertEqual(first, .failed("status_429"))
        var until = await engine.status().retryNotBefore
        XCTAssertEqual(until?.timeIntervalSince(rig.clock.now()), 120)
        // Still inside the server's wait, and a clock check must not shorten it to the 30 s backoff step.
        rig.clock.advance(60)
        let waiting = await run(engine, Fixture.numbered(1))
        XCTAssertEqual(waiting, .backingOff(until: rig.clock.now().addingTimeInterval(60)))
        XCTAssertEqual(rig.transport.sent.count, 1)

        rig.clock.advance(61)
        rig.transport.setFallback(.deferred(status: 503, retryAfter: 86_400))
        _ = await run(engine, Fixture.numbered(1))
        until = await engine.status().retryNotBefore
        XCTAssertEqual(until?.timeIntervalSince(rig.clock.now()), 3_600, "a day-long Retry-After is capped at an hour")
    }

    func testRateLimitingIsABackoffNotAStop() async {
        let rig = Rig()
        rig.transport.setFallback(.status(429))
        let engine = rig.engine
        _ = await run(engine, "")
        let report = await run(engine, Fixture.numbered(1))
        XCTAssertEqual(report, .failed("status_429"))
        let stopped = await engine.status().stopped
        XCTAssertNil(stopped)
    }

    func testARejectedBatchIsDroppedAndCountedInsteadOfBlockingTheQueueForever() async {
        let rig = Rig()
        rig.transport.setFallback(.status(422))
        let engine = rig.engine
        _ = await run(engine, "")
        let first = await run(engine, Fixture.numbered(3))
        XCTAssertEqual(first, .failed("status_422"))
        let status = await engine.status()
        XCTAssertEqual(status.queuedEvents, 0)

        rig.transport.setFallback(.status(200))
        rig.clock.advance(31)
        let more = Fixture.numbered(3) + Fixture.line(9, "intent.stop", ["request": "04fcc3fc"]) + "\n"
        _ = await run(engine, more)
        XCTAssertEqual(rig.transport.sent.last?.envelope.droppedEvents, 3, "the next batch reports what was dropped")
    }

    // MARK: Restarts and duplicates

    func testAppKilledMidBatchResendsTheSameBatchAndOnlyRemovesItOnAck() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1005))
        let first = rig.engine
        _ = await run(first, "")
        let log = Fixture.numbered(5)
        _ = await run(first, log)
        let persisted = rig.store.load()
        XCTAssertEqual(persisted?.inFlight?.events.count, 5, "unacknowledged events are still on disk")
        let batchID = persisted?.inFlight?.id

        // A new process: new engine, same disk.
        let revived = ScriptedTransport()
        let second = Fixture.engine(store: rig.store, transport: revived, clock: rig.clock)
        rig.clock.advance(31)
        let report = await run(second, log)
        XCTAssertEqual(report, .sent(batches: 1, events: 5))
        XCTAssertEqual(revived.sent.first?.batchID, batchID)
        XCTAssertNil(rig.store.load()?.inFlight)
        XCTAssertTrue(rig.store.load()?.queue.isEmpty == true)
    }

    func testAnEventIsNeverQueuedTwiceAcrossARestart() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1005))
        let first = rig.engine
        _ = await run(first, "")
        let log = Fixture.numbered(5)
        _ = await run(first, log)
        let second = Fixture.engine(store: rig.store, transport: rig.transport, clock: rig.clock)
        _ = await run(second, log)
        let queued = await second.status().queuedEvents
        XCTAssertEqual(queued, 5)
    }

    func testALostAcknowledgementResendsTheSameBatchIDAsTheIdempotencyKey() async {
        let rig = Rig()
        // The server stored the batch, then the response never arrived.
        rig.transport.setFallback(.networkFailure(code: -1001))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(2)
        _ = await run(engine, log)
        rig.transport.setFallback(.status(200))
        rig.clock.advance(31)
        _ = await run(engine, log)
        let sent = rig.transport.sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].batchID, sent[1].batchID)
        XCTAssertEqual(sent[0].batchID, sent[0].envelope.batchID, "the Idempotency-Key header and the body id are one value")
        XCTAssertEqual(sent[0].envelope.seq, sent[1].envelope.seq)
    }

    func testADuplicateBatchTheServerAlreadyHasCountsAsAcknowledged() async {
        let rig = Rig()
        rig.transport.setFallback(.status(409))
        let engine = rig.engine
        _ = await run(engine, "")
        let report = await run(engine, Fixture.numbered(2))
        XCTAssertEqual(report, .sent(batches: 1, events: 2))
        let queued = await engine.status().queuedEvents
        XCTAssertEqual(queued, 0)
    }

    // MARK: Caps

    func testTheDefaultCapsAreTwoMegabytesAndSevenDays() {
        XCTAssertEqual(DiagnosticsEngineConfig.standard.maxQueueBytes, 2 * 1024 * 1024)
        XCTAssertEqual(DiagnosticsEngineConfig.standard.maxAge, 7 * 24 * 3600)
        XCTAssertEqual(DiagnosticsEngineConfig.standard.maxBatchEvents, 100)
    }

    func testAQueueOverTheByteCapDropsTheOldestAndReportsTheCountInTheNextBatch() async {
        var rig = Rig()
        rig.config.maxQueueBytes = 4_000
        rig.config.maxBatchEvents = 1_000
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(60))
        let state = rig.store.load()
        let held = (state?.queue.count ?? 0) + (state?.inFlight?.events.count ?? 0)
        let bytes = (state?.queue.map(\.bytes).reduce(0, +) ?? 0)
            + (state?.inFlight?.events.map(\.bytes).reduce(0, +) ?? 0)
        XCTAssertLessThanOrEqual(bytes, 4_000)
        XCTAssertLessThan(held, 60)
        let dropped = 60 - held

        rig.transport.setFallback(.status(200))
        rig.clock.advance(31)
        _ = await run(engine, Fixture.numbered(60))
        let batch = rig.transport.sent.last?.envelope
        XCTAssertEqual(batch?.droppedEvents, dropped)
        let elapsed = batch?.events.compactMap { $0.fields["elapsed_ms"] }.compactMap(Int.init) ?? []
        XCTAssertEqual(elapsed.last, 59, "the newest events are the ones kept")
    }

    func testEventsOlderThanSevenDaysAreDropped() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(3))
        rig.clock.advance(8 * 24 * 3600)
        rig.transport.setFallback(.status(200))
        let log = Fixture.numbered(3) + Fixture.line(900_000, "intent.stop", ["request": "04fcc3fc"]) + "\n"
        let report = await run(engine, log)
        XCTAssertEqual(report, .sent(batches: 1, events: 1))
        XCTAssertEqual(rig.transport.sent.last?.envelope.droppedEvents, 3)
    }

    func testAClockMovedBackwardsDoesNotDropQueuedEvents() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(3))
        rig.clock.set(rig.clock.now().addingTimeInterval(-30 * 24 * 3600))
        let queued = await engine.status().queuedEvents
        _ = await run(engine, Fixture.numbered(3))
        let after = await engine.status().queuedEvents
        XCTAssertEqual(queued, 3)
        XCTAssertEqual(after, 3)
    }

    func testAClockMovedBackwardsDoesNotLockOutRetriesForDays() async {
        let rig = Rig()
        rig.transport.setFallback(.status(503))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(1)
        _ = await run(engine, log)
        rig.clock.set(rig.clock.now().addingTimeInterval(-10 * 24 * 3600))
        let waiting = await run(engine, log)
        guard case .backingOff(let until) = waiting else { return XCTFail("expected a wait, got \(waiting)") }
        XCTAssertLessThanOrEqual(until.timeIntervalSince(rig.clock.now()), 30, "a wrong clock costs one wait, never a lockout")
        rig.clock.advance(31)
        rig.transport.setFallback(.status(200))
        let resumed = await run(engine, log)
        XCTAssertEqual(resumed, .sent(batches: 1, events: 1))
    }

    // MARK: Endpoint and key changes

    func testChangingTheEndpointDiscardsTheQueueAndStartsFromNow() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(4)
        _ = await run(engine, log)

        rig.transport.setFallback(.status(200))
        let other = DiagnosticsEndpoint(url: "https://other.tail13013.ts.net/v1/diagnostics", host: "other.tail13013.ts.net", looksPrivate: true, keyFingerprint: "k1")
        let moved = await run(engine, log, settings: on(other))
        XCTAssertEqual(moved, .idle, "events gathered for the old server do not go to the new one, and the old log is not backfilled")
        XCTAssertTrue(rig.transport.sent.count == 1, "only the failed attempt at the old endpoint")

        let newer = log + Fixture.line(20, "intent.stop", ["request": "04fcc3fc"]) + "\n"
        let sent = await run(engine, newer, settings: on(other))
        XCTAssertEqual(sent, .sent(batches: 1, events: 1))
    }

    func testChangingTheEndpointClearsAStoppedState() async {
        let rig = Rig()
        rig.transport.setFallback(.status(404))
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(1))
        let other = DiagnosticsEndpoint(url: "https://other.tail13013.ts.net/v1/diagnostics", host: "other.tail13013.ts.net", looksPrivate: true, keyFingerprint: "k1")
        _ = await run(engine, Fixture.numbered(1), settings: on(other))
        let stopped = await engine.status().stopped
        XCTAssertNil(stopped)
    }

    // MARK: Background

    func testBackgroundTimeRunningOutLeavesTheBatchQueuedWithoutAPenalty() async {
        let rig = Rig()
        rig.transport.setFallback(.cancelled)
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(3)
        let report = await run(engine, log, trigger: .background)
        XCTAssertEqual(report, .interrupted)
        let status = await engine.status()
        XCTAssertEqual(status.queuedEvents, 3)
        XCTAssertNil(status.retryNotBefore, "an expired OS time budget is not a server failure")
        XCTAssertNil(rig.store.load()?.queue.first, "the events are sealed in the batch, ready to resend")

        rig.transport.setFallback(.status(200))
        let resumed = await run(engine, log)
        XCTAssertEqual(resumed, .sent(batches: 1, events: 3))
        XCTAssertEqual(rig.transport.sent[0].batchID, rig.transport.sent[1].batchID)
    }

    // MARK: Reading the shared log

    func testAPartialLastLineIsSkippedNowAndPickedUpOnceWholeWithoutDuplicates() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        let whole = Fixture.line(1, "intent.stop", ["request": "04fcc3fc"])
        let second = Fixture.line(2, "recording.started", ["elapsed_ms": "9"])
        let torn = whole + "\n" + String(second.prefix(30))
        let first = await run(engine, torn)
        XCTAssertEqual(first, .sent(batches: 1, events: 1))

        let complete = whole + "\n" + second + "\n"
        let next = await run(engine, complete)
        XCTAssertEqual(next, .sent(batches: 1, events: 1))
        XCTAssertEqual(rig.transport.sent.flatMap(\.envelope.events).map(\.name), ["intent.stop", "recording.started"])
    }

    func testRepeatedPassesOverTheSameLogQueueEachLineOnce() async {
        let rig = Rig()
        rig.transport.setFallback(.networkFailure(code: -1009))
        let engine = rig.engine
        _ = await run(engine, "")
        let log = Fixture.numbered(5)
        for _ in 0..<4 { _ = await run(engine, log) }
        let queued = await engine.status().queuedEvents
        XCTAssertEqual(queued, 5)
    }

    func testTheSeenSetStaysBoundedAsTheLogRotates() async {
        var rig = Rig()
        rig.config.seenLimit = 200
        let engine = rig.engine
        _ = await run(engine, "")
        for chunk in 0..<10 { _ = await run(engine, Fixture.numbered(100, from: chunk * 100)) }
        XCTAssertLessThanOrEqual(rig.store.load()?.seen.count ?? 0, 200)
        XCTAssertEqual(rig.transport.sent.flatMap(\.envelope.events).count, 1000)
    }

    // MARK: Batches and the envelope

    func testBatchesHoldAtMostOneHundredEventsAndAreNumberedInOrder() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        let report = await run(engine, Fixture.numbered(250))
        XCTAssertEqual(report, .sent(batches: 3, events: 250))
        XCTAssertEqual(rig.transport.sent.map(\.envelope.events.count), [100, 100, 50])
        XCTAssertEqual(rig.transport.sent.map(\.envelope.seq), [1, 2, 3])
        XCTAssertEqual(Set(rig.transport.sent.map(\.batchID)).count, 3)
        for sent in rig.transport.sent { XCTAssertNotNil(UUID(uuidString: sent.batchID)) }
    }

    func testTheEnvelopeCarriesTheDeviceFieldsAndTheTrigger() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(1), trigger: .background)
        let envelope = rig.transport.sent.first?.envelope
        XCTAssertEqual(envelope?.deviceID, Fixture.device.deviceID)
        XCTAssertEqual(envelope?.appVersion, "0.1.7")
        XCTAssertEqual(envelope?.appBuild, "9")
        XCTAssertEqual(envelope?.os, "iOS 26.0")
        XCTAssertEqual(envelope?.model, "iPhone18,1")
        XCTAssertEqual(envelope?.thermal, "nominal")
        XCTAssertEqual(envelope?.trigger, .background)
        XCTAssertEqual(envelope?.sentAt, DiagnosticsLogFormat.timestamp(rig.clock.now()))
        XCTAssertEqual(envelope?.schema, 1)
    }

    func testAUserTypedDeviceNameNeverReachesTheEnvelope() async {
        let rig = Rig()
        let hostile = DiagnosticsDeviceInfo(
            deviceID: "11111111-2222-4333-8444-555555555555", appVersion: "0.1.7", appBuild: "9",
            iosVersion: "26.0", deviceModel: "Sam's iPhone", thermalState: "toasty"
        )
        let engine = DiagnosticsUploadEngine(store: rig.store, transport: rig.transport, clock: rig.clock, deviceInfo: { hostile })
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(1))
        XCTAssertEqual(rig.transport.sent.first?.envelope.model, "unknown")
        // The receiver rejects a whole batch for a thermal state outside its four words.
        XCTAssertEqual(rig.transport.sent.first?.envelope.thermal, "nominal")
    }

    func testAHostileValueIsDroppedEndToEndAndTheBatchReportsTheCount() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        let transcript = "Please remind me to call Dr. Okafor about the biopsy results tomorrow"
        let log = Fixture.log(
            Fixture.line(1, "recording.startFailed", ["request": transcript, "elapsed_ms": "5", "transcript": "secret"]),
            Fixture.line(2, "typed.a.secret", ["request": "04fcc3fc"])
        )
        _ = await run(engine, log)
        let envelope = rig.transport.sent.first?.envelope
        XCTAssertEqual(envelope?.events.count, 1)
        XCTAssertEqual(envelope?.events.first?.fields, ["elapsed_ms": "5"])
        XCTAssertEqual(envelope?.droppedFields, 2)
        XCTAssertEqual(envelope?.rejectedEvents, 1)
        let body = String(data: envelope?.encoded() ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("Okafor"))
        XCTAssertFalse(body.contains("secret"))
    }

    func testResettingTheIdentityClearsTheQueueAndRestartsTheSequence() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(2))
        XCTAssertEqual(rig.transport.sent.first?.envelope.seq, 1)
        rig.transport.setFallback(.networkFailure(code: -1009))
        _ = await run(engine, Fixture.numbered(2) + Fixture.line(5) + "\n")
        await engine.resetIdentity()
        let queued = await engine.status().queuedEvents
        XCTAssertEqual(queued, 0, "events queued under the old device id do not follow the new one")
        XCTAssertEqual(rig.store.load()?.nextSeq, 1)
    }

    func testStatePersistsLastUploadAcrossEngineInstances() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        _ = await run(engine, Fixture.numbered(1))
        let again = Fixture.engine(store: rig.store, transport: rig.transport, clock: rig.clock)
        let status = await again.status()
        XCTAssertEqual(status.lastUploadAt, rig.clock.now())
    }

    // MARK: The lost dictation

    /// The real incident, replayed through the pipeline: stop pressed, transcription started, then the task left
    /// without a result. The last event the server sees names the stage it died in.
    func testALostDictationEndsWithAnExitEventNamingTheStage() async {
        let rig = Rig()
        let engine = rig.engine
        _ = await run(engine, "")
        let id = "04fcc3fc"
        let full = Fixture.request.uuidString
        let log = Fixture.log(
            Fixture.line(1, "intent.stop", process: "MuesliKeyboard", ["request": id, "localPhase": "recording"]),
            Fixture.line(1.1, "stop.received", ["request": full, "source": "keyboard"]),
            Fixture.line(1.4, "recording.stopped", ["request": full, "duration_ms": "6100", "samples": "97600", "bytes": "195200", "file_written": "yes"]),
            Fixture.line(1.5, "transcription.started", ["request": full, "model": "parakeet-tdt-v3"]),
            Fixture.line(2, "handoff.observed", process: "MuesliKeyboard", ["phase": "transcribingStarted", "request": id]),
            Fixture.line(10, "scene.inactive", ["active_request": full, "recording": "no"]),
            Fixture.line(19, "backgroundTask", ["request": full, "bg_state": "expired", "bg_remaining_ms": "0"]),
            Fixture.line(19.1, "dictation.exit", ["request": full, "outcome": "abandoned", "last_stage": "transcribing"])
        )
        let report = await run(engine, log)
        XCTAssertEqual(report, .sent(batches: 1, events: 8))
        let last = rig.transport.sent.last?.envelope.events.last
        XCTAssertEqual(last?.name, "dictation.exit")
        XCTAssertEqual(last?.fields["last_stage"], "transcribing")
        XCTAssertEqual(rig.transport.sent.last?.envelope.droppedFields, 0)
    }
}
