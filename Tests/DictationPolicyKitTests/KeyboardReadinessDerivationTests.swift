import XCTest
@testable import DictationPolicyKit

/// The one state the keyboard shows, derived from what the app published, the heartbeat and the request in play.
/// Rows R01 (fresh install), R11 (every model state, including a 15 minute compile), R13 (what Record does in
/// each state), R16 (Full Access off), R20 (nothing waits forever), R28/R30 (another build, a suspended load).
final class KeyboardReadinessDerivationTests: XCTestCase {
    private typealias F = ReadinessFixtures
    private typealias Derivation = KeyboardReadinessDerivation

    private func derive(
        record: AppReadinessRecord?,
        access: Bool = true,
        request: OwnershipVerdict = .notInProgress,
        checking: TimeInterval? = nil,
        stamp: ReadinessBuildStamp = F.stamp
    ) -> KeyboardReadiness {
        Derivation.derive(KeyboardReadinessInput(
            hasStoreAccess: access,
            record: record,
            keyboardStamp: stamp,
            request: request,
            now: F.t0,
            checkingStartedAt: checking.map { F.t0.addingTimeInterval(-$0) }
        ))
    }

    private func live(
        _ model: ReadinessModelState,
        mic: ReadinessMicState = .ready
    ) -> AppReadinessRecord {
        F.record(heartbeatAge: 1, model: model, mic: mic)
    }

    // MARK: A live app, by model state (R11)

    func testReadyWithAHotMicStartsInPlace() {
        let readiness = derive(record: live(.ready))
        XCTAssertEqual(readiness, KeyboardReadiness(state: .ready, recordAction: .startInPlace, offersEscape: false))
    }

    func testReadyWithoutAHotMicOpensTheAppToStart() {
        for mic in [ReadinessMicState.off, .starting] {
            let readiness = derive(record: live(.ready, mic: mic))
            XCTAssertEqual(readiness.state, .ready)
            XCTAssertEqual(readiness.recordAction, .openAppToStart, "\(mic)")
        }
    }

    // R15: the model let go after a memory warning, or a fresh launch has not loaded it. A load is quick now.
    func testReadyOnDemandReadsAsReady() {
        XCTAssertEqual(derive(record: live(.readyOnDemand)).state, .ready)
        XCTAssertEqual(derive(record: live(.readyOnDemand)).recordAction, .startInPlace)
    }

    func testDownloadingShowsProgressAndRecordOpensTheApp() {
        let readiness = derive(record: live(.downloading(progress: 0.42)))
        XCTAssertEqual(readiness.state, .loading(.downloading, progress: 0.42, elapsed: 0))
        XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
        XCTAssertFalse(readiness.offersEscape)
    }

    func testLoadingShowsElapsedTime() {
        let record = live(.loading(since: F.t0.addingTimeInterval(-40), progress: nil))
        let readiness = derive(record: record)
        XCTAssertEqual(readiness.state, .loading(.preparing, progress: nil, elapsed: 40))
        XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
        XCTAssertFalse(readiness.offersEscape)
    }

    // R11: a 15 minute compile. It is shown for what it is, and past two minutes it offers a way out.
    func testALongCompileOffersAnEscapeButStaysALoad() {
        let record = live(.loading(since: F.t0.addingTimeInterval(-900), progress: 0.5))
        let readiness = derive(record: record)
        XCTAssertEqual(readiness.state, .loading(.preparing, progress: 0.5, elapsed: 900))
        XCTAssertTrue(readiness.offersEscape)
        XCTAssertFalse(derive(record: live(.loading(since: F.t0.addingTimeInterval(-120), progress: nil))).offersEscape)
        XCTAssertTrue(derive(record: live(.loading(since: F.t0.addingTimeInterval(-121), progress: nil))).offersEscape)
    }

    func testALoadThatStartedInTheFutureCountsAsJustStarted() {
        let readiness = derive(record: live(.loading(since: F.t0.addingTimeInterval(500), progress: nil)))
        XCTAssertEqual(readiness.state, .loading(.preparing, progress: nil, elapsed: 0))
    }

    func testMissingModelAsksToOpenTheApp() {
        let readiness = derive(record: live(.notDownloaded))
        XCTAssertEqual(readiness.state, .needsApp(.modelMissing))
        XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
    }

