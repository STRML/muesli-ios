import XCTest
@testable import Muesli

/// The Island must mirror the keyboard mic: when the session is over, the activity is over.
final class KeyboardMicActivityPolicyTests: XCTestCase {
    func testEverySessionEndingEndsTheActivity() {
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .micStopped))
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .stop(.turnedOff)))
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .stop(.off)))
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .stop(.stopped)))
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .standbyStopped(preserveHandoff: false)))
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .standbyStopped(preserveHandoff: true)))
    }

    func testAGivenUpStartEndsTheActivityButARetryDoesNot() {
        XCTAssertTrue(KeyboardMicActivityPolicy.endsActivity(after: .startFailed(message: "denied", recoverable: false)))
        XCTAssertFalse(KeyboardMicActivityPolicy.endsActivity(after: .startFailed(message: "busy", recoverable: true)))
        XCTAssertFalse(KeyboardMicActivityPolicy.endsActivity(after: .retryScheduled(message: "retrying")))
    }

    func testEventsInsideALiveSessionLeaveTheActivityAlone() {
        let id = UUID()
        for event: KeyboardSessionEvent in [
            .micRequested, .startRequested, .startSucceeded, .resumeRequested,
            .handoffStarted(id), .recordingStarted(id), .transcribing(id),
            // The mic is handed to another capture and comes back: the session is paused, not over.
            .requestFinished,
        ] {
            XCTAssertFalse(KeyboardMicActivityPolicy.endsActivity(after: event), "\(event)")
        }
    }
}
