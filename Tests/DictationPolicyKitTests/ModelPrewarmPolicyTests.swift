import XCTest
@testable import DictationPolicyKit

/// When the app may load the selected transcription model ahead of need, and how it backs off after a load fails
/// or takes too long. Every test is one row of the failure matrix in the pull request. Time is a `Date` the test
/// supplies, so nothing here reads the wall clock.
final class ModelPrewarmPolicyTests: XCTestCase {
    private typealias Policy = ModelPrewarmPolicy

    private let model = "whisper-small-en"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The app build and OS the model loads under in these tests. `ModelPrewarmReadinessTests` covers a change.
    private let stamp = "0.1.7(40)/27.0"

    private func decide(
        _ trigger: Policy.Trigger,
        downloaded: Bool = true,
        loaded: Bool = false,
        inFlight: Bool = false,
        history: ModelPrewarmHistory? = nil,
        at now: Date? = nil
    ) -> Policy.Decision {
        Policy.decide(
            trigger: trigger,
            isDownloaded: downloaded,
            isLoaded: loaded,
            loadInFlight: inFlight,
            history: history ?? ModelPrewarmHistory(modelID: model),
            stamp: stamp,
            now: now ?? t0
        )
    }

    /// A model that has loaded before: the steady state after the first warm.
    private func warmed() -> ModelPrewarmHistory {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordLoad(seconds: 2, now: t0, stamp: stamp)
        return history
    }

    private func failedOnce(at time: Date? = nil) -> ModelPrewarmHistory {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordFailure(now: time ?? t0)
        return history
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "ModelPrewarmPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Model state

    // Row 1: first launch with no model on the phone. The prewarm path starts the download as it always did; the
    // download is network and disk work, not a Neural Engine load, so it is not throttled.
    func testFirstLaunchWithNoModelStartsTheDownloadOnEveryTrigger() {
        for trigger in Policy.Trigger.allCases {
            XCTAssertEqual(decide(trigger, downloaded: false), .download, "\(trigger)")
        }
    }

    // Row 1b: a failing load never throttles the download that repairs missing files.
    func testMissingFilesStartTheDownloadEvenWhileBackingOff() {
        let history = failedOnce()
        XCTAssertEqual(decide(.foreground, downloaded: false, history: history, at: t0.addingTimeInterval(1)), .download)
    }

    // Row 2: the model is downloaded, has never loaded on this install, and the app just opened. This is the one
    // cold-open prewarm that remains, so the very first dictation does not pay the Neural Engine compile.
    func testDownloadedModelThatHasNeverLoadedWarmsOnLaunchLaunchScreenAndForeground() {
        for trigger in [Policy.Trigger.launch, .launchScreen, .foreground] {
            XCTAssertEqual(decide(trigger), .load, "\(trigger)")
        }
    }

    // Row 3: the model is already in memory. Nothing to do for any trigger.
    func testAlreadyLoadedModelIsNeverLoadedAgain() {
        for trigger in Policy.Trigger.allCases {
            XCTAssertEqual(decide(trigger, loaded: true, history: warmed()), .skip(.alreadyLoaded), "\(trigger)")
        }
    }

    // Row 4: a plain foreground, launch or launch screen, on a model that has loaded before, does not load it.
    // This is the change that stops the heat: the load happens when it is needed, not whenever the app opens.
    func testOpeningTheAppDoesNotPrewarmAModelThatHasLoadedBefore() {
        for trigger in [Policy.Trigger.launch, .launchScreen, .foreground] {
            XCTAssertEqual(decide(trigger, history: warmed()), .skip(.alreadyWarmedOnce), "\(trigger)")
        }
    }

    // MARK: Demand triggers

    // Row 5: arming the keyboard session still prewarms, even for a model that has loaded before.
    func testKeyboardSessionStartStillPrewarms() {
        XCTAssertEqual(decide(.keyboardSession, history: warmed()), .load)
        XCTAssertEqual(decide(.keyboardSession), .load)
    }

    // Row 6: starting a recording with the model unloaded still loads it, so the load overlaps the speech.
    func testRecordingStartWithTheModelUnloadedStillLoadsIt() {
        XCTAssertEqual(decide(.recordingStart, history: warmed()), .load)
        XCTAssertEqual(decide(.recordingStart), .load)
    }

    // Row 6b: finishing onboarding and starting a meeting are demand triggers too.
    func testOnboardingCompletionAndMeetingRecordingStillPrewarm() {
        XCTAssertEqual(decide(.onboardingCompleted, history: warmed()), .load)
        XCTAssertEqual(decide(.meetingRecording, history: warmed()), .load)
    }

    // MARK: In flight

    // Row 7: a foreground while a load is already running starts nothing, whatever the trigger or history.
    func testForegroundWhileALoadIsInFlightDoesNotStartASecondLoad() {
        for trigger in Policy.Trigger.allCases {
            XCTAssertEqual(decide(trigger, inFlight: true), .skip(.loadInFlight), "\(trigger)")
            XCTAssertEqual(decide(trigger, inFlight: true, history: warmed()), .skip(.loadInFlight), "\(trigger)")
        }
    }

    // MARK: Failure and backoff

    // Row 8: a load fails once. The next foreground, a second later, does not retry.
    func testALoadThatFailedOnceIsNotRetriedOnTheNextForeground() {
        let history = failedOnce()
        XCTAssertEqual(history.strikes, 1)
        XCTAssertEqual(decide(.foreground, history: history, at: t0.addingTimeInterval(1)), .skip(.backingOff))
        XCTAssertEqual(decide(.launch, history: history, at: t0.addingTimeInterval(60)), .skip(.backingOff))
    }

    // Row 8b: the backoff gates every automatic trigger, including the ones that normally always load.
    func testBackoffGatesKeyboardSessionRecordingStartAndMeetingAlike() {
        let history = failedOnce()
        let soon = t0.addingTimeInterval(10)
        for trigger in [Policy.Trigger.keyboardSession, .recordingStart, .meetingRecording, .onboardingCompleted] {
            XCTAssertEqual(decide(trigger, history: history, at: soon), .skip(.backingOff), "\(trigger)")
        }
    }

    // Row 9: repeated failures lengthen the wait and the wait stops growing at the cap.
    func testRepeatedFailuresDoubleTheWaitAndCapIt() {
        let expected: [TimeInterval] = [300, 600, 1_200, 2_400, 4_800, 9_600, 19_200, 21_600, 21_600]
        let actual = (1...9).map { Policy.backoffSeconds(forStrikes: $0) }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Policy.backoffSeconds(forStrikes: 0), 0)
        // A store that failed a million times must not overflow the shift.
        XCTAssertEqual(Policy.backoffSeconds(forStrikes: 1_000_000), Policy.maxBackoffSeconds)
        XCTAssertEqual(Policy.backoffSeconds(forStrikes: Int.max), Policy.maxBackoffSeconds)
    }

