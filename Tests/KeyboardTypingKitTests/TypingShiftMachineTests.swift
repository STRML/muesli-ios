import XCTest
@testable import KeyboardTypingKit

/// Matrix rows S1-S9: shift, caps lock and auto-capitalize, and how they interact.
final class TypingShiftMachineTests: XCTestCase {
    private var machine = TypingShiftMachine()

    override func setUp() { machine = TypingShiftMachine() }

    // S1
    func testASingleTapShiftsTheNextLetterOnly() {
        machine.tapShift(at: 0)
        XCTAssertEqual(machine.state, .once)
        XCTAssertTrue(machine.isUppercase)
        machine.didInsertCharacter()
        XCTAssertEqual(machine.state, .off)
        XCTAssertFalse(machine.isUppercase)
    }

    // S2
    func testTappingAgainAfterAWhileCancelsTheShift() {
        machine.tapShift(at: 0)
        machine.tapShift(at: 2)
        XCTAssertEqual(machine.state, .off)
    }

    // S3
    func testADoubleTapLocksCaps() {
        machine.tapShift(at: 0)
        machine.tapShift(at: TypingShiftMachine.doubleTapWindow - 0.01)
        XCTAssertEqual(machine.state, .locked)
    }

    // S4
    func testTwoSlowTapsDoNotLock() {
        machine.tapShift(at: 0)
        machine.tapShift(at: TypingShiftMachine.doubleTapWindow + 0.01)
        XCTAssertEqual(machine.state, .off)
    }

    // S5
    func testTappingShiftUnlocksCapsAndAQuickTapDoesNotRelock() {
        machine.tapShift(at: 0)
        machine.tapShift(at: 0.1)
        XCTAssertEqual(machine.state, .locked)
        machine.tapShift(at: 5)
        XCTAssertEqual(machine.state, .off)
        machine.tapShift(at: 5.1)
        XCTAssertEqual(machine.state, .once, "the tap that unlocked must not start a double tap")
    }

    // S6/S7
    func testTypingEndsAShiftButNotCapsLock() {
        machine.tapShift(at: 0)
        machine.tapShift(at: 0.1)
        machine.didInsertCharacter()
        XCTAssertEqual(machine.state, .locked)
    }

    // S8
    func testAutoCapitalizeArmsShiftForOneLetter() {
        machine.autoCapitalize(true)
        XCTAssertEqual(machine.state, .once)
        XCTAssertTrue(machine.isAutomatic)
        machine.didInsertCharacter()
        XCTAssertEqual(machine.state, .off)
        XCTAssertFalse(machine.isAutomatic)
    }

    // S9
    func testTappingShiftCancelsAnAutomaticShift() {
        machine.autoCapitalize(true)
        machine.tapShift(at: 0)
        XCTAssertEqual(machine.state, .off)
        XCTAssertFalse(machine.isAutomatic)
    }

    func testDoubleTappingOnAnAutomaticShiftLocksCaps() {
        machine.autoCapitalize(true)
        machine.tapShift(at: 0)
        machine.tapShift(at: 0.1)
        XCTAssertEqual(machine.state, .locked)
    }

    // S10
    func testAutoCapitalizeNeverChangesCapsLock() {
        machine.tapShift(at: 0)
        machine.tapShift(at: 0.1)
        machine.autoCapitalize(true)
        XCTAssertEqual(machine.state, .locked)
        machine.autoCapitalize(false)
        XCTAssertEqual(machine.state, .locked)
    }

    // S11
    func testAManualShiftSurvivesAnAutoCapitalizeNo() {
        machine.tapShift(at: 0)
        machine.autoCapitalize(false)
        XCTAssertEqual(machine.state, .once)
    }

    // S13
    func testAnAutomaticShiftIsWithdrawnWhenTheContextStopsCalling() {
        machine.autoCapitalize(true)
        machine.autoCapitalize(false)
        XCTAssertEqual(machine.state, .off)
    }
}
