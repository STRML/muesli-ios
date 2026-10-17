import XCTest
@testable import DictationPolicyKit

/// Whether a persisted handoff phase still has a live owner. The keyboard shows listening or writing only for
/// `.live`; `.abandoned` is shown as idle and recorded once as terminal. Rows R02a-R02h (a request left by an old
/// boot), R03/R04 (the app was killed), R10 (the keyboard is shown while the app is launching), R20 (bounds),
/// R22 (an owner nobody has adopted yet).
final class RequestOwnershipPolicyTests: XCTestCase {
    private typealias Policy = RequestOwnershipPolicy
    private typealias F = ReadinessFixtures

    private let live = AppLiveness(liveBootID: F.liveBoot, recordedBootID: F.liveBoot, heartbeatAge: 1)
    private let deadRecorded = AppLiveness(liveBootID: nil, recordedBootID: F.liveBoot, heartbeatAge: 40)
    private let noRecord = AppLiveness.none

    private func verdict(
        _ phase: HandoffPhaseKind,
        owner: UUID?,
        age: TimeInterval = 1,
        liveness: AppLiveness
    ) -> OwnershipVerdict {
        Policy.evaluate(
            phase: phase,
            owner: owner,
            updatedAt: F.t0.addingTimeInterval(-age),
            liveness: liveness,
            now: F.t0
        )
    }

    // MARK: Phases that need no owner

    // R02e-R02h: a settled phase from any boot is not in progress, so it is idle and never abandoned.
    func testSettledPhasesAreNeverInProgress() {
        for phase in [HandoffPhaseKind.idle, .inserted, .copyRequired, .cancelled, .failed] {
            for owner in [nil, F.liveBoot, F.oldBoot] {
                for liveness in [live, deadRecorded, noRecord] {
                    XCTAssertEqual(verdict(phase, owner: owner, liveness: liveness), .notInProgress, "\(phase)")
                }
            }
        }
    }

    // R02d: a result that is queued is delivered by the keyboard itself, whoever wrote it. It is not abandoned.
    func testResultReadyNeedsNoOwner() {
        for owner in [nil, F.liveBoot, F.oldBoot] {
            for liveness in [live, deadRecorded, noRecord] {
                XCTAssertEqual(verdict(.resultReady, owner: owner, age: 3, liveness: liveness), .deliverable(isFresh: true))
                XCTAssertEqual(verdict(.resultReady, owner: owner, age: 15, liveness: liveness), .deliverable(isFresh: true))
                XCTAssertEqual(verdict(.resultReady, owner: owner, age: 16, liveness: liveness), .deliverable(isFresh: false))
            }
        }
    }

    // The explicit "Open Muesli to finish" prompt is an honest affordance, not a fake state.
    func testRecoveryRequestedIsAPromptWhoeverOwnsIt() {
        for liveness in [live, deadRecorded, noRecord] {
            XCTAssertEqual(verdict(.recoveryRequested, owner: F.oldBoot, age: 3_600, liveness: liveness), .recoveryPrompt)
        }
    }

    // MARK: Phases that need a live owner

    private let ownerOnly: [(HandoffPhaseKind, ProgressStage)] = [
        (.startAcknowledged, .starting), (.recordingStarted, .recording), (.stopAcknowledged, .transcribing),
        (.audioSaved, .transcribing), (.transcribingStarted, .transcribing),
    ]

    // R02a, R02b: a persisted recordingStarted or transcribingStarted from the old boot, new boot alive.
    func testAnOldBootOwnerIsAbandonedAsRestartedWhileANewBootIsAlive() {
        for (phase, _) in ownerOnly {
            XCTAssertEqual(verdict(phase, owner: F.oldBoot, liveness: live), .abandoned(.appRestarted), "\(phase)")
        }
    }

    // A row written before owners existed has no owner. It cannot be confirmed, so it is abandoned.
    func testARowWithNoOwnerIsAbandoned() {
        for (phase, _) in ownerOnly {
            XCTAssertEqual(verdict(phase, owner: nil, liveness: live), .abandoned(.appRestarted), "\(phase)")
            XCTAssertEqual(verdict(phase, owner: nil, liveness: deadRecorded), .abandoned(.appRestarted), "\(phase)")
            XCTAssertEqual(verdict(phase, owner: nil, liveness: noRecord), .abandoned(.ownerLost), "\(phase)")
        }
    }