    // R12: the model is on the phone but a cold load is still ahead, or automatic loads are waiting.
    func testAnUnloadedColdModelAsksToOpenTheApp() {
        for model in [ReadinessModelState.notLoaded, .deferredByBackoff(until: F.t0.addingTimeInterval(300))] {
            let readiness = derive(record: live(model))
            XCTAssertEqual(readiness.state, .needsApp(.modelNotLoaded), "\(model)")
            XCTAssertEqual(readiness.recordAction, .openAppToPrepare, "\(model)")
        }
    }

    func testAFailedModelShowsItsReason() {
        for failure in ReadinessModelFailure.allCases {
            let readiness = derive(record: live(.failed(failure)))
            XCTAssertEqual(readiness.state, .failed(failure))
            XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
        }
    }

    // MARK: No live app

    // R01: nothing has ever been published.
    func testAFreshInstallNeedsTheApp() {
        let readiness = derive(record: nil)
        XCTAssertEqual(readiness.state, .needsApp(.neverOpened))
        XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
    }

    func testAFreshInstallIsNeverCheckingBecauseThereIsNothingToWaitFor() {
        XCTAssertEqual(derive(record: nil, checking: 0.1).state, .needsApp(.neverOpened))
    }

    // The common case: the app was killed, the model is fine. One trip, as before.
    func testAKilledAppWithAGoodModelOpensTheAppToStart() {
        let record = F.record(heartbeatAge: 60, model: .ready)
        let readiness = derive(record: record)
        XCTAssertEqual(readiness.state, .needsApp(.appNotRunning))
        XCTAssertEqual(readiness.recordAction, .openAppToStart)
    }

    func testAKilledAppThatHadNotLoadedTheModelNeedsAPrepareTrip() {
        for model in [ReadinessModelState.notLoaded, .deferredByBackoff(until: F.t0), .notDownloaded, .failed(.loadFailed)] {
            let readiness = derive(record: F.record(heartbeatAge: 60, model: model))
            XCTAssertEqual(readiness.state, .needsApp(.appNotRunning), "\(model)")
            XCTAssertEqual(readiness.recordAction, .openAppToPrepare, "\(model)")
        }
    }

    // R30: the app was suspended in the middle of a load. A frozen "Loading 3 min" would be a lie.
    func testASuspendedLoadIsNeverShownAsLoading() {
        let record = F.record(heartbeatAge: 60, model: .loading(since: F.t0.addingTimeInterval(-180), progress: 0.2))
        let readiness = derive(record: record)
        XCTAssertEqual(readiness.state, .needsApp(.loadInterrupted))
        XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
    }

    // R02, R28: the app has not run since an update, whether the heartbeat is stale or from another build.
    func testAnUpdatedAppNeedsAPrepareTrip() {
        for age in [TimeInterval(1), 60] {
            let record = F.record(stamp: F.updatedStamp, heartbeatAge: age, model: .ready)
            let readiness = derive(record: record)
            XCTAssertEqual(readiness.state, .needsApp(.appUpdated), "age \(age)")
            XCTAssertEqual(readiness.recordAction, .openAppToPrepare, "age \(age)")
        }
    }

    // A new OS invalidates the compiled model even though the app is the same build.
    func testANewOSNeedsAPrepareTrip() {
        let record = F.record(stamp: F.newOSStamp, heartbeatAge: 60, model: .ready)
        let readiness = derive(record: record)
        XCTAssertEqual(readiness.state, .needsApp(.appUpdated))
        XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
    }

    func testASkewedHeartbeatReadsAsNoLiveApp() {
        let readiness = derive(record: F.record(heartbeatAge: -3_600, model: .ready))
        XCTAssertEqual(readiness.state, .needsApp(.appNotRunning))
    }

    // R16: without Full Access the store cannot be read, so the keyboard says so and never guesses.
    func testWithoutFullAccessTheStateIsTheSetupState() {
        for record in [nil, live(.ready), F.record(heartbeatAge: 60)] {
            let readiness = derive(record: record, access: false)
            XCTAssertEqual(readiness.state, .needsApp(.fullAccessOff))
            XCTAssertEqual(readiness.recordAction, .openAppToPrepare)
        }
    }

