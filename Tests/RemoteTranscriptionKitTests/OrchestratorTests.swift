import XCTest
@testable import RemoteTranscriptionKit

/// The decision flow with stubbed probe and upload. Rows 1 to 16 and the latency acceptance.
final class OrchestratorTests: XCTestCase {
    private let timing = RemoteTranscriptionTiming(probeThreshold: 0.1, resultBudget: 0.5, unresolvedProbeGrace: 0.05)
    private let audio = URL(fileURLWithPath: "/dev/null/recording.m4a")
    private let eligible = RemoteRequestContext(settingEnabled: true, endpointConfigured: true)

    private struct Harness {
        let probeCalls = Counter()
        let uploadCalls = Counter()
        let prewarmCalls = Counter()
        let log = LogSink()
        let uploadCancelled = Flag()
        let localCancelled = Flag()
    }

    private func make(
        _ harness: Harness,
        timing: RemoteTranscriptionTiming? = nil,
        probe: @escaping @Sendable () async -> RemoteProbeOutcome = { .reachable(latency: 0.02) },
        upload: @escaping @Sendable () async throws -> String = { "remote text" }
    ) -> RemoteTranscriptionOrchestrator {
        RemoteTranscriptionOrchestrator(
            timing: timing ?? self.timing,
            probe: { harness.probeCalls.increment(); return await probe() },
            upload: { _ in harness.uploadCalls.increment(); return try await upload() },
            prewarm: { harness.prewarmCalls.increment() },
            log: { harness.log.append($0) }
        )
    }

    private func local(
        _ text: String = "local text",
        after delay: Double = 0,
        harness: Harness? = nil
    ) -> @Sendable () async throws -> String {
        {
            if delay > 0 { try await cancellableSleep(delay, cancelled: harness?.localCancelled) }
            return text
        }
    }

    private func assertNothingSent(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(harness.probeCalls.value, 0, "probe", file: file, line: line)
        XCTAssertEqual(harness.uploadCalls.value, 0, "upload", file: file, line: line)
    }

    // MARK: Rows 1, 2, 10, 12: ineligible requests send nothing

    func testRow01SettingOffTranscribesOnDeviceAndSendsNothing() async throws {
        let h = Harness()
        let context = RemoteRequestContext(settingEnabled: false, endpointConfigured: true)
        let outcome = try await make(h).transcribe(audioURL: audio, context: context, local: local())
        XCTAssertEqual(outcome, .init(text: "local text", source: .onDevice))
        assertNothingSent(h)
    }

    func testRow02NoEndpointIgnoresTheStaleSettingAndSendsNothing() async throws {
        let h = Harness()
        let context = RemoteRequestContext(settingEnabled: true, endpointConfigured: false)
        let outcome = try await make(h).transcribe(audioURL: audio, context: context, local: local())
        XCTAssertEqual(outcome.source, .onDevice)
        assertNothingSent(h)
    }

    func testRow10KeyboardWithoutFullAccessSendsNothing() async throws {
        let h = Harness()
        let context = RemoteRequestContext(
            settingEnabled: true, endpointConfigured: true, origin: .keyboard(hasFullAccess: false)
        )
        let outcome = try await make(h).transcribe(audioURL: audio, context: context, local: local())
        XCTAssertEqual(outcome.source, .onDevice)
        assertNothingSent(h)
    }

    func testRow10KeyboardWithFullAccessMayUseRemote() async throws {
        let h = Harness()
        let context = RemoteRequestContext(
            settingEnabled: true, endpointConfigured: true, origin: .keyboard(hasFullAccess: true)
        )
        let outcome = try await make(h).transcribe(audioURL: audio, context: context, local: local())
        XCTAssertEqual(outcome, .init(text: "remote text", source: .remote))
    }

    func testRow12PrivateContentIsNeverSent() async throws {
        let h = Harness()
        let context = RemoteRequestContext(settingEnabled: true, endpointConfigured: true, isPrivateContent: true)
        let outcome = try await make(h).transcribe(audioURL: audio, context: context, local: local())
        XCTAssertEqual(outcome.source, .onDevice)
        assertNothingSent(h)
    }

    func testIneligibleRequestsDoNotPrewarmAProbeEither() async {
        let contexts = [
            RemoteRequestContext(settingEnabled: false, endpointConfigured: true),
            RemoteRequestContext(settingEnabled: true, endpointConfigured: false),
            RemoteRequestContext(settingEnabled: true, endpointConfigured: true, origin: .keyboard(hasFullAccess: false)),
            RemoteRequestContext(settingEnabled: true, endpointConfigured: true, isPrivateContent: true),
        ]
        for context in contexts {
            let h = Harness()
            await make(h).prewarmIfEligible(context: context)
            XCTAssertEqual(h.prewarmCalls.value, 0, "\(context)")
        }
        let h = Harness()
        await make(h).prewarmIfEligible(context: eligible)
        XCTAssertEqual(h.prewarmCalls.value, 1)
    }