    // R03: the app was killed mid-recording. Its boot is the last one recorded and its heartbeat is stale.
    func testTheRecordedBootWithAStaleHeartbeatIsOwnerLost() {
        for (phase, _) in ownerOnly {
            XCTAssertEqual(verdict(phase, owner: F.liveBoot, liveness: deadRecorded), .abandoned(.ownerLost), "\(phase)")
        }
    }

    // R02: after an update, no new boot has run yet. The persisted row names an older boot than the record.
    func testAnOlderBootThanTheRecordIsRestartedEvenWithoutALiveApp() {
        for (phase, _) in ownerOnly {
            XCTAssertEqual(verdict(phase, owner: F.oldBoot, liveness: deadRecorded), .abandoned(.appRestarted), "\(phase)")
        }
    }

    func testWithNoRecordAtAllAnOwnedRequestIsOwnerLost() {
        for (phase, _) in ownerOnly {
            XCTAssertEqual(verdict(phase, owner: F.oldBoot, liveness: noRecord), .abandoned(.ownerLost), "\(phase)")
        }
    }

    func testALiveOwnerIsLiveInEveryStage() {
        for (phase, stage) in ownerOnly {
            XCTAssertEqual(verdict(phase, owner: F.liveBoot, liveness: live), .live(stage), "\(phase)")
        }
    }

    // R20: bounds. A live owner that has sat in a stage past its bound is stalled, so the UI offers an escape.
    func testStagesHaveBounds() {
        XCTAssertEqual(verdict(.startAcknowledged, owner: F.liveBoot, age: 10, liveness: live), .live(.starting))
        XCTAssertEqual(verdict(.startAcknowledged, owner: F.liveBoot, age: 10.5, liveness: live), .stalled(.starting))
        XCTAssertEqual(verdict(.stopRequested, owner: F.liveBoot, age: 8, liveness: live), .live(.stopping))
        XCTAssertEqual(verdict(.stopRequested, owner: F.liveBoot, age: 8.5, liveness: live), .stalled(.stopping))
        XCTAssertEqual(verdict(.cancelRequested, owner: F.liveBoot, age: 9, liveness: live), .stalled(.stopping))
        XCTAssertEqual(verdict(.transcribingStarted, owner: F.liveBoot, age: 120, liveness: live), .live(.transcribing))
        XCTAssertEqual(verdict(.transcribingStarted, owner: F.liveBoot, age: 121, liveness: live), .stalled(.transcribing))
        XCTAssertEqual(verdict(.audioSaved, owner: F.liveBoot, age: 500, liveness: live), .stalled(.transcribing))
        // A recording has no length limit of its own; the heartbeat is its bound.
        XCTAssertEqual(verdict(.recordingStarted, owner: F.liveBoot, age: 3_600, liveness: live), .live(.recording))
    }

    // MARK: Phases the keyboard writes before an app has adopted them

    // R10, R22: the keyboard asked and the app is still launching. Not abandoned, not yet live.
    func testAnUnadoptedStartIsPendingWhileItIsYoung() {
        XCTAssertEqual(verdict(.startRequested, owner: nil, age: 2, liveness: noRecord), .pendingAdoption(.starting))
        XCTAssertEqual(verdict(.startRequested, owner: nil, age: 10, liveness: deadRecorded), .pendingAdoption(.starting))
        XCTAssertEqual(verdict(.startRequested, owner: nil, age: 2, liveness: live), .pendingAdoption(.starting))
    }

    // R03: nobody ever took it.
    func testAnUnadoptedStartWithNoAppIsOwnerLostPastTheBound() {
        XCTAssertEqual(verdict(.startRequested, owner: nil, age: 11, liveness: noRecord), .abandoned(.ownerLost))
        XCTAssertEqual(verdict(.startRequested, owner: nil, age: 11, liveness: deadRecorded), .abandoned(.ownerLost))
    }

