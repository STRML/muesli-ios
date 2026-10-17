import XCTest
import SQLite3
@testable import Muesli

/// Request ownership in the shared store, with two connections standing in for two processes: an app with a boot
/// id and a keyboard without one. Rows R08/R09 (racing abandoners), R22 (owner stamping), R24 (a busy database),
/// R25 (a result that arrives after the request was abandoned).
final class SharedStoreOwnershipTests: XCTestCase {
    private var directory: URL!
    private let bootA = UUID()
    private let bootB = UUID()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func app(_ boot: UUID, bus: StubEventBus = StubEventBus()) -> SharedStore {
        SharedStore(containerURL: directory, eventPoster: bus, bootID: boot)
    }

    private func keyboard(bus: StubEventBus = StubEventBus()) -> SharedStore {
        SharedStore(containerURL: directory, eventPoster: bus)
    }

    // MARK: Owner stamping (R22)

    func testAnAppWriteIsStampedWithItsBoot() throws {
        let store = app(bootA)
        let request = DictationRequest()
        try store.claimRequest(request)
        XCTAssertEqual(try store.keyboardHandoffState().ownerBootID, bootA, "an app claim is owned from the first write")
        try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
        XCTAssertEqual(try store.keyboardHandoffState().ownerBootID, bootA)
    }

    func testAKeyboardClaimIsUnownedUntilAnAppAdoptsIt() throws {
        let request = DictationRequest()
        try keyboard().claimRequest(request)
        XCTAssertNil(try keyboard().keyboardHandoffState().ownerBootID)
        try app(bootA).saveKeyboardHandoffState(.init(requestID: request.id, phase: .startAcknowledged))
        XCTAssertEqual(try keyboard().keyboardHandoffState().ownerBootID, bootA)
    }

    // The keyboard writes stop and cancel as fresh states with no owner. They must not erase the app's.
    func testAKeyboardWriteCarriesTheOwnerForward() throws {
        let request = DictationRequest()
        try app(bootA).claimRequest(request)
        try app(bootA).saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
        let keyboardStore = keyboard()
        for phase in [KeyboardHandoffPhase.stopRequested, .cancelRequested] {
            try keyboardStore.saveKeyboardHandoffState(.init(requestID: request.id, phase: phase))
            XCTAssertEqual(try keyboardStore.keyboardHandoffState().ownerBootID, bootA, "\(phase)")
        }
    }

    // A state the keyboard read a moment ago can carry an owner that has since changed. The row wins.
    func testAKeyboardWriteCannotOverwriteTheOwnerWithAStaleOne() throws {
        let request = DictationRequest()
        try app(bootB).claimRequest(request)
        let stale = KeyboardHandoffState(requestID: request.id, phase: .recoveryRequested, recoveryAction: .stop, ownerBootID: bootA)
        try keyboard().saveKeyboardHandoffState(stale)
        XCTAssertEqual(try keyboard().keyboardHandoffState().ownerBootID, bootB)
    }

    func testRecoveryTakesTheRecoveringBoot() throws {
        let request = DictationRequest()
        try app(bootA).claimRequest(request)
        try app(bootA).saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
        try app(bootB).claimRecovery(request)
        let state = try keyboard().keyboardHandoffState()
        XCTAssertEqual(state.phase, .transcribingStarted)
        XCTAssertEqual(state.ownerBootID, bootB, "or the keyboard would abandon the request being recovered")
    }

    func testAReAdoptedFailedRequestTakesTheNewBoot() throws {
        let request = DictationRequest()
        try app(bootA).claimRequest(request)
        try app(bootA).saveKeyboardHandoffState(.init(requestID: request.id, phase: .failed))
        try app(bootB).claimRequest(request)
        XCTAssertEqual(try keyboard().keyboardHandoffState().ownerBootID, bootB)
        XCTAssertEqual(try keyboard().keyboardHandoffState().phase, .startRequested)
    }

