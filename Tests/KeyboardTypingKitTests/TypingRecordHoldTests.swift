import XCTest
@testable import KeyboardTypingKit

/// Matrix rows H1-H10: the Record key's three-second hold, as a press tracker with an injected clock.
final class TypingRecordHoldTests: XCTestCase {
    private var hold = TypingRecordHold()

    private func press(at time: TimeInterval = 100) {
        hold.begin(at: time, x: 20, y: 20)
    }

    // H1
    func testTheHoldIsThreeSeconds() {
        XCTAssertEqual(TypingRecordHold.duration, 3.0)
    }

    // H2
    func testHoldingForTheFullDurationFiresOnce() {
        press()
        XCTAssertTrue(hold.timerFired(at: 103))
        XCTAssertFalse(hold.timerFired(at: 103.5), "fires once per press")
        XCTAssertTrue(hold.hasFired)
    }

    // H3
    func testAWakeShortOfTheDurationDoesNotFire() {
        press()
        XCTAssertFalse(hold.timerFired(at: 101))
        XCTAssertFalse(hold.timerFired(at: 102.9))
        XCTAssertFalse(hold.hasFired)
    }

    func testAClockAHairShortOfTheDurationStillFires() {
        press()
        XCTAssertTrue(hold.timerFired(at: 102.97))
    }

    // H4: a tap
    func testReleasingEarlyIsATap() {
        press()
        XCTAssertEqual(hold.end(), .tap)
        XCTAssertFalse(hold.isPressed)
    }

    func testReleasingJustBeforeTheDurationIsStillATap() {
        press()
        XCTAssertFalse(hold.timerFired(at: 102.9))
        XCTAssertEqual(hold.end(), .tap)
    }

    // H5: the release after a hold is not a tap
    func testReleasingAfterTheHoldFiredIsNotATap() {
        press()
        XCTAssertTrue(hold.timerFired(at: 103))
        XCTAssertEqual(hold.end(), .held)
    }

    // H6: the finger drifts away
    func testMovingFartherThanTheAllowedTravelCancelsTheHold() {
        press()
        hold.move(x: 20 + TypingRecordHold.allowedTravel + 1, y: 20)
        XCTAssertFalse(hold.timerFired(at: 103))
        XCTAssertEqual(hold.end(), .movedAway)
    }

    func testASmallWobbleDoesNotCancelTheHold() {
        press()
        hold.move(x: 24, y: 23)
        XCTAssertTrue(hold.timerFired(at: 103))
    }

    func testMovingAwayAndBackStaysCancelled() {
        press()
        hold.move(x: 200, y: 20)
        hold.move(x: 20, y: 20)
        XCTAssertFalse(hold.timerFired(at: 103))
    }

    func testTheTravelIsMeasuredInBothAxes() {
        press()
        hold.move(x: 20 + 9, y: 20 + 9)
        XCTAssertFalse(hold.timerFired(at: 103), "9 across and 9 down is about 12.7 points")
    }

    // H7: no press, no hold
    func testATimerWithNoPressNeverFires() {
        XCTAssertFalse(hold.timerFired(at: 500))
        XCTAssertEqual(hold.end(), .tap)
    }

    // H8: a release ends the press, so a late timer does nothing
    func testALateTimerAfterReleaseDoesNotFire() {
        press()
        _ = hold.end()
        XCTAssertFalse(hold.timerFired(at: 103))
    }

    // H9: a new press starts clean
    func testANewPressForgetsTheLastOne() {
        press(at: 100)
        hold.move(x: 500, y: 500)
        _ = hold.end()
        press(at: 200)
        XCTAssertTrue(hold.timerFired(at: 203))
    }

    func testAPressThatFiredDoesNotCarryOverToTheNext() {
        press()
        XCTAssertTrue(hold.timerFired(at: 103))
        _ = hold.end()
        press(at: 200)
        XCTAssertEqual(hold.end(), .tap)
    }
}