    // A live app that did not take it is not dead: the existing retry and recovery handle that.
    func testAnUnadoptedStartWithALiveAppIsStalledPastTheBound() {
        XCTAssertEqual(verdict(.startRequested, owner: nil, age: 11, liveness: live), .stalled(.starting))
    }

    func testAnUnadoptedStopOrCancelFollowsTheStopBound() {
        for phase in [HandoffPhaseKind.stopRequested, .cancelRequested] {
            XCTAssertEqual(verdict(phase, owner: nil, age: 7, liveness: noRecord), .pendingAdoption(.stopping), "\(phase)")
            XCTAssertEqual(verdict(phase, owner: nil, age: 9, liveness: noRecord), .abandoned(.ownerLost), "\(phase)")
            XCTAssertEqual(verdict(phase, owner: nil, age: 9, liveness: live), .stalled(.stopping), "\(phase)")
        }
    }

    // An app that claimed the request itself (the Action Button) owns it from the first write.
    func testAnAppClaimedStartIsOwnedLikeAnyOther() {
        XCTAssertEqual(verdict(.startRequested, owner: F.liveBoot, age: 1, liveness: live), .live(.starting))
        XCTAssertEqual(verdict(.startRequested, owner: F.oldBoot, age: 1, liveness: live), .abandoned(.appRestarted))
        XCTAssertEqual(verdict(.stopRequested, owner: F.liveBoot, age: 1, liveness: live), .live(.stopping))
    }

    // MARK: The whole cross product

    // R02-R22: whatever the inputs, a live or stalled verdict needs a live owner (or an unadopted keyboard write
    // beside a live app), abandonment never touches a phase that needs no owner, and an owner-only phase with an
    // owner that is not the live boot is always abandoned.
    func testInvariantsOverTheCrossProduct() {
        let owners: [UUID?] = [nil, F.liveBoot, F.oldBoot]
        let livenesses = [live, deadRecorded, noRecord]
        let ages: [TimeInterval] = [0, 7, 9.9, 10.1, 30, 130, 1_000, 100_000]
        let ownerFree: Set<HandoffPhaseKind> = [.idle, .inserted, .copyRequired, .cancelled, .failed, .resultReady, .recoveryRequested]
        let keyboardWritten: Set<HandoffPhaseKind> = [.startRequested, .stopRequested, .cancelRequested]
        var cells = 0
        for phase in HandoffPhaseKind.allCases {
            for owner in owners {
                for liveness in livenesses {
                    for age in ages {
                        cells += 1
                        let result = verdict(phase, owner: owner, age: age, liveness: liveness)
                        let label = "\(phase) owner=\(String(describing: owner)) age=\(age)"
                        switch result {
                        case .live:
                            XCTAssertNotNil(owner, label)
                            XCTAssertEqual(owner, liveness.liveBootID, label)
                        case .stalled:
                            XCTAssertNotNil(liveness.liveBootID, label)
                            XCTAssertTrue(owner == liveness.liveBootID || (owner == nil && keyboardWritten.contains(phase)), label)
                        case .abandoned:
                            XCTAssertFalse(ownerFree.contains(phase), label)
                        case .pendingAdoption:
                            XCTAssertNil(owner, label)
                            XCTAssertTrue(keyboardWritten.contains(phase), label)
                        case .notInProgress, .deliverable, .recoveryPrompt:
                            XCTAssertTrue(ownerFree.contains(phase), label)
                        }
                        let isOwnedByLiveBoot = owner != nil && owner == liveness.liveBootID
                        if !ownerFree.contains(phase), !keyboardWritten.contains(phase) || owner != nil,
                           !isOwnedByLiveBoot {
                            guard case .abandoned = result else { return XCTFail("\(label) should be abandoned: \(result)") }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cells, HandoffPhaseKind.allCases.count * 3 * 3 * 8)
    }

    func testEveryHandoffPhaseHasAKind() {
        XCTAssertEqual(HandoffPhaseKind.allCases.count, 15)
    }
}
