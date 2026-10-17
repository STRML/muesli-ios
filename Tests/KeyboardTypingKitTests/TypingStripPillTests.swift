import XCTest
@testable import KeyboardTypingKit

/// Matrix rows P1-P12: when the wide dictation pill in the strip stops and saves the dictation.
final class TypingStripPillTests: XCTestCase {
    private func tappable(
        _ phase: TypingPillPhase, stopRequested: Bool = false, cancelRequested: Bool = false
    ) -> Bool {
        TypingStripPill.isTappable(phase: phase, stopRequested: stopRequested, cancelRequested: cancelRequested)
    }

    // P1-P2: before the mic is live there is nothing to stop.
    func testIdleAndRequestedAreNotTappable() {
        XCTAssertFalse(tappable(.idle))
        XCTAssertFalse(tappable(.requested))
    }

    // P3-P5: the preview text has no bearing; recording is tappable with or without words.
    func testRecordingIsTappable() {
        XCTAssertTrue(tappable(.recording))
    }

    // P6-P7: after the stop there is nothing left to stop, and no second tap may cancel.
    func testTranscribingAndInsertingAreNotTappable() {
        XCTAssertFalse(tappable(.transcribing))
        XCTAssertFalse(tappable(.inserting))
    }

    // P8-P10
    func testSettledPhasesAreNotTappable() {
        XCTAssertFalse(tappable(.copyRequired))
        XCTAssertFalse(tappable(.failed))
        XCTAssertFalse(tappable(.cancelled))
    }

    // P11: a double tap, and a tap after the stop was sent.
    func testAStopAlreadyRequestedDisablesThePill() {
        XCTAssertFalse(tappable(.recording, stopRequested: true))
    }

    // P12: a cancel in flight owns the dictation.
    func testACancelInFlightDisablesThePill() {
        XCTAssertFalse(tappable(.recording, cancelRequested: true))
        XCTAssertFalse(tappable(.recording, stopRequested: true, cancelRequested: true))
    }

    func testTheHitAreaIsAtLeastAKeyHeight() {
        XCTAssertGreaterThanOrEqual(TypingStripPill.minimumHitHeight, TypingMetrics.keyHeight)
        XCTAssertGreaterThanOrEqual(TypingStripPill.minimumHitHeight, 44)
    }
}