    // MARK: Checking is brief and bounded (R20)

    func testCheckingLastsOnlyForTheWindow() {
        let stale = F.record(heartbeatAge: 60, model: .ready)
        XCTAssertEqual(derive(record: stale, checking: 0).state, .checking)
        XCTAssertEqual(derive(record: stale, checking: 1.49).state, .checking)
        XCTAssertEqual(derive(record: stale, checking: 1.5).state, .needsApp(.appNotRunning))
        XCTAssertEqual(derive(record: stale, checking: 30).state, .needsApp(.appNotRunning))
        XCTAssertEqual(derive(record: stale, checking: nil).state, .needsApp(.appNotRunning))
    }

    func testALiveAppSkipsChecking() {
        XCTAssertEqual(derive(record: live(.ready), checking: 0).state, .ready)
    }

    func testCheckingKeepsTheOpenAppActionSoARecordTapNeverHangs() {
        let readiness = derive(record: F.record(heartbeatAge: 60, model: .ready), checking: 0.2)
        XCTAssertEqual(readiness.recordAction, .openAppToStart)
    }

    // MARK: A request in play

    func testALiveRecordingShowsRecordingEvenWhileTheModelLoads() {
        let record = live(.loading(since: F.t0.addingTimeInterval(-5), progress: nil))
        XCTAssertEqual(derive(record: record, request: .live(.recording)).state, .recording)
    }

    func testEveryLiveStageMapsToItsState() {
        let cases: [(ProgressStage, KeyboardReadinessState)] = [
            (.starting, .starting), (.recording, .recording), (.stopping, .recording), (.transcribing, .transcribing),
        ]
        for (stage, state) in cases {
            XCTAssertEqual(derive(record: live(.ready), request: .live(stage)).state, state, "\(stage)")
            XCTAssertFalse(derive(record: live(.ready), request: .live(stage)).offersEscape, "\(stage)")
            let stalled = derive(record: live(.ready), request: .stalled(stage))
            XCTAssertEqual(stalled.state, state, "\(stage)")
            XCTAssertTrue(stalled.offersEscape, "\(stage)")
        }
    }

    // R10: the keyboard asked and the app has not published yet. Starting, not abandoned and not recording.
    func testAnUnadoptedRequestShowsStartingEvenBeforeTheAppHasPublished() {
        XCTAssertEqual(derive(record: nil, request: .pendingAdoption(.starting)).state, .starting)
        XCTAssertEqual(derive(record: F.record(heartbeatAge: 60), request: .pendingAdoption(.starting)).state, .starting)
        XCTAssertEqual(derive(record: nil, request: .pendingAdoption(.stopping)).state, .recording)
    }

    func testAFreshResultBeingDeliveredShowsWriting() {
        XCTAssertEqual(derive(record: live(.ready), request: .deliverable(isFresh: true)).state, .transcribing)
        XCTAssertEqual(derive(record: F.record(heartbeatAge: 60), request: .deliverable(isFresh: true)).state, .transcribing)
        XCTAssertEqual(derive(record: live(.ready), request: .deliverable(isFresh: false)).state, .ready)
    }

    func testARecoveryPromptOpensTheAppToRecover() {
        let readiness = derive(record: F.record(heartbeatAge: 60), request: .recoveryPrompt)
        XCTAssertEqual(readiness.state, .needsApp(.recovery))
        XCTAssertEqual(readiness.recordAction, .openAppToRecover)
    }

    // R02: an abandoned request is invisible; the state is whatever the app says without it.
    func testAnAbandonedRequestChangesNothing() {
        for reason in AbandonReason.allCases {
            XCTAssertEqual(
                derive(record: live(.ready), request: .abandoned(reason)),
                derive(record: live(.ready), request: .notInProgress)
            )
            XCTAssertEqual(
                derive(record: F.record(heartbeatAge: 60), request: .abandoned(reason)),
                derive(record: F.record(heartbeatAge: 60), request: .notInProgress)
            )
        }
    }

    // MARK: The whole cross product