    // Row 9b: each failure restarts the wait from the failure, with the next length.
    func testEachFailureRestartsTheWaitFromThatFailure() {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordFailure(now: t0)
        history.recordFailure(now: t0.addingTimeInterval(400))
        XCTAssertEqual(history.strikes, 2)
        XCTAssertEqual(history.remainingBackoff(now: t0.addingTimeInterval(400)), 600, accuracy: 0.001)
        XCTAssertEqual(history.remainingBackoff(now: t0.addingTimeInterval(1_000)), 0, accuracy: 0.001)
    }

    // Row 10: a load that succeeds but takes longer than 30 s counts as a strike, and exactly 30 s does not.
    func testASlowLoadCountsAsAStrikeAndAFastOneClearsThem() {
        var slow = ModelPrewarmHistory(modelID: model)
        slow.recordLoad(seconds: 30.5, now: t0, stamp: stamp)
        XCTAssertEqual(slow.strikes, 1)
        XCTAssertTrue(slow.isWarm(for: stamp))
        XCTAssertEqual(decide(.keyboardSession, history: slow, at: t0.addingTimeInterval(5)), .skip(.backingOff))

        var boundary = ModelPrewarmHistory(modelID: model)
        boundary.recordLoad(seconds: 30, now: t0, stamp: stamp)
        XCTAssertEqual(boundary.strikes, 0)

        var recovered = failedOnce()
        recovered.recordLoad(seconds: 2, now: t0.addingTimeInterval(400), stamp: stamp)
        XCTAssertEqual(recovered.strikes, 0)
        XCTAssertNil(recovered.lastStrikeAt)
        XCTAssertEqual(decide(.keyboardSession, history: recovered, at: t0.addingTimeInterval(401)), .load)
    }

    // Row 10b: the 933 s load in the user's log. A slow success backs the next attempts off, and the model that
    // did load is not warmed again on open.
    func testTheNineHundredSecondLoadBacksOffAndStopsOpportunisticWarming() {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordLoad(seconds: 933, now: t0, stamp: stamp)
        XCTAssertEqual(decide(.foreground, history: history, at: t0.addingTimeInterval(1)), .skip(.backingOff))
        let afterWait = t0.addingTimeInterval(Policy.baseBackoffSeconds)
        XCTAssertEqual(decide(.foreground, history: history, at: afterWait), .skip(.alreadyWarmedOnce))
        XCTAssertEqual(decide(.keyboardSession, history: history, at: afterWait), .load)
    }

