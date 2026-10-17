import XCTest
@testable import Muesli

/// The app side of readiness through the real coordinator: what it publishes at launch, what it ends before the
/// keyboard can read it as live, and what the prepare URL does. The coordinator belongs to the app target, so this
/// file speaks the app's own types.
@MainActor
final class CoordinatorReadinessTests: XCTestCase {
    private var directory: URL!
    private var onboardingWasComplete: Bool!
    private let oldBoot = UUID()
    private let onboardingKey = "muesli.onboarding.completed"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coordinator-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        onboardingWasComplete = UserDefaults.standard.bool(forKey: onboardingKey)
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(onboardingWasComplete, forKey: onboardingKey)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var store: Muesli.SharedStore { Muesli.SharedStore(containerURL: directory) }

    private func leave(_ phase: Muesli.KeyboardHandoffPhase, owner: UUID?, age: TimeInterval = 600) throws -> UUID {
        let writer = owner.map { Muesli.SharedStore(containerURL: directory, bootID: $0) } ?? store
        let request = Muesli.DictationRequest()
        try writer.claimRequest(request)
        if phase != .startRequested {
            try writer.saveKeyboardHandoffState(.init(requestID: request.id, phase: phase, updatedAt: Date().addingTimeInterval(-age)))
        }
        return request.id
    }

    func testLaunchPublishesThisBootBeforeAnythingElse() throws {
        let coordinator = DictationCoordinator(store: store)
        let record = try XCTUnwrap(try store.appReadiness())
        XCTAssertEqual(record.mic, .off)
        XCTAssertNotEqual(record.model, .ready)
        XCTAssertEqual(record.stamp, .current)
        XCTAssertLessThan(Date().timeIntervalSince(record.heartbeatAt), 5)
        withExtendedLifetime(coordinator) {}
    }

    // R02: the request an old boot left is ended before the keyboard can read it as live.
    func testLaunchEndsARequestAnOldBootLeft() throws {
        let id = try leave(.recordingStarted, owner: oldBoot)
        let coordinator = DictationCoordinator(store: store)
        let row = try store.keyboardHandoffState()
        XCTAssertEqual(row.requestID, id)
        XCTAssertEqual(row.phase, .failed)
        XCTAssertEqual(row.endReason, "app_restarted")
        XCTAssertNotEqual(row.ownerBootID, try store.appReadiness()?.bootID)
        withExtendedLifetime(coordinator) {}
    }

    // The trap: init runs before onOpenURL. The request the user just tapped Record for is young, unowned and
    // about to be adopted by the URL that launched this process.
    func testLaunchLeavesAYoungUnadoptedStartAlone() throws {
        let id = try leave(.startRequested, owner: nil, age: 1)
        let coordinator = DictationCoordinator(store: store)
        let row = try store.keyboardHandoffState()
        XCTAssertEqual(row.requestID, id)
        XCTAssertEqual(row.phase, .startRequested)
        XCTAssertNil(row.endReason)
        withExtendedLifetime(coordinator) {}
    }

    func testLaunchEndsAStartNobodyTookAfterTheBound() throws {
        let id = try leave(.startRequested, owner: nil)
        try store.saveKeyboardHandoffState(.init(requestID: id, phase: .startRequested, updatedAt: Date().addingTimeInterval(-60)))
        let coordinator = DictationCoordinator(store: store)
        XCTAssertEqual(try store.keyboardHandoffState().endReason, "owner_lost")
        withExtendedLifetime(coordinator) {}
    }

    func testLaunchClearsTheLastBootsRuntimeStatus() throws {
        try store.saveKeyboardRuntimeStatus(.init(isActive: true, activeRequestID: UUID(), phase: .recording))
        let coordinator = DictationCoordinator(store: store)
        XCTAssertNil(try store.keyboardRuntimeStatus())
        withExtendedLifetime(coordinator) {}
    }

    // R27: the prepare URL needs no request id and claims nothing.
    func testThePrepareURLStartsATripAndClaimsNothing() throws {
        let coordinator = DictationCoordinator(store: store)
        coordinator.handleOpenURL(URL(string: "\(MuesliAppConstants.urlScheme)://\(MuesliAppConstants.prepareHost)?trip=\(UUID().uuidString)")!)
        let trip = try XCTUnwrap(coordinator.prepareTrip)
        // On a simulator the model is not downloaded, which the trip reports as its own outcome.
        XCTAssertTrue([.working, .needsDownload].contains(trip.outcome))
        XCTAssertNil(try store.pendingRequest())
        XCTAssertEqual(try store.keyboardHandoffState().phase, .idle)
        coordinator.dismissPrepareTrip()
        XCTAssertNil(coordinator.prepareTrip)
    }

    // R31: Open Muesli from a stuck keyboard ends a request this boot owns but holds nothing for.
    func testOpeningMuesliEndsAZombieThisBootOwns() throws {
        let coordinator = DictationCoordinator(store: store)
        let boot = try XCTUnwrap(try store.appReadiness()?.bootID)
        let id = try leave(.recordingStarted, owner: boot, age: 30)
        coordinator.handleOpenURL(URL(string: "\(MuesliAppConstants.urlScheme)://\(MuesliAppConstants.openHost)")!)
        let row = try store.keyboardHandoffState()
        XCTAssertEqual(row.requestID, id)
        XCTAssertEqual(row.phase, .failed)
        XCTAssertEqual(row.endReason, "owner_lost")
    }

    func testOpeningMuesliLeavesAnotherBootsLiveWorkToTheLaunchRules() throws {
        let coordinator = DictationCoordinator(store: store)
        let id = try leave(.startRequested, owner: nil, age: 1)
        coordinator.handleOpenURL(URL(string: "\(MuesliAppConstants.urlScheme)://\(MuesliAppConstants.openHost)")!)
        XCTAssertEqual(try store.keyboardHandoffState().requestID, id)
        XCTAssertEqual(try store.keyboardHandoffState().phase, .startRequested)
    }
}
