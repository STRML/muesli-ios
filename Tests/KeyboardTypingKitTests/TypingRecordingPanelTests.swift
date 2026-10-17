import XCTest
@testable import KeyboardTypingKit

/// Matrix rows R1-R14: when the large recording panel takes the letter rows, and what it says and does.
final class TypingRecordingPanelTests: XCTestCase {
    private let allPhases: [TypingPillPhase] = [
        .idle, .requested, .recording, .transcribing, .inserting, .copyRequired, .failed, .cancelled,
    ]

    private func panel(
        _ phase: TypingPillPhase,
        layout: KeyboardLayout = .full,
        surface: TypingSurface = .type,
        stop: Bool = false,
        cancel: Bool = false
    ) -> TypingRecordingPanel {
        TypingRecordingPanel.resolve(
            layout: layout, surface: surface, phase: phase, stopRequested: stop, cancelRequested: cancel)
    }

    // R1: recording in Full on the Type page is the panel's one tappable state.
    func testRecordingInFullShowsTheTappablePanel() {
        XCTAssertEqual(panel(.recording), .recording)
        XCTAssertTrue(panel(.recording).isTappable)
    }

    // R2: the mic is not live yet, so the keys stay. This is also the fail-to-start row: requested goes to
    // failed without ever reaching recording.
    func testNothingIsShownBeforeRecordingBegins() {
        XCTAssertEqual(panel(.idle), .hidden)
        XCTAssertEqual(panel(.requested), .hidden)
    }

    // R3: transcribing keeps the panel up, and it is not a button.
    func testTranscribingKeepsThePanelButItIsNotTappable() {
        XCTAssertEqual(panel(.transcribing), .transcribing)
        XCTAssertFalse(panel(.transcribing).isTappable)
    }

    // R4: when the dictation ends, however it ends, the keys come back.
    func testEveryEndOfADictationBringsTheKeysBack() {
        for phase in [TypingPillPhase.inserting, .copyRequired, .failed, .cancelled, .idle] {
            XCTAssertEqual(panel(phase), .hidden, "\(phase)")
        }
    }

    // R5: a second tap, or a tap after the stop went out.
    func testAStopAlreadyOnItsWayMakesThePanelInert() {
        XCTAssertEqual(panel(.recording, stop: true), .stopping)
        XCTAssertFalse(panel(.recording, stop: true).isTappable)
    }

    // R6: the X on the strip while the panel is up.
    func testACancelInFlightMakesThePanelInertAndSaysSo() {
        XCTAssertEqual(panel(.recording, cancel: true), .cancelling)
        XCTAssertEqual(panel(.recording, stop: true, cancel: true), .cancelling)
        XCTAssertEqual(panel(.transcribing, cancel: true), .cancelling)
        XCTAssertFalse(panel(.recording, cancel: true).isTappable)
        XCTAssertFalse(panel(.transcribing, cancel: true).isTappable)
    }

    // R7: Minimal has no Type page and its Dictate page already has the big pill.
    func testMinimalNeverShowsThePanel() {
        for phase in allPhases {
            XCTAssertEqual(panel(phase, layout: .minimal, surface: .dictate), .hidden, "\(phase)")
            XCTAssertEqual(panel(phase, layout: .minimal, surface: .type), .hidden, "\(phase)")
        }
    }

    // R8: Full's Dictate page (reached by the 3 s hold) has its own pill.
    func testFullsDictatePageNeverShowsThePanel() {
        for phase in allPhases {
            XCTAssertEqual(panel(phase, surface: .dictate), .hidden, "\(phase)")
        }
    }

    // R9: the panel stops exactly when the strip pill does, in every phase and flag combination.
    func testThePanelIsTappableExactlyWhenTheStripPillIs() {
        for phase in allPhases {
            for stop in [false, true] {
                for cancel in [false, true] {
                    XCTAssertEqual(
                        panel(phase, stop: stop, cancel: cancel).isTappable,
                        TypingStripPill.isTappable(phase: phase, stopRequested: stop, cancelRequested: cancel),
                        "\(phase) stop=\(stop) cancel=\(cancel)")
                }
            }
        }
    }