    // Row 11: the wait ends exactly when it is up.
    func testBackoffExpiresAtTheBoundary() {
        let history = failedOnce()
        let wait = Policy.baseBackoffSeconds
        XCTAssertEqual(decide(.foreground, history: history, at: t0.addingTimeInterval(wait - 0.001)), .skip(.backingOff))
        XCTAssertEqual(decide(.foreground, history: history, at: t0.addingTimeInterval(wait)), .load)
        XCTAssertEqual(decide(.foreground, history: history, at: t0.addingTimeInterval(wait + 3_600)), .load)
    }

    // Row 12: the clock moves backwards after a failure. The wait is never negative and never a lockout.
    func testAClockMovedBackwardsNeitherGoesNegativeNorLocksTheModelOut() {
        let history = failedOnce(at: t0)
        let behind = t0.addingTimeInterval(-86_400)
        XCTAssertEqual(history.remainingBackoff(now: behind), 0)
        XCTAssertEqual(decide(.foreground, history: history, at: behind), .load)

        var corrupt = ModelPrewarmHistory(modelID: model)
        corrupt.strikes = 3
        corrupt.lastStrikeAt = t0.addingTimeInterval(10 * 365 * 86_400)
        XCTAssertEqual(corrupt.remainingBackoff(now: t0), 0)
        XCTAssertGreaterThanOrEqual(history.remainingBackoff(now: t0.addingTimeInterval(1)), 0)
    }

    // Row 12b: strikes recorded without a timestamp (a hand-edited or partly written record) do not lock out.
    func testStrikesWithoutATimestampDoNotBlock() {
        var history = ModelPrewarmHistory(modelID: model)
        history.strikes = 5
        history.lastStrikeAt = nil
        XCTAssertEqual(history.remainingBackoff(now: t0), 0)
        XCTAssertEqual(decide(.foreground, history: history), .load)
    }

    // Row 10c: the duration the coordinator measures converts to seconds without losing the fraction, so a 30.5 s
    // load is slow and a 29.9 s load is not.
    func testMeasuredDurationConvertsToFractionalSeconds() {
        XCTAssertEqual(Duration.milliseconds(30_500).totalSeconds, 30.5, accuracy: 0.0001)
        XCTAssertEqual(Duration.seconds(2).totalSeconds, 2, accuracy: 0.0001)
        var history = ModelPrewarmHistory(modelID: model)
        history.recordLoad(seconds: Duration.milliseconds(29_900).totalSeconds, now: t0, stamp: stamp)
        XCTAssertEqual(history.strikes, 0)
        history.recordLoad(seconds: Duration.milliseconds(30_500).totalSeconds, now: t0, stamp: stamp)
        XCTAssertEqual(history.strikes, 1)
    }

    // MARK: Persistence

    // Row 13: the app relaunches right after a failure. A new store over the same defaults still backs off.
    func testRelaunchRightAfterAFailureRespectsThePersistedBackoff() {
        let defaults = isolatedDefaults()
        ModelPrewarmHistoryStore(defaults: defaults).recordFailure(modelID: model, now: t0)

        let relaunched = ModelPrewarmHistoryStore(defaults: defaults)
        let history = relaunched.history(for: model)
        XCTAssertEqual(history.strikes, 1)
        XCTAssertEqual(decide(.launch, history: history, at: t0.addingTimeInterval(20)), .skip(.backingOff))
        XCTAssertEqual(decide(.launch, history: history, at: t0.addingTimeInterval(Policy.baseBackoffSeconds)), .load)
    }

    // Row 13b: a successful load persists too, so a relaunch no longer warms on open.
    func testASuccessfulLoadPersistsAcrossRelaunch() {
        let defaults = isolatedDefaults()
        ModelPrewarmHistoryStore(defaults: defaults).recordLoad(modelID: model, seconds: 2.2, now: t0, stamp: stamp)
        let history = ModelPrewarmHistoryStore(defaults: defaults).history(for: model)
        XCTAssertTrue(history.isWarm(for: stamp))
        XCTAssertEqual(decide(.launch, history: history), .skip(.alreadyWarmedOnce))
    }