    // R02-R30: whatever the inputs, the keyboard never says listening, writing or ready without a live owner.
    func testInvariantsOverTheCrossProduct() {
        let models: [ReadinessModelState] = [
            .notDownloaded, .downloading(progress: nil), .downloading(progress: 0.5),
            .loading(since: F.t0.addingTimeInterval(-3), progress: nil),
            .loading(since: F.t0.addingTimeInterval(-900), progress: 0.4),
            .notLoaded, .readyOnDemand, .ready,
            .failed(.loadFailed), .failed(.downloadFailed), .deferredByBackoff(until: F.t0.addingTimeInterval(60)),
        ]
        let heartbeats: [TimeInterval?] = [nil, -3_600, -3, 0, 14.9, 15, 15.1, 600]
        let stamps = [F.stamp, F.updatedStamp, F.newOSStamp]
        let requests: [OwnershipVerdict] = [
            .notInProgress, .deliverable(isFresh: true), .deliverable(isFresh: false), .recoveryPrompt,
            .live(.starting), .live(.recording), .live(.stopping), .live(.transcribing),
            .stalled(.starting), .stalled(.recording), .stalled(.transcribing),
            .pendingAdoption(.starting), .pendingAdoption(.stopping),
            .abandoned(.appRestarted), .abandoned(.ownerLost),
        ]
        var cells = 0
        for access in [true, false] {
            for model in models {
                for mic in ReadinessMicState.allCases {
                    for heartbeat in heartbeats {
                        for stamp in stamps {
                            for request in requests {
                                for checking in [nil, 0.5, 5.0] as [TimeInterval?] {
                                    cells += 1
                                    let record = heartbeat.map { F.record(stamp: stamp, heartbeatAge: $0, model: model, mic: mic) }
                                    check(access: access, record: record, request: request, checking: checking)
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cells, 2 * models.count * 4 * heartbeats.count * stamps.count * requests.count * 3)
    }

    private func check(access: Bool, record: AppReadinessRecord?, request: OwnershipVerdict, checking: TimeInterval?) {
        let readiness = derive(record: record, access: access, request: request, checking: checking)
        let liveness = F.liveness(record)
        let isLive = liveness.liveBootID != nil
        let label = "access=\(access) record=\(String(describing: record?.model)) hb=\(String(describing: liveness.heartbeatAge)) req=\(request) checking=\(String(describing: checking)) -> \(readiness)"

        if !access {
            XCTAssertEqual(readiness.state, .needsApp(.fullAccessOff), label)
            return
        }

        let inProgress: Bool = {
            switch request {
            case .live, .stalled, .pendingAdoption, .deliverable(isFresh: true): true
            default: false
            }
        }()

        switch readiness.state {
        case .recording, .transcribing, .starting:
            XCTAssertTrue(inProgress, label)
        case .ready:
            XCTAssertTrue(isLive && record?.model.isUsable == true && !inProgress, label)
        case .loading, .failed:
            XCTAssertTrue(isLive && !inProgress, label)
        case .checking:
            XCTAssertTrue(record != nil && !isLive && !inProgress, label)
            XCTAssertNotNil(checking, label)
            XCTAssertLessThan(checking ?? .infinity, AppLivenessPolicy.checkingWindow, label)
        case .needsApp:
            break
        }

        // No live app and nothing in flight: only checking or needsApp, never a fake state.
        if !isLive, !inProgress {
            switch readiness.state {
            case .checking, .needsApp: break
            default: XCTFail("fake state without a live app: \(label)")
            }
        }
        // Past the window the state is decided.
        if let checking, checking >= AppLivenessPolicy.checkingWindow, readiness.state == .checking {
            XCTFail("checking never ends: \(label)")
        }
        // Every state that is not in progress has an action that gets the user somewhere.
        if !inProgress { XCTAssertNotEqual(readiness.recordAction, .none, label) }
        // A long load always offers a way out.
        if case let .loading(_, _, elapsed) = readiness.state, elapsed > Derivation.loadingEscapeAfter {
            XCTAssertTrue(readiness.offersEscape, label)
        }
        // Only a hot mic on a ready model starts in place.
        if readiness.recordAction == .startInPlace {
            XCTAssertEqual(readiness.state, .ready, label)
            XCTAssertEqual(record?.mic, .ready, label)
        }
    }
}
