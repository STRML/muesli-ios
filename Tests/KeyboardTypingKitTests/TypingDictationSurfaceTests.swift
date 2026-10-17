import XCTest
@testable import KeyboardTypingKit

/// Matrix rows S1-S10: which page the keyboard shows, given the layout, the remembered page, the dictation phase and
/// whether the user took the Type page back during this dictation. In Full, a dictation shows the Dictate page.
final class TypingDictationSurfaceTests: XCTestCase {
    private let allPhases: [TypingPillPhase] = [
        .idle, .requested, .recording, .transcribing, .inserting, .copyRequired, .failed, .cancelled,
    ]
    private let endings: [TypingPillPhase] = [.idle, .inserting, .copyRequired, .failed, .cancelled]

    private func surface(
        _ phase: TypingPillPhase,
        selected: TypingSurface = .type,
        layout: KeyboardLayout = .full,
        verification: Bool = false,
        holds: Bool = false
    ) -> TypingSurface {
        TypingSurface.resolve(
            layout: layout, selected: selected, hasPendingSetupVerification: verification,
            phase: phase, holdsTypePage: holds)
    }

    // S1: recording switches to the Dictate page.
    func testRecordingShowsTheDictatePage() {
        XCTAssertEqual(surface(.recording), .dictate)
    }

    // S2: not on requested, so a start that fails never flashes the page; and not at rest.
    func testRequestedAndIdleStayOnTheTypePage() {
        XCTAssertEqual(surface(.requested), .type)
        XCTAssertEqual(surface(.idle), .type)
    }

    // S3: the final pass, and the delivery that follows it (the controller maps resultReady to transcribing).
    func testTranscribingStaysOnTheDictatePage() {
        XCTAssertEqual(surface(.transcribing), .dictate)
    }

    // S4: every way a dictation ends returns to the Type page.
    func testEveryEndingReturnsToTheTypePage() {
        for phase in endings {
            XCTAssertEqual(surface(phase), .type, "\(phase)")
        }
    }

    // S5: a user who holds the Dictate page by choice is never moved, in any phase.
    func testAUserOnTheDictatePageByChoiceIsNeverMoved() {
        for phase in allPhases {
            XCTAssertEqual(surface(phase, selected: .dictate), .dictate, "\(phase)")
        }
    }

    // S6: ABC tapped mid-dictation keeps the Type page until the dictation ends.
    func testTheTypePageTakenBackStaysForTheRestOfTheDictation() {
        XCTAssertEqual(surface(.recording, holds: true), .type)
        XCTAssertEqual(surface(.transcribing, holds: true), .type)
        // The flag never moves a user who is on Dictate by choice.
        XCTAssertEqual(surface(.recording, selected: .dictate, holds: true), .dictate)
    }

    // S7: Minimal is the Dictate page in every state.
    func testMinimalIsAlwaysTheDictatePage() {
        for phase in allPhases {
            for selected in [TypingSurface.type, .dictate] {
                for holds in [false, true] {
                    XCTAssertEqual(
                        surface(phase, selected: selected, layout: .minimal, holds: holds), .dictate, "\(phase)")
                }
            }
        }
    }

    // S8: setup verification forces Dictate at rest, as before; a dictation shows it too.
    func testSetupVerificationStillForcesTheDictatePage() {
        XCTAssertEqual(surface(.idle, verification: true), .dictate)
        XCTAssertEqual(surface(.recording, verification: true), .dictate)
        for phase in endings {
            XCTAssertEqual(surface(phase, verification: true), .dictate, "\(phase)")
        }
        // A start still being requested is not forced: the user sees the Type page they were on.
        XCTAssertEqual(surface(.requested, verification: true), .type)
    }

    // S9: the whole table in one place: Full, Type remembered, no hold, no verification.
    func testTheDictatePageIsShownExactlyWhileTheMicIsLiveOrTheFinalPassRuns() {
        for phase in allPhases {
            let expected: TypingSurface = (phase == .recording || phase == .transcribing) ? .dictate : .type
            XCTAssertEqual(surface(phase), expected, "\(phase)")
        }
    }

    // S10: the remembered page is an input only. The rule has nothing to write back.
    func testTheRememberedPageIsNeverTheResultOfTheSwitch() {
        // Same remembered page, two phases, two answers: the answer is derived, not stored.
        XCTAssertNotEqual(surface(.recording), surface(.idle))
    }
}
