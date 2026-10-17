import XCTest
@testable import DictationPolicyKit

/// What the keyboard's preview strip shows. The strip is display only; insertion is covered in KeyboardControllerTests and live typing in KeyboardLiveTypingTests.
final class KeyboardLivePreviewTests: XCTestCase {
    func testRecordingWithPartialsShowsTheListeningStrip() {
        let preview = KeyboardLivePreview.make(
            isRecording: true, isTranscribing: false, isRewriting: false,
            text: "  the newest words  ", isFinal: false
        )
        XCTAssertEqual(preview, .init(text: "the newest words", phase: .listening))
    }

    func testTheFinalPassDimsTheStripInsteadOfClearingIt() {
        let preview = KeyboardLivePreview.make(
            isRecording: false, isTranscribing: true, isRewriting: false,
            text: "the newest words", isFinal: false
        )
        XCTAssertEqual(preview, .init(text: "the newest words", phase: .finalizing))
    }

    // The app writes the final text as an isFinal live transcript just before resultReady. It must not flash.
    func testFinalTextIsNeverShownAsAPreview() {
        XCTAssertNil(KeyboardLivePreview.make(
            isRecording: false, isTranscribing: true, isRewriting: false,
            text: "Final text.", isFinal: true
        ))
    }

    func testNoPartialsNoStrip() {
        XCTAssertNil(KeyboardLivePreview.make(
            isRecording: true, isTranscribing: false, isRewriting: false, text: " \n", isFinal: false
        ))
    }

    // Idle, finished, failed and cancelled all clear the strip.
    func testTheStripClearsOutsideRecordingAndTranscribing() {
        XCTAssertNil(KeyboardLivePreview.make(
            isRecording: false, isTranscribing: false, isRewriting: false, text: "stale words", isFinal: false
        ))
    }

    // Quill keeps its own edit-target UI; the spoken instruction is not previewed as text to insert.
    func testVoiceEditsKeepTheirOwnStatusInsteadOfAPreview() {
        XCTAssertNil(KeyboardLivePreview.make(
            isRecording: true, isTranscribing: false, isRewriting: true, text: "make it shorter", isFinal: false
        ))
    }

    func testElapsedLabelIsMinutesAndSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(KeyboardLivePreview.elapsedLabel(from: start, to: start.addingTimeInterval(7.9)), "0:07")
        XCTAssertEqual(KeyboardLivePreview.elapsedLabel(from: start, to: start.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(KeyboardLivePreview.elapsedLabel(from: start, to: start.addingTimeInterval(-3)), "0:00")
        XCTAssertEqual(KeyboardLivePreview.elapsedLabel(from: nil, to: start), "0:00")
    }
}
