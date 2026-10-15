import XCTest
@testable import Muesli

/// The keyboard mic stays hot between dictations, which costs battery. These are the rules for when it
/// goes off by itself: after a configurable idle time, and always when the screen locks.
final class KeyboardMicAutoOffPolicyTests: XCTestCase {
    private func state(_ phase: KeyboardSessionState.Phase, available: Bool = true, mic: Bool = true) -> KeyboardSessionState {
        var state = KeyboardSessionState()
        state.phase = phase
        state.sessionAvailable = available
        if mic { _ = state.micSession.begin() }
        return state
    }

    // MARK: idle timer

    func testAReadyMicIsTurnedOffAfterTheConfiguredMinutes() {
        XCTAssertEqual(KeyboardMicAutoOff.idleDelay(for: state(.ready), minutes: 10), 600)
        XCTAssertEqual(KeyboardMicAutoOff.idleDelay(for: state(.ready), minutes: 2), 120)
    }

    func testNeverMeansNoIdleTimer() {
        XCTAssertNil(KeyboardMicAutoOff.idleDelay(for: state(.ready), minutes: 0))
    }

    func testOnlyAReadyMicIsOnTheIdleTimer() {
        let busy: [KeyboardSessionState.Phase] = [
            .off, .arming, .handoff(UUID()), .recording(UUID()), .transcribing(UUID()), .retrying("x"), .failed("x"),
        ]
        for phase in busy {
            XCTAssertNil(KeyboardMicAutoOff.idleDelay(for: state(phase), minutes: 10), "\(phase)")
        }
    }

    func testAReadyPhaseWithoutAnAvailableSessionIsNotTimed() {
        XCTAssertNil(KeyboardMicAutoOff.idleDelay(for: state(.ready, available: false), minutes: 10))
    }

    // MARK: screen off

    func testLockingTheScreenTurnsAnIdleMicOffAtOnce() {
        XCTAssertEqual(KeyboardMicAutoOff.screenOffAction(for: state(.ready)), .turnOffNow)
        XCTAssertEqual(KeyboardMicAutoOff.screenOffAction(for: state(.arming, available: false)), .turnOffNow)
    }

    func testLockingTheScreenCancelsAPendingRetryAndTurnsTheMicOff() {
        XCTAssertEqual(KeyboardMicAutoOff.screenOffAction(for: state(.retrying("x"), available: false)), .turnOffNow)
    }

    func testLockingTheScreenDuringADictationLetsItFinishFirst() {
        for phase in [KeyboardSessionState.Phase.handoff(UUID()), .recording(UUID()), .transcribing(UUID())] {
            XCTAssertEqual(KeyboardMicAutoOff.screenOffAction(for: state(phase)), .turnOffWhenIdle, "\(phase)")
        }
    }

    func testLockingTheScreenWithNoKeyboardMicTouchesNothing() {
        XCTAssertEqual(KeyboardMicAutoOff.screenOffAction(for: state(.off, available: false, mic: false)), .ignore)
    }

    // MARK: setting

    func testTheChoicesStartWithNeverAndIncludeTheDefault() {
        XCTAssertEqual(KeyboardMicAutoOff.choices.first, 0)
        XCTAssertTrue(KeyboardMicAutoOff.choices.contains(KeyboardMicAutoOff.defaultMinutes))
    }

    func testAStoredValueOutsideTheChoicesFallsBackToTheDefault() {
        XCTAssertEqual(KeyboardMicAutoOff.resolved(minutes: 5), 5)
        XCTAssertEqual(KeyboardMicAutoOff.resolved(minutes: 0), 0)
        XCTAssertEqual(KeyboardMicAutoOff.resolved(minutes: 7), KeyboardMicAutoOff.defaultMinutes)
        XCTAssertEqual(KeyboardMicAutoOff.resolved(minutes: -3), KeyboardMicAutoOff.defaultMinutes)
    }

    func testTheLabelsAreReadable() {
        XCTAssertEqual(KeyboardMicAutoOff.label(forMinutes: 0), "Never")
        XCTAssertEqual(KeyboardMicAutoOff.label(forMinutes: 5), "5 minutes")
        XCTAssertEqual(KeyboardMicAutoOff.label(forMinutes: 60), "1 hour")
    }
}
