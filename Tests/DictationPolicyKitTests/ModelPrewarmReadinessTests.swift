import XCTest
@testable import DictationPolicyKit

/// The update case and the user-initiated load. Rows R02 (the first load after an update is cold), R05 (a crash
/// during a load is a strike), R11/R15 (the model state the keyboard sees), R12 (a user-initiated load ignores the
/// automatic wait and a success clears it).
final class ModelPrewarmReadinessTests: XCTestCase {
    private typealias Policy = ModelPrewarmPolicy
    private typealias F = ReadinessFixtures

    private let model = "whisper-small-en"
    private let t0 = F.t0
    private let stampA = "0.1.7(40)/27.0"
    private let stampB = "0.1.8(41)/27.0"
    private let stampOS = "0.1.7(40)/27.1"
    private let bootA = UUID()
    private let bootB = UUID()
    private let bootC = UUID()

    private func decide(
        _ trigger: Policy.Trigger,
        stamp: String? = nil,
        loaded: Bool = false,
        inFlight: Bool = false,
        downloaded: Bool = true,
        history: ModelPrewarmHistory,
        at now: Date? = nil
    ) -> Policy.Decision {
        Policy.decide(
            trigger: trigger,
            isDownloaded: downloaded,
            isLoaded: loaded,
            loadInFlight: inFlight,
            history: history,
            stamp: stamp ?? stampA,
            now: now ?? t0
        )
    }

    private func warm(_ stamp: String) -> ModelPrewarmHistory {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordLoad(seconds: 2, now: t0, stamp: stamp)
        return history
    }

    // MARK: The update case (R02)

    // The root cause of the 935 s first dictation: "loaded once" survived the update, so opening the app skipped
    // the warm-up and the cold compile ran inside the first transcription.
    func testAModelLoadedBeforeTheUpdateIsWarmedAgainWhenTheAppOpens() {
        let history = warm(stampA)
        for trigger in [Policy.Trigger.launch, .launchScreen, .foreground] {
            XCTAssertEqual(decide(trigger, stamp: stampA, history: history), .skip(.alreadyWarmedOnce), "\(trigger)")
            XCTAssertEqual(decide(trigger, stamp: stampB, history: history), .load, "\(trigger) after an app update")
            XCTAssertEqual(decide(trigger, stamp: stampOS, history: history), .load, "\(trigger) after an OS update")
        }
    }

    func testTheLoadUnderTheNewBuildMakesItWarmForThatBuildOnly() {
        var history = warm(stampA)
        history.recordLoad(seconds: 2, now: t0, stamp: stampB)
        XCTAssertTrue(history.isWarm(for: stampB))
        XCTAssertFalse(history.isWarm(for: stampA))
        XCTAssertEqual(decide(.launch, stamp: stampB, history: history), .skip(.alreadyWarmedOnce))
    }