    // Row 14: the user changes the model. The new model starts clean, and switching back does not resurrect the
    // old model's backoff.
    func testChangingTheModelResetsTheBackoff() {
        let defaults = isolatedDefaults()
        let store = ModelPrewarmHistoryStore(defaults: defaults)
        store.recordFailure(modelID: model, now: t0)

        XCTAssertEqual(store.history(for: "parakeet-v3").strikes, 0)
        XCTAssertFalse(store.history(for: "parakeet-v3").isWarm(for: stamp))

        store.reset(modelID: model)
        XCTAssertEqual(store.history(for: model).strikes, 0)
        XCTAssertEqual(decide(.foreground, history: store.history(for: model), at: t0.addingTimeInterval(1)), .load)
    }

    // Row 14b: an outcome that arrives for a model that is no longer selected is not recorded against the new one.
    func testAnOutcomeForAnotherModelDoesNotTouchTheCurrentModelsRecord() {
        let defaults = isolatedDefaults()
        let store = ModelPrewarmHistoryStore(defaults: defaults)
        store.recordLoad(modelID: "parakeet-v3", seconds: 1, now: t0, stamp: stamp)
        store.recordFailure(modelID: model, now: t0)
        XCTAssertEqual(store.history(for: model).strikes, 1)
        // One record is kept, for the model that reported last; the earlier model reads back clean.
        XCTAssertEqual(store.history(for: "parakeet-v3").strikes, 0)
    }

    // Row 15: unreadable stored data reads as a clean history rather than a lockout or a crash.
    func testCorruptStoredHistoryReadsAsClean() {
        let defaults = isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: ModelPrewarmHistoryStore.defaultKey)
        let history = ModelPrewarmHistoryStore(defaults: defaults).history(for: model)
        XCTAssertEqual(history, ModelPrewarmHistory(modelID: model))
        defaults.set("a string where data belongs", forKey: ModelPrewarmHistoryStore.defaultKey)
        XCTAssertEqual(ModelPrewarmHistoryStore(defaults: defaults).history(for: model), ModelPrewarmHistory(modelID: model))
    }

    // MARK: Scripted sequence

    /// What the code did before this change: one load per foreground whenever nothing was already loading and the
    /// last attempt had finished. Kept here so the comparison below counts the same script both ways.
    private func legacyAttempts(foregrounds: Int) -> Int {
        // Every attempt fails, so nothing is ever loaded and nothing is ever in flight at the next foreground.
        foregrounds
    }

    // Row 16: ten foregrounds in a row, thirty seconds apart, against a loader that always fails.
    func testTenForegroundsWithAFailingLoaderAttemptOneLoad() {
        let defaults = isolatedDefaults()
        let store = ModelPrewarmHistoryStore(defaults: defaults)
        var attempts = 0
        for index in 0..<10 {
            let now = t0.addingTimeInterval(Double(index) * 30)
            let decision = decide(.foreground, history: store.history(for: model), at: now)
            guard decision == .load else { continue }
            attempts += 1
            store.recordFailure(modelID: model, now: now)
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(legacyAttempts(foregrounds: 10), 10)
    }

    // Row 16b: a day of foregrounds against a loader that keeps failing makes a handful of attempts, spaced by the
    // growing wait and ending at the cap.
    func testADayOfForegroundsWithAFailingLoaderStaysWithinTheBackoffSchedule() {
        let store = ModelPrewarmHistoryStore(defaults: isolatedDefaults())
        var attemptTimes: [TimeInterval] = []
        for minute in 0..<(24 * 60) {
            let now = t0.addingTimeInterval(Double(minute) * 60)
            guard decide(.foreground, history: store.history(for: model), at: now) == .load else { continue }
            attemptTimes.append(now.timeIntervalSince(t0))
            store.recordFailure(modelID: model, now: now)
        }
        // Each attempt is followed by the next wait: 5, 10, 20, 40, 80, 160, 320 min, then the 6 h cap twice.
        XCTAssertEqual(attemptTimes, [0, 300, 900, 2_100, 4_500, 9_300, 18_900, 38_100, 59_700, 81_300])
    }

    // Row 17: a clean run. The first foreground loads, the load succeeds, and nine more foregrounds do nothing.
    func testAHealthyInstallLoadsOnceThenLeavesTheModelAlone() {
        let store = ModelPrewarmHistoryStore(defaults: isolatedDefaults())
        var attempts = 0
        for index in 0..<10 {
            let now = t0.addingTimeInterval(Double(index) * 30)
            guard decide(.foreground, history: store.history(for: model), at: now) == .load else { continue }
            attempts += 1
            store.recordLoad(modelID: model, seconds: 2, now: now, stamp: stamp)
        }
        XCTAssertEqual(attempts, 1)
    }
}
