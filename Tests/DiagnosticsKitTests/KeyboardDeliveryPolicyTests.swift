import XCTest
@testable import DiagnosticsKit

/// The keyboard is handed the result directly only while its heartbeat is fresh. Each way that fails is a distinct
/// reason, because "copyRequired" alone does not say whether Full Access, visibility or timing was the cause.
final class KeyboardDeliveryPolicyTests: XCTestCase {
    private func decide(open: Bool = true, visible: Bool = true, age: TimeInterval = 0.5) -> KeyboardDeliveryReason {
        KeyboardDeliveryPolicy.decide(.init(hasOpenAccess: open, isVisible: visible, lastSeenAge: age)).reason
    }

    func testAFreshVisibleKeyboardWithFullAccessGetsTheTextDirectly() {
        let decision = KeyboardDeliveryPolicy.decide(.init(hasOpenAccess: true, isVisible: true, lastSeenAge: 0.5))
        XCTAssertTrue(decision.canInsertDirectly)
        XCTAssertEqual(decision.reason, .ok)
    }

    func testNoKeyboardStatusAtAllIsItsOwnReason() {
        let decision = KeyboardDeliveryPolicy.decide(nil)
        XCTAssertFalse(decision.canInsertDirectly)
        XCTAssertEqual(decision.reason, .noExtensionStatus)
    }

    func testMissingFullAccessIsReportedBeforeVisibilityAndHeartbeat() {
        XCTAssertEqual(decide(open: false, visible: false, age: 99), .noOpenAccess)
    }

    func testAHiddenKeyboardIsReportedBeforeAStaleHeartbeat() {
        XCTAssertEqual(decide(visible: false, age: 99), .notVisible)
    }

    func testTheHeartbeatWindowIsExactlyThreePointFiveSeconds() {
        XCTAssertEqual(KeyboardDeliveryPolicy.heartbeatWindow, 3.5)
        XCTAssertEqual(decide(age: 3.4), .ok)
        XCTAssertEqual(decide(age: 3.5), .heartbeatStale)
        XCTAssertEqual(decide(age: 18), .heartbeatStale)
    }

    func testAHeartbeatFromTheFutureCountsAsFreshLikeTheOriginalCheck() {
        // The old inline check was `Date.now.timeIntervalSince(lastSeenAt) < 3.5`, which a clock step backwards made true.
        XCTAssertEqual(decide(age: -30), .ok)
    }
}