    // A record saved before stamps existed says "loaded once" and nothing about when. It is not warm for any build.
    func testARecordFromBeforeStampsIsNotWarm() throws {
        let legacy = Data(#"{"modelID":"whisper-small-en","hasLoadedSuccessfully":true,"strikes":0}"#.utf8)
        let history = try JSONDecoder().decode(ModelPrewarmHistory.self, from: legacy)
        XCTAssertFalse(history.isWarm(for: stampA))
        XCTAssertEqual(decide(.launch, history: history), .load)
    }

    // MARK: A user-initiated load (R12)

    func testAUserRequestedLoadIgnoresTheAutomaticWait() {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordFailure(now: t0)
        history.recordFailure(now: t0)
        let soon = t0.addingTimeInterval(5)
        XCTAssertEqual(decide(.foreground, history: history, at: soon), .skip(.backingOff))
        XCTAssertEqual(decide(.keyboardSession, history: history, at: soon), .skip(.backingOff))
        XCTAssertEqual(decide(.userRequested, history: history, at: soon), .load)
    }

    func testAUserRequestedLoadStillSkipsWhatIsAlreadyDone() {
        let history = ModelPrewarmHistory(modelID: model)
        XCTAssertEqual(decide(.userRequested, loaded: true, history: history), .skip(.alreadyLoaded))
        XCTAssertEqual(decide(.userRequested, inFlight: true, history: history), .skip(.loadInFlight))
        XCTAssertEqual(decide(.userRequested, downloaded: false, history: history), .download)
    }

    func testAUserRequestedLoadIsNotOpportunistic() {
        XCTAssertFalse(Policy.Trigger.userRequested.isOpportunistic)
        XCTAssertTrue(Policy.Trigger.userRequested.bypassesBackoff)
        for trigger in Policy.Trigger.allCases where trigger != .userRequested {
            XCTAssertFalse(trigger.bypassesBackoff, "\(trigger)")
        }
        // Even a warm model is loaded when the user asks.
        XCTAssertEqual(decide(.userRequested, history: warm(stampA)), .load)
    }

    // A successful load the user asked for clears the wait, even a 935 s one that an automatic load would count
    // as a strike.
    func testASuccessfulUserRequestedLoadClearsTheBackoffWhateverItsDuration() {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordFailure(now: t0)
        history.recordFailure(now: t0)
        history.recordLoad(seconds: 935, now: t0.addingTimeInterval(10), stamp: stampA, userInitiated: true)
        XCTAssertEqual(history.strikes, 0)
        XCTAssertNil(history.lastStrikeAt)
        XCTAssertTrue(history.isWarm(for: stampA))
        XCTAssertEqual(decide(.keyboardSession, history: history, at: t0.addingTimeInterval(11)), .load)

        var automatic = ModelPrewarmHistory(modelID: model)
        automatic.recordLoad(seconds: 935, now: t0, stamp: stampA)
        XCTAssertEqual(automatic.strikes, 1)
    }

    // MARK: A crash during a load (R05)

    func testALoadThatNeverFinishedIsAStrikeOnTheNextBoot() {
        var history = ModelPrewarmHistory(modelID: model)
        history.markLoadStarted(boot: bootA, now: t0)
        XCTAssertFalse(history.recoverInterruptedLoad(currentBoot: bootA, now: t0.addingTimeInterval(5)), "same boot")
        XCTAssertEqual(history.strikes, 0)
        XCTAssertTrue(history.recoverInterruptedLoad(currentBoot: bootB, now: t0.addingTimeInterval(20)))
        XCTAssertEqual(history.strikes, 1)
        XCTAssertNil(history.loadMarker)
        XCTAssertFalse(history.recoverInterruptedLoad(currentBoot: bootB, now: t0.addingTimeInterval(21)), "once")
    }

    func testAFinishedLoadLeavesNoMarker() {
        var history = ModelPrewarmHistory(modelID: model)
        history.markLoadStarted(boot: bootA, now: t0)
        history.markLoadFinished()
        XCTAssertFalse(history.recoverInterruptedLoad(currentBoot: bootB, now: t0))
        XCTAssertEqual(history.strikes, 0)
    }

    // A launch loop: the app dies during every load and relaunches a minute later, for a day. The wait grows from
    // five minutes to the six hour cap, so the loop makes ten attempts instead of fourteen hundred.
    func testALaunchLoopBacksOffInsteadOfRetryingForever() {
        var history = ModelPrewarmHistory(modelID: model)
        var attempts: [TimeInterval] = []
        for minute in 0..<(24 * 60) {
            let now = t0.addingTimeInterval(Double(minute) * 60)
            let boot = UUID()
            _ = history.recoverInterruptedLoad(currentBoot: boot, now: now)
            guard decide(.launch, history: history, at: now) == .load else { continue }
            attempts.append(now.timeIntervalSince(t0))
            history.markLoadStarted(boot: boot, now: now)
        }
        XCTAssertEqual(attempts, [0, 360, 1_020, 2_280, 4_740, 9_600, 19_260, 38_520, 60_180, 81_840])
        let now = t0.addingTimeInterval(24 * 3_600)
        XCTAssertEqual(decide(.userRequested, history: history, at: now), .load, "the user can still ask")
    }

    func testTheMarkerSurvivesInTheStore() {
        let name = "ModelPrewarmReadinessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let store = ModelPrewarmHistoryStore(defaults: defaults)
        store.markLoadStarted(modelID: model, boot: bootA, now: t0)
        XCTAssertTrue(ModelPrewarmHistoryStore(defaults: defaults).recoverInterruptedLoad(modelID: model, currentBoot: bootB, now: t0.addingTimeInterval(60)))
        XCTAssertEqual(store.history(for: model).strikes, 1)
        store.markLoadStarted(modelID: model, boot: bootB, now: t0)
        store.markLoadFinished(modelID: model)
        XCTAssertFalse(store.recoverInterruptedLoad(modelID: model, currentBoot: bootC, now: t0))
    }

    // MARK: What the keyboard is told (R11, R15)

    private func resolve(
        _ phase: PreparationPhaseKind,
        progress: Double? = nil,
        since: Date? = nil,
        failure: ReadinessModelFailure? = nil,
        downloaded: Bool = true,
        history: ModelPrewarmHistory? = nil
    ) -> ReadinessModelState {
        ModelReadinessResolver.resolve(
            phase: phase,
            progress: progress,
            loadStartedAt: since,
            failure: failure,
            isDownloaded: downloaded,
            history: history ?? ModelPrewarmHistory(modelID: model),
            stamp: stampA,
            now: t0
        )
    }

    func testEachPreparationPhaseMapsToItsReadinessState() {
        XCTAssertEqual(resolve(.ready), .ready)
        XCTAssertEqual(resolve(.downloading, progress: 0.3, downloaded: false), .downloading(progress: 0.3))
        XCTAssertEqual(resolve(.preparing, progress: 0.6, since: t0.addingTimeInterval(-40)), .loading(since: t0.addingTimeInterval(-40), progress: 0.6))
        XCTAssertEqual(resolve(.preparing), .loading(since: t0, progress: nil))
        XCTAssertEqual(resolve(.failed, failure: .loadFailed), .failed(.loadFailed))
        XCTAssertEqual(resolve(.failed), .failed(.unknown))
    }

    func testAnIdleModelIsMissingColdOrWarm() {
        XCTAssertEqual(resolve(.idle, downloaded: false), .notDownloaded)
        XCTAssertEqual(resolve(.idle), .notLoaded)
        XCTAssertEqual(resolve(.idle, history: warm(stampA)), .readyOnDemand)
    }

    // R15: a model dropped after a memory warning, or not yet loaded by a new launch, is ready on demand when it
    // has loaded under this build and OS, and not when it has not.
    func testReadyOnDemandNeedsALoadUnderThisBuildAndOS() {
        XCTAssertEqual(resolve(.idle, history: warm(stampB)), .notLoaded)
        XCTAssertEqual(resolve(.idle, history: warm(stampOS)), .notLoaded)
    }

    func testAColdModelUnderBackoffIsDeferred() {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordFailure(now: t0)
        XCTAssertEqual(resolve(.idle, history: history), .deferredByBackoff(until: t0.addingTimeInterval(300)))
    }

    // The slow first load left a strike, but the model did compile: the next load is quick, so it is ready.
    func testAWarmModelIsReadyEvenWhileAutomaticLoadsWait() {
        var history = ModelPrewarmHistory(modelID: model)
        history.recordLoad(seconds: 935, now: t0, stamp: stampA)
        XCTAssertEqual(history.strikes, 1)
        XCTAssertEqual(resolve(.idle, history: history), .readyOnDemand)
    }
}