    // R10: what it says. The label tells the user the whole panel is the button.
    func testTheRecordingPanelSaysTapAnywhereToStopAndSave() {
        XCTAssertEqual(TypingRecordingPanel.recording.caption(isEdit: false), "Tap anywhere to stop and save")
        XCTAssertEqual(TypingRecordingPanel.recording.caption(isEdit: true), "Speak your change, then tap anywhere")
        XCTAssertEqual(TypingRecordingPanel.recording.accessibilityLabel(isEdit: false), "Stop and save dictation")
        XCTAssertEqual(TypingRecordingPanel.recording.accessibilityLabel(isEdit: true), "Finish voice edit")
        XCTAssertEqual(TypingRecordingPanel.recording.accessibilityHint(isEdit: false), "Stops recording and inserts the text")
        XCTAssertEqual(TypingRecordingPanel.recording.accessibilityHint(isEdit: true), "Stops recording and applies your edit")
    }

    // R11: the inert states say what is happening and offer no hint, because there is nothing to activate.
    func testTheInertStatesDescribeWhatIsHappeningAndOfferNoAction() {
        XCTAssertEqual(TypingRecordingPanel.transcribing.caption(isEdit: false), "Writing your text")
        XCTAssertEqual(TypingRecordingPanel.transcribing.caption(isEdit: true), "Applying your edit")
        XCTAssertEqual(TypingRecordingPanel.stopping.caption(isEdit: false), "Stopping")
        XCTAssertEqual(TypingRecordingPanel.cancelling.caption(isEdit: false), "Cancelling")
        for inert in [TypingRecordingPanel.stopping, .cancelling, .transcribing] {
            XCTAssertNil(inert.accessibilityHint(isEdit: false), "\(inert)")
            XCTAssertFalse(inert.accessibilityLabel(isEdit: false).isEmpty)
        }
    }

    // R12: a very long preview keeps the newest words, on a word boundary, within the limit.
    func testALongPreviewKeepsTheNewestWords() {
        let long = (1...400).map { "word\($0)" }.joined(separator: " ")
        let tail = TypingRecordingPanel.previewTail(long, limit: 100)
        XCTAssertLessThanOrEqual(tail.count, 101)
        XCTAssertTrue(tail.hasPrefix("\u{2026}"))
        XCTAssertTrue(tail.hasSuffix("word400"))
        XCTAssertTrue(tail.dropFirst().first?.isLetter == true, "starts on a whole word: \(tail)")
    }

    func testAShortPreviewIsUntouched() {
        XCTAssertEqual(TypingRecordingPanel.previewTail("hello there", limit: 100), "hello there")
        XCTAssertEqual(TypingRecordingPanel.previewTail("", limit: 100), "")
    }

    func testOneGiantWordIsStillCut() {
        let tail = TypingRecordingPanel.previewTail(String(repeating: "a", count: 5000), limit: 100)
        XCTAssertLessThanOrEqual(tail.count, 101)
        XCTAssertTrue(tail.hasPrefix("\u{2026}"))
    }

    func testTheCutNeverSplitsAnEmoji() {
        let tail = TypingRecordingPanel.previewTail(String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ", count: 100), limit: 50)
        XCTAssertLessThanOrEqual(tail.count, 51)
        XCTAssertTrue(tail.dropFirst().hasPrefix("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"))
    }

    // R13: the panel takes exactly the three rows above the bottom row, so nothing moves and the height holds.
    func testThePanelFillsTheThreeRowsAboveTheBottomRow() {
        XCTAssertEqual(TypingMetrics.panelSlotHeight, 3 * (TypingMetrics.keyHeight + TypingMetrics.rowSpacing))
        XCTAssertEqual(
            TypingMetrics.panelSlotHeight + TypingMetrics.rowSlotHeight,
            Double(TypingMetrics.rowCount) * TypingMetrics.rowSlotHeight)
        XCTAssertEqual(TypingMetrics.preferredHeight, 262)
    }

    // R14: far more than a key. The panel's face is three keys and two gaps tall, wider than the screen minus its
    // margins; 44 pt is the floor.
    func testThePanelIsMuchLargerThanTheStripPill() {
        let face = TypingMetrics.panelSlotHeight - TypingMetrics.rowSpacing
        XCTAssertGreaterThan(face, 3 * TypingStripPill.minimumHitHeight)
        XCTAssertGreaterThanOrEqual(face, 44)
    }
}