    func testARowFromBeforeOwnersExistedDecodesWithNone() throws {
        let legacy = Data(#"{"requestID":"11111111-1111-1111-1111-111111111111","phase":"recordingStarted","recoveryAttemptCount":0,"createdAt":0,"updatedAt":0}"#.utf8)
        let state = try JSONDecoder().decode(KeyboardHandoffState.self, from: legacy)
        XCTAssertNil(state.ownerBootID)
        XCTAssertNil(state.endReason)
        XCTAssertEqual(state.phase, .recordingStarted)
    }

    // MARK: Abandoning a request (R08, R09, R24, R25)

    private func recording(owner: UUID?) throws -> (UUID, SharedStore) {
        let request = DictationRequest()
        let store = owner.map { app($0) } ?? keyboard()
        try store.claimRequest(request)
        if owner != nil { try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted)) }
        try store.saveCommand(.init(requestID: request.id, action: .stop))
        return (request.id, store)
    }

    func testAbandoningIsTerminalAndCleansUp() throws {
        let (id, _) = try recording(owner: bootA)
        let store = keyboard()
        try store.saveStatus(.init(requestID: id, phase: .recording))
        XCTAssertTrue(try store.abandonRequest(id, expectedOwner: bootA, reason: .appRestarted))
        let state = try store.keyboardHandoffState()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.endReason, "app_restarted")
        XCTAssertEqual(state.ownerBootID, bootA)
        XCTAssertNil(try store.pendingCommand(), "a stale stop must not reach the next owner")
        XCTAssertNil(try store.pendingRequest())
        XCTAssertEqual(try store.status().phase, .failed)
        XCTAssertNoThrow(try store.claimRequest(.init()), "the next dictation is free to start")
    }

    func testAbandoningIsIdempotent() throws {
        let (id, _) = try recording(owner: bootA)
        let store = keyboard()
        XCTAssertTrue(try store.abandonRequest(id, expectedOwner: bootA, reason: .ownerLost))
        XCTAssertFalse(try store.abandonRequest(id, expectedOwner: bootA, reason: .ownerLost))
        XCTAssertEqual(try store.keyboardHandoffState().endReason, "owner_lost")
    }

    func testAbandoningNeedsTheExpectedOwnerAndRequest() throws {
        let (id, _) = try recording(owner: bootA)
        let store = keyboard()
        XCTAssertFalse(try store.abandonRequest(id, expectedOwner: bootB, reason: .appRestarted))
        XCTAssertFalse(try store.abandonRequest(id, expectedOwner: nil, reason: .appRestarted))
        XCTAssertFalse(try store.abandonRequest(UUID(), expectedOwner: bootA, reason: .appRestarted))
        XCTAssertEqual(try store.keyboardHandoffState().phase, .recordingStarted)
    }

    // The phases that need no owner are never abandoned: settled ones are over, a queued result is delivered, and
    // a recovery prompt is an honest affordance.
    func testPhasesThatNeedNoOwnerAreNeverAbandoned() throws {
        for phase in [KeyboardHandoffPhase.inserted, .copyRequired, .cancelled, .failed, .resultReady, .recoveryRequested] {
            let id = UUID()
            let seed = app(bootA)
            try seed.claimRequest(.init(id: id))
            try seed.saveKeyboardHandoffState(.init(requestID: id, phase: phase, recoveryAction: phase == .recoveryRequested ? .stop : nil))
            XCTAssertFalse(try keyboard().abandonRequest(id, expectedOwner: bootA, reason: .appRestarted), "\(phase)")
            XCTAssertEqual(try keyboard().keyboardHandoffState().phase, phase, "\(phase)")
        }
    }

    func testAnUnadoptedStartCanBeAbandonedWithNoOwner() throws {
        let (id, _) = try recording(owner: nil)
        XCTAssertEqual(try keyboard().keyboardHandoffState().phase, .startRequested)
        XCTAssertTrue(try keyboard().abandonRequest(id, expectedOwner: nil, reason: .ownerLost))
    }

    // R08, R09: two keyboards and the app launching all decide at once. Exactly one wins, so the log gets one line.
    func testRacingAbandonersProduceExactlyOneWinner() throws {
        let (id, _) = try recording(owner: bootA)
        let contenders: [SharedStore] = [keyboard(), keyboard(), app(bootB), app(bootB), keyboard(), keyboard()]
        let wins = Locked(0)
        DispatchQueue.concurrentPerform(iterations: contenders.count) { index in
            if (try? contenders[index].abandonRequest(id, expectedOwner: bootA, reason: .appRestarted)) == true {
                wins.mutate { $0 += 1 }
            }
        }
        XCTAssertEqual(wins.value, 1)
        XCTAssertEqual(try keyboard().keyboardHandoffState().phase, .failed)
    }

    // R24: a locked database is "lost": no crash, no second log line, and the next read sees the winner's row.
    func testALockedDatabaseCountsAsLost() throws {
        let (id, _) = try recording(owner: bootA)
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Muesli.sqlite").path, &holder), SQLITE_OK)
        defer { sqlite3_close(holder) }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let result = try keyboard().abandonRequest(id, expectedOwner: bootA, reason: .appRestarted)
        XCTAssertFalse(result)
        sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
        XCTAssertEqual(try keyboard().keyboardHandoffState().phase, .recordingStarted)
    }

    // R25: the app was only suspended and finishes after all. Its result is delivered, not lost.
    func testALateResultForAnAbandonedRequestIsStillDelivered() throws {
        let (id, _) = try recording(owner: bootA)
        XCTAssertTrue(try keyboard().abandonRequest(id, expectedOwner: bootA, reason: .ownerLost))
        let late = app(bootA)
        try late.saveResult(.init(requestID: id, text: "Late words", engineIdentifier: "test"))
        try late.saveKeyboardHandoffState(.init(requestID: id, phase: .resultReady))
        XCTAssertEqual(try keyboard().keyboardHandoffState().phase, .resultReady)
        XCTAssertEqual(try keyboard().pendingKeyboardDeliveries().map(\.text), ["Late words"])
    }

    // MARK: The readiness record

    func testReadinessRoundTripsEveryModelState() throws {
        let boot = AppBootIdentity(id: bootA, startedAt: Date(timeIntervalSince1970: 1_800_000_000), stamp: .init(appVersion: "0.1.7", appBuild: "40", osVersion: "27.0"))
        let states: [ReadinessModelState] = [
            .notDownloaded, .downloading(progress: 0.4), .downloading(progress: nil),
            .loading(since: Date(timeIntervalSince1970: 1_800_000_100), progress: 0.2),
            .notLoaded, .readyOnDemand, .ready, .failed(.loadInterrupted),
            .deferredByBackoff(until: Date(timeIntervalSince1970: 1_800_000_900)),
        ]
        let store = app(bootA)
        for model in states {
            for mic in ReadinessMicState.allCases {
                let record = AppReadinessRecord(boot: boot, heartbeatAt: Date(timeIntervalSince1970: 1_800_000_200), model: model, mic: mic)
                try store.saveAppReadiness(record, notify: false)
                XCTAssertEqual(try keyboard().appReadiness(), record)
            }
        }
    }

    func testOnlyAMaterialChangePostsAnEvent() throws {
        let bus = StubEventBus()
        let store = app(bootA, bus: bus)
        let boot = AppBootIdentity(id: bootA, startedAt: .now, stamp: .init(appVersion: "1", appBuild: "1", osVersion: "27"))
        let record = AppReadinessRecord(boot: boot, heartbeatAt: .now, model: .ready, mic: .ready)
        try store.saveAppReadiness(record, notify: true)
        try store.saveAppReadiness(record, notify: false)
        XCTAssertEqual(bus.postedEvents.filter { $0 == .readinessChanged }.count, 1)
    }

    func testNothingIsPublishedBeforeTheAppRuns() throws {
        XCTAssertNil(try keyboard().appReadiness())
    }

    // MARK: Logging once per change, across instances

    func testALogLineIsWorthWritingOncePerChange() throws {
        let first = keyboard()
        let second = keyboard()
        XCTAssertTrue(try first.noteLogged(topic: "keyboard.readiness", value: "ready"))
        XCTAssertFalse(try second.noteLogged(topic: "keyboard.readiness", value: "ready"), "another instance, same state")
        XCTAssertTrue(try second.noteLogged(topic: "keyboard.readiness", value: "needsApp"))
        XCTAssertFalse(try first.noteLogged(topic: "keyboard.readiness", value: "needsApp"))
        XCTAssertTrue(try first.noteLogged(topic: "handoff.observed", value: "needsApp"), "topics are independent")
        XCTAssertTrue(try first.noteLogged(topic: "keyboard.readiness", value: "ready"), "a change back is a change")
    }

    // MARK: The package and the app agree

    func testTheKitMirrorsTheAppsPhases() {
        XCTAssertEqual(
            KeyboardHandoffPhase.allCases.map(\.rawValue).sorted(),
            HandoffPhaseKind.allCases.map(\.rawValue).sorted()
        )
        for phase in [KeyboardHandoffPhase.idle, .startRequested, .recordingStarted, .resultReady, .cancelled] {
            XCTAssertEqual(phase.kind.rawValue, phase.rawValue)
        }
    }

    func testTheLivenessBoundsAreTheExistingOnes() {
        XCTAssertEqual(AppLivenessPolicy.heartbeatInterval, KeyboardRuntimeStatusPublishPolicy.refreshInterval)
        XCTAssertEqual(AppLivenessPolicy.staleAfter, KeyboardHandoffRecoveryPolicy.keyboardDefaults.runtimeFreshnessInterval)
        let recovery = KeyboardHandoffRecoveryPolicy.keyboardDefaults
        XCTAssertEqual(RequestOwnershipPolicy.startBound, recovery.staleStartInterval)
        XCTAssertEqual(RequestOwnershipPolicy.stopBound, recovery.staleStopRequestInterval)
        XCTAssertEqual(RequestOwnershipPolicy.transcribeBound, recovery.staleTranscribingInterval)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