    // MARK: Rows 3, 4, 9, 13: the probe says no

    func testRow03NoTranscriptionRouteUsesOnDeviceTextWithoutUploading() async throws {
        let h = Harness()
        let outcome = try await make(h, probe: { .noRoute }).transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome, .init(text: "local text", source: .onDevice))
        XCTAssertEqual(h.uploadCalls.value, 0)
    }

    func testRow04SlowProbeUsesOnDeviceTextWithoutUploading() async throws {
        let h = Harness()
        let outcome = try await make(h, probe: { .reachable(latency: 0.5) })
            .transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertEqual(h.uploadCalls.value, 0)
    }

    func testRow04TimedOutAndUnreachableProbesUseOnDeviceText() async throws {
        for probed in [RemoteProbeOutcome.timedOut, .unreachable] {
            let h = Harness()
            let outcome = try await make(h, probe: { probed }).transcribe(audioURL: audio, context: eligible, local: local())
            XCTAssertEqual(outcome.source, .onDevice, "\(probed)")
            XCTAssertEqual(h.uploadCalls.value, 0)
        }
    }

    func testRow04AProbeThatNeverAnswersDoesNotHoldTheOnDeviceTextBeyondTheGrace() async throws {
        let h = Harness()
        let orchestrator = make(h, probe: { try? await Task.sleep(for: .seconds(30)); return .unreachable })
        let start = ContinuousClock.now
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        let elapsed = seconds(ContinuousClock.now - start)
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertLessThan(elapsed, timing.unresolvedProbeGrace + 0.15)
    }

    func testRow09ProbeFailureOnAMeteredLinkStillSendsNoRecording() async throws {
        // The probe runs on any link; the upload happens only when it passes.
        let h = Harness()
        _ = try await make(h, probe: { .reachable(latency: 0.9) }).transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(h.probeCalls.value, 1)
        XCTAssertEqual(h.uploadCalls.value, 0)
    }

    // MARK: Rows 5, 6, 7, 8: the upload

    func testRow05UploadFailureUsesOnDeviceTextAndLogsOneLine() async throws {
        let h = Harness()
        let secret = "SECRET-KEY-do-not-log"
        let orchestrator = make(h, upload: { throw StubFailure(description: "boom \(secret) https://host/path") })
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome, .init(text: "local text", source: .onDevice))
        XCTAssertEqual(h.uploadCalls.value, 1, "no retry")
        XCTAssertEqual(h.log.lines.count, 1)
        XCTAssertFalse(h.log.lines.joined().contains(secret))
        XCTAssertFalse(h.log.lines.joined().contains("https://"))
    }

    func testRow05ATypedUploadFailureLogsItsCategory() async throws {
        let h = Harness()
        let orchestrator = make(h, upload: { throw RemoteTranscriptionError.transport(-1005) })
        _ = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(h.log.lines.count, 1)
        XCTAssertTrue((h.log.lines.first ?? "").contains(RemoteTranscriptionError.transport(-1005).logCategory))
    }

    func testRow06RemoteAfterTheBudgetIsDroppedAndNothingReplacesTheOnDeviceText() async throws {
        let h = Harness()
        let orchestrator = make(h, upload: {
            try await cancellableSleep(2, cancelled: h.uploadCancelled)
            return "remote text"
        })
        let start = ContinuousClock.now
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        let elapsed = seconds(ContinuousClock.now - start)
        XCTAssertEqual(outcome, .init(text: "local text", source: .onDevice))
        XCTAssertGreaterThanOrEqual(elapsed, timing.resultBudget - 0.05, "waits for the remote until the budget runs out")
        XCTAssertLessThan(elapsed, timing.resultBudget + 0.3)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(h.uploadCancelled.value, "the late upload is cancelled, never left to land later")
    }

    func testRow07EmptyOrGarbageRemoteTextFallsBackToOnDevice() async throws {
        for garbage in ["", "   \n", "...", "—"] {
            let h = Harness()
            let outcome = try await make(h, upload: { garbage }).transcribe(audioURL: audio, context: eligible, local: local())
            XCTAssertEqual(outcome, .init(text: "local text", source: .onDevice), "\(garbage.debugDescription)")
            XCTAssertEqual(h.log.lines.count, 1)
        }
    }

    func testRow08RemoteTextInsideTheBudgetWinsAndIsDeliveredOnce() async throws {
        let h = Harness()
        let orchestrator = make(h, upload: {
            try await Task.sleep(for: .milliseconds(120))
            return "remote text"
        })
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome, .init(text: "remote text", source: .remote))
        XCTAssertEqual(h.uploadCalls.value, 1)
    }

    func testRow08RemoteThatBeatsASlowOnDeviceRunIsUsedAtOnceAndOnDeviceIsStopped() async throws {
        let h = Harness()
        let orchestrator = make(h, upload: {
            try await Task.sleep(for: .milliseconds(80))
            return "remote text"
        })
        let start = ContinuousClock.now
        let outcome = try await orchestrator.transcribe(
            audioURL: audio, context: eligible, local: local(after: 2, harness: h)
        )
        let elapsed = seconds(ContinuousClock.now - start)
        XCTAssertEqual(outcome.source, .remote)
        XCTAssertLessThan(elapsed, 0.4)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(h.localCancelled.value)
    }

    func testOnDeviceTextReadyFirstWaitsOnlyForARemoteThatIsInFlight() async throws {
        let h = Harness()
        let orchestrator = make(h, upload: {
            try await Task.sleep(for: .milliseconds(200))
            return "remote text"
        })
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome.text, "remote text")
    }

    // MARK: Rows 11 and extras

    func testRow11CancellingTheDictationCancelsBothPathsAndLeavesNoUploadRunning() async throws {
        let h = Harness()
        let orchestrator = make(h, upload: {
            try await cancellableSleep(5, cancelled: h.uploadCancelled)
            return "remote text"
        })
        let (audio, eligible) = (self.audio, self.eligible)
        let slowLocal = local(after: 5, harness: h)
        let task = Task {
            try await orchestrator.transcribe(audioURL: audio, context: eligible, local: slowLocal)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(h.uploadCancelled.value)
        XCTAssertTrue(h.localCancelled.value)
    }

    func testOnDeviceFailureWithAGoodRemoteUsesTheRemoteText() async throws {
        let h = Harness()
        let failing: @Sendable () async throws -> String = { throw StubFailure(description: "model not loaded") }
        let outcome = try await make(h).transcribe(audioURL: audio, context: eligible, local: failing)
        XCTAssertEqual(outcome, .init(text: "remote text", source: .remote))
    }

    func testOnDeviceFailureWithNoRemoteRethrowsTheOnDeviceError() async {
        let h = Harness()
        let failing: @Sendable () async throws -> String = { throw StubFailure(description: "model not loaded") }
        do {
            _ = try await make(h, probe: { .unreachable }).transcribe(audioURL: audio, context: eligible, local: failing)
            XCTFail("expected the on-device error")
        } catch {
            XCTAssertEqual((error as? StubFailure)?.description, "model not loaded")
        }
    }

    // MARK: Acceptance

    func testAcceptanceUnreachableServerAddsLessThan100msToDictation() async throws {
        let h = Harness()
        let orchestrator = make(h, timing: .standard, probe: {
            try? await Task.sleep(for: .seconds(30))
            return .unreachable
        })
        let baselineStart = ContinuousClock.now
        _ = try await make(Harness(), timing: .standard).transcribe(
            audioURL: audio,
            context: RemoteRequestContext(settingEnabled: false, endpointConfigured: true),
            local: local()
        )
        let baseline = seconds(ContinuousClock.now - baselineStart)

        let start = ContinuousClock.now
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        let withRemote = seconds(ContinuousClock.now - start)
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertLessThan(withRemote - baseline, 0.1)
    }

    func testAcceptanceAPrewarmedUnreachableVerdictAddsNothing() async throws {
        let cache = RemoteProbeCache(ttl: 30, probe: { .unreachable })
        await cache.prewarm()
        let orchestrator = RemoteTranscriptionOrchestrator(
            timing: .standard, probe: { await cache.outcome() }, upload: { _ in "remote" }
        )
        let start = ContinuousClock.now
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertLessThan(seconds(ContinuousClock.now - start), 0.03)
    }
}

/// The probe memory that lets dictation read a verdict instead of waiting for one.
final class ProbeCacheTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    }

    func testAFreshVerdictIsReusedAndAStaleOneIsReprobed() async {
        let calls = Counter()
        let clock = Clock()
        let cache = RemoteProbeCache(ttl: 30, now: { clock.now }, probe: { calls.increment(); return .reachable(latency: 0.05) })
        _ = await cache.outcome()
        _ = await cache.outcome()
        XCTAssertEqual(calls.value, 1)
        clock.advance(31)
        _ = await cache.outcome()
        XCTAssertEqual(calls.value, 2)
    }

    func testPrewarmAndOutcomeShareOneProbe() async {
        let calls = Counter()
        let cache = RemoteProbeCache(ttl: 30, probe: {
            calls.increment()
            try? await Task.sleep(for: .milliseconds(80))
            return .reachable(latency: 0.08)
        })
        await cache.prewarm()
        let outcome = await cache.outcome()
        XCTAssertEqual(outcome, .reachable(latency: 0.08))
        XCTAssertEqual(calls.value, 1)
    }
}
