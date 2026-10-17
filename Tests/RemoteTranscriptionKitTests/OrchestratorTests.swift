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
        /// Every wait the orchestrator schedules lands here and stays parked until a test releases it, so no test
        /// outcome depends on how fast the machine runs.
        let sleeper = ManualSleeper()
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
            log: { harness.log.append($0) },
            sleep: harness.sleeper.sleep
        )
    }

    /// Runs one dictation whose probe never answers and whose on-device text is ready at once, letting only the
    /// unresolved-probe grace elapse. Returning at all shows that wait alone ended the dictation.
    private func dictationWithAProbeThatNeverAnswers(
        timing: RemoteTranscriptionTiming
    ) async throws -> (outcome: RemoteTranscriptionOrchestrator.Outcome, sleeper: ManualSleeper) {
        let h = Harness()
        let orchestrator = make(h, timing: timing, probe: { try? await cancellableSleep(1_000); return .unreachable })
        let (audio, eligible) = (self.audio, self.eligible)
        let run = Task { try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { "local text" }) }
        await h.sleeper.waitUntilPending(timing.unresolvedProbeGrace)
        h.sleeper.release(timing.unresolvedProbeGrace)
        return (try await run.value, h.sleeper)
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
        let (outcome, sleeper) = try await dictationWithAProbeThatNeverAnswers(timing: timing)
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertEqual(sleeper.released, [timing.unresolvedProbeGrace], "only the grace elapsed, never the result budget")
        XCTAssertTrue(sleeper.requested.contains(timing.resultBudget), "the budget was scheduled but did not gate the text")
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
            try await cancellableSleep(1_000, cancelled: h.uploadCancelled)
            return "remote text"
        })
        let (audio, eligible) = (self.audio, self.eligible)
        let run = Task { try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { "local text" }) }
        await h.sleeper.waitUntilPending(timing.resultBudget)
        h.sleeper.release(timing.resultBudget)
        let outcome = try await run.value
        XCTAssertEqual(outcome, .init(text: "local text", source: .onDevice))
        XCTAssertEqual(h.sleeper.released, [timing.resultBudget], "it waited for the remote exactly until the budget ran out")
        await eventually("the late upload to be cancelled") { h.uploadCancelled.value }
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
        let gate = Gate()
        let orchestrator = make(h, upload: {
            await gate.wait()
            return "remote text"
        })
        let (audio, eligible) = (self.audio, self.eligible)
        let run = Task { try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { "local text" }) }
        await eventually("the upload to start") { h.uploadCalls.value == 1 }
        gate.open()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .init(text: "remote text", source: .remote))
        XCTAssertEqual(h.uploadCalls.value, 1)
        XCTAssertTrue(h.sleeper.released.isEmpty, "the budget never ran out")
    }

    func testRow08RemoteThatBeatsASlowOnDeviceRunIsUsedAtOnceAndOnDeviceIsStopped() async throws {
        let h = Harness()
        let outcome = try await make(h).transcribe(
            audioURL: audio, context: eligible, local: local(after: 1_000, harness: h)
        )
        XCTAssertEqual(outcome.source, .remote)
        XCTAssertTrue(h.sleeper.released.isEmpty)
        await eventually("the on-device run to be stopped") { h.localCancelled.value }
    }

    func testOnDeviceTextReadyFirstWaitsOnlyForARemoteThatIsInFlight() async throws {
        let h = Harness()
        let gate = Gate()
        let localDone = Flag()
        let orchestrator = make(h, upload: {
            await gate.wait()
            return "remote text"
        })
        let (audio, eligible) = (self.audio, self.eligible)
        let run = Task {
            try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { localDone.set(); return "local text" })
        }
        await eventually("on-device text and the upload both under way") { localDone.value && h.uploadCalls.value == 1 }
        gate.open()
        let outcome = try await run.value
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
        await eventually("the upload to start") { h.uploadCalls.value == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await eventually("both paths to be cancelled") { h.uploadCancelled.value && h.localCancelled.value }
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

    /// The acceptance criterion: an unreachable remote adds under 100 ms to a dictation. The orchestrator's only wait
    /// on that path is the unresolved-probe grace, so the criterion is a bound on the configured grace. Asserting the
    /// wait itself, not a stopwatch reading, keeps the check independent of runner load.
    func testAcceptanceUnreachableServerAddsLessThan100msToDictation() async throws {
        let criterion = 0.1
        let (outcome, sleeper) = try await dictationWithAProbeThatNeverAnswers(timing: .standard)
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertEqual(sleeper.released, [RemoteTranscriptionTiming.standard.unresolvedProbeGrace])
        XCTAssertLessThan(sleeper.released.reduce(0, +), criterion, "the whole wait the unreachable server caused")
        XCTAssertLessThan(RemoteTranscriptionTiming.standard.unresolvedProbeGrace, criterion)
    }

    func testAcceptanceAPrewarmedUnreachableVerdictAddsNothing() async throws {
        let cache = RemoteProbeCache(ttl: 30, probe: { .unreachable })
        await cache.prewarm()
        let sleeper = ManualSleeper()
        let orchestrator = RemoteTranscriptionOrchestrator(
            timing: .standard, probe: { await cache.outcome() }, upload: { _ in "remote" }, sleep: sleeper.sleep
        )
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: local())
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertTrue(sleeper.released.isEmpty, "no wait of any length was let elapse")
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

/// A verdict from before the server went away must not cost every following dictation the full budget.
final class StaleVerdictTests: XCTestCase {
    private let timing = RemoteTranscriptionTiming(probeThreshold: 0.1, resultBudget: 0.3, unresolvedProbeGrace: 0.05)
    private let audio = URL(fileURLWithPath: "/dev/null/recording.m4a")
    private let eligible = RemoteRequestContext(settingEnabled: true, endpointConfigured: true)

    func testRow14AnUploadThatMissesTheBudgetMakesTheNextRecordingProbeAgain() async throws {
        let probes = Counter()
        let invalidations = Counter()
        let hanging = Flag()
        let sleeper = ManualSleeper()
        let cache = RemoteProbeCache(ttl: 30, probe: {
            probes.increment()
            return hanging.value ? .timedOut : .reachable(latency: 0.02)
        })
        let orchestrator = RemoteTranscriptionOrchestrator(
            timing: timing,
            probe: { await cache.outcome() },
            upload: { _ in
                hanging.set()
                try await cancellableSleep(1_000)
                return "late"
            },
            invalidateProbe: { await cache.invalidate(); invalidations.increment() },
            sleep: sleeper.sleep
        )
        let (audio, eligible) = (self.audio, self.eligible)
        let firstRun = Task { try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { "on device" }) }
        await sleeper.waitUntilPending(timing.resultBudget)
        await eventually("the upload to start, after the probe passed") { hanging.value }
        sleeper.release(timing.resultBudget)
        let first = try await firstRun.value
        XCTAssertEqual(first.source, .onDevice)
        await eventually("the stale verdict to be dropped") { invalidations.value == 1 }
        XCTAssertEqual(probes.value, 1)

        let second = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { "on device" })
        XCTAssertEqual(second.source, .onDevice)
        XCTAssertEqual(probes.value, 2, "the stale 'fast' verdict was dropped and probed again")
        XCTAssertEqual(sleeper.released, [timing.resultBudget], "the second recording did not wait for the budget again")
    }

    func testRow05AFailedUploadInvalidatesTheVerdictAndASuccessDoesNot() async throws {
        for (fails, expected) in [(true, 1), (false, 0)] {
            let invalidations = Counter()
            let orchestrator = RemoteTranscriptionOrchestrator(
                timing: timing,
                probe: { .reachable(latency: 0.02) },
                upload: { _ in
                    if fails { throw RemoteTranscriptionError.transport(-1005) }
                    return "remote"
                },
                invalidateProbe: { invalidations.increment() },
                sleep: ManualSleeper().sleep
            )
            _ = try await orchestrator.transcribe(audioURL: audio, context: eligible, local: { "on device" })
            // A failed upload is invalidated before the orchestrator reports it, so the count is final on return.
            XCTAssertEqual(invalidations.value, expected, "fails=\(fails)")
        }
    }
}
