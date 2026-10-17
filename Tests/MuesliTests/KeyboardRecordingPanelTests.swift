import UIKit
import XCTest
@testable import Muesli

/// The large recording panel on the Full keyboard's Type page, through the real `KeyboardController`: when it is
/// up, what its tap does, and what typing still reaches while it is. Row ids (B1..) match the PR's failure matrix.
@MainActor
final class KeyboardRecordingPanelTests: XCTestCase {
    private var d: LiveDictationDriver!

    override func tearDown() async throws {
        d?.tearDown()
        d = nil
        try await super.tearDown()
    }

    private var controller: KeyboardController { d.controller }

    private func make(before: String = "", layout: KeyboardLayout = .full, liveTyping: Bool = true) throws {
        d = try LiveDictationDriver(before: before)
        try d.store.saveKeyboardTypingSettings(
            KeyboardTypingSettings(autocorrect: true, liveTyping: liveTyping, layout: layout))
        controller.loadTypingSettings(appliesLayout: true)
    }

    private func clearCommand() throws {
        try d.store.clearPendingCommand(matching: d.requestID)
    }

    // B1: idle.
    func testIdleShowsTheKeys() throws {
        try make()
        XCTAssertEqual(controller.recordingPanel, .hidden)
    }

    // B2: Record was tapped but the mic is not live yet: the keys stay.
    func testWhileTheStartIsRequestedTheKeysStay() throws {
        try make()
        try d.store.saveKeyboardRuntimeStatus(.init(isActive: true, supportsBackgroundStart: true))
        controller.prepareInitialPresentationState()
        controller.primaryAction()
        XCTAssertEqual(controller.dictationPhase, .requested)
        XCTAssertEqual(controller.recordingPanel, .hidden)
    }

    // B3: recording.
    func testRecordingShowsThePanelOnTheTypePage() throws {
        try make()
        try d.startRecording()
        XCTAssertEqual(controller.surface, .type)
        XCTAssertEqual(controller.recordingPanel, .recording)
        XCTAssertTrue(controller.recordingPanel.isTappable)
    }

    // B4: one tap stops once, like the Record key and the strip pill: same entry point, same guard.
    func testATapOnThePanelSendsOneStopAndTheSecondSendsNone() throws {
        try make()
        try d.startRecording()
        controller.stopFromStatusPill()
        let command = try XCTUnwrap(try d.store.pendingCommand())
        XCTAssertEqual(command.action, .stop)
        XCTAssertEqual(command.requestID, d.requestID)
        XCTAssertEqual(controller.recordingPanel, .stopping)
        try clearCommand()
        controller.stopFromStatusPill()
        XCTAssertNil(try d.store.pendingCommand(), "a double tap sent a second stop")
        controller.primaryAction()
        XCTAssertNil(try d.store.pendingCommand(), "the Record key after the panel sent a second stop")
    }

    // B5: transcribing keeps the panel; it is not tappable and a tap sends nothing, not even a cancel.
    func testTranscribingKeepsThePanelAndIgnoresTaps() throws {
        try make()
        try d.startRecording()
        try d.stopAndTranscribe()
        try clearCommand()
        XCTAssertEqual(controller.dictationPhase, .transcribing)
        XCTAssertEqual(controller.recordingPanel, .transcribing)
        XCTAssertFalse(controller.recordingPanel.isTappable)
        controller.stopFromStatusPill()
        XCTAssertNil(try d.store.pendingCommand())
        XCTAssertEqual(controller.dictationPhase, .transcribing)
    }

    // B6: the X on the strip while the panel is up: the panel goes inert and a tap cannot override the cancel.
    func testCancellingFromTheStripMakesThePanelInert() throws {
        try make()
        try d.startRecording()
        controller.cancelActiveDictation()
        XCTAssertEqual(try d.store.pendingCommand()?.action, .cancel)
        XCTAssertEqual(controller.recordingPanel, .cancelling)
        controller.stopFromStatusPill()
        XCTAssertEqual(try d.store.pendingCommand()?.action, .cancel, "a stop overrode the cancel")
    }

    // B7: the dictation ends, however it ends, and the keys are back.
    func testWhenTheDictationEndsTheKeysComeBack() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("hello world")
        try d.stopAndTranscribe()
        XCTAssertEqual(controller.recordingPanel, .transcribing)
        try d.finish("Hello world.")
        XCTAssertEqual(controller.dictationPhase, .idle)
        XCTAssertEqual(controller.recordingPanel, .hidden)
        XCTAssertEqual(d.document, "Hello Hello world.")
    }

    func testACancelledDictationBringsTheKeysBack() throws {
        try make()
        try d.startRecording()
        controller.cancelActiveDictation()
        try d.appWrites(.cancelled)
        XCTAssertEqual(controller.recordingPanel, .hidden)
    }

    // B8: Quill. The panel's strip slot shows it as an indicator only; a voice edit recording shows the panel too,
    // for the edit, and Quill cannot start a second request under it.
    func testAVoiceEditRecordingShowsThePanelAndQuillStartsNothingUnderIt() throws {
        try make(before: "Fix this sentence please")
        try d.store.saveKeyboardRuntimeStatus(.init(isActive: true, supportsBackgroundStart: true, rewriteAvailable: true))
        controller.prepareInitialPresentationState()
        d.host.model.userSelects(8)
        controller.startRewrite()
        d.requestID = try XCTUnwrap(try d.store.pendingCommand()).requestID
        try d.appWrites(.startAcknowledged)
        try d.appWrites(.recordingStarted)
        try d.store.saveKeyboardRuntimeStatus(.init(
            isActive: true, activeRequestID: d.requestID, phase: .recording,
            supportsBackgroundStart: true, inputLevel: 0.4, rewriteAvailable: true))
        controller.prepareInitialPresentationState()
        XCTAssertNotNil(controller.activeRewrite)
        XCTAssertEqual(controller.recordingPanel, .recording)
        try clearCommand()
        controller.startRewrite()
        XCTAssertNil(try d.store.pendingCommand(), "Quill started a second request under the panel")
        XCTAssertEqual(controller.recordingPanel, .recording)
    }

    // B9: a dictation that fails to start never shows the panel.
    func testADictationThatFailsToStartNeverShowsThePanel() throws {
        try make()
        try d.store.saveKeyboardRuntimeStatus(.init(isActive: true, supportsBackgroundStart: true))
        controller.prepareInitialPresentationState()
        controller.primaryAction()
        d.requestID = try XCTUnwrap(try d.store.pendingCommand()).requestID
        var seen: [TypingRecordingPanel] = [controller.recordingPanel]
        try d.appWrites(.startAcknowledged)
        seen.append(controller.recordingPanel)
        try d.appWrites(.failed)
        seen.append(controller.recordingPanel)
        XCTAssertEqual(Set(seen.map { "\($0)" }), ["hidden"], "\(seen)")
    }

    // B10: the keyboard is hidden and shown again mid-recording: the panel is there when it reappears.
    func testTheKeyboardHiddenAndShownMidRecordingComesBackWithThePanel() throws {
        try make()
        try d.startRecording()
        controller.stopObservingSharedState()
        controller.loadTypingSettings(appliesLayout: true)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.recordingPanel, .recording)
    }

    // B11: the preview text in the panel, live typing on and off.
    func testThePanelShowsTheHeardWordsWhetherOrNotTheyAreTypedLive() throws {
        for liveTyping in [true, false] {
            try make(before: "Hello ", liveTyping: liveTyping)
            try d.startRecording()
            try d.hear("so the plan for tomorrow")
            XCTAssertEqual(controller.recordingPanelPreview, "so the plan for tomorrow", "liveTyping=\(liveTyping)")
            XCTAssertEqual(d.document, liveTyping ? "Hello so the plan for tomorrow" : "Hello ")
            d.tearDown()
        }
    }

    // B12: very long heard text is cut to its newest words.
    func testAVeryLongPreviewIsCutToTheNewestWords() throws {
        try make()
        try d.startRecording()
        let long = (1...600).map { "word\($0)" }.joined(separator: " ")
        try d.hear(long)
        let preview = try XCTUnwrap(controller.recordingPanelPreview)
        XCTAssertLessThanOrEqual(preview.count, 71)
        XCTAssertTrue(preview.hasSuffix("word600"))
        XCTAssertEqual(controller.recordingPanel, .recording)
    }

    func testWithNothingHeardYetThereIsNoPreview() throws {
        try make()
        try d.startRecording()
        XCTAssertNil(controller.recordingPanelPreview)
        XCTAssertEqual(controller.recordingPanel, .recording)
    }

    // B13: what typing still reaches while the panel is up. Letters, shift and backspace are covered by the panel.
    // Space and return stay on the bottom row and still take the dictated words out of the field, as PR 18 says.
    func testSpaceAndReturnStillYieldTheLiveWordsAndTheDictationContinues() throws {
        for (name, key, expected) in [("space", TypingKeyAction.space, "Note "), ("return", .returnKey, "Note\n")] {
            try make(before: "Note")
            try d.startRecording()
            try d.hear("dictated words")
            XCTAssertEqual(d.document, "Notedictated words", name)
            controller.typing.perform(key)
            XCTAssertEqual(d.document, expected, name)
            XCTAssertEqual(controller.recordingPanel, .recording, name)
            XCTAssertEqual(controller.recordingPanelPreview, "dictated words", "\(name): the words stay in the panel")
            try d.stopAndTranscribe()
            try d.finish("Final.")
            XCTAssertEqual(d.document, expected + "Final.", name)
            XCTAssertEqual(controller.recordingPanel, .hidden, name)
            d.tearDown()
        }
    }

    // B13b: the 123 key flips the page under the panel. The bottom row shows ABC, and the number rows are there
    // when the dictation ends.
    func testThePageKeyStillWorksUnderThePanel() throws {
        try make()
        try d.startRecording()
        controller.typing.perform(.switchPage(.numbers))
        XCTAssertEqual(controller.typing.state.page, .numbers)
        XCTAssertEqual(controller.recordingPanel, .recording)
    }

    // B14: Minimal has no panel; its Dictate page keeps the helper row, so a delete key during a dictation still
    // yields the live words (the PR 18 backspace row stays reachable there).
    func testMinimalShowsNoPanelAndItsDeleteKeyStillYields() throws {
        try make(before: "Note", layout: .minimal)
        try d.startRecording()
        try d.hear("dictated words")
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertEqual(controller.recordingPanel, .hidden)
        controller.deleteBackward()
        XCTAssertEqual(d.document, "Not")
        XCTAssertEqual(controller.dictationPhase, .recording)
        try d.stopAndTranscribe()
        try d.finish("Final.")
        XCTAssertEqual(d.document, "NotFinal.")
    }

    // B15: the layout changes between two appearances while a dictation records: the new appearance follows it.
    func testAMinimalLayoutAtTheNextAppearanceHidesThePanelAndTheStopStillWorks() throws {
        try make()
        try d.startRecording()
        XCTAssertEqual(controller.recordingPanel, .recording)
        try d.store.saveKeyboardTypingSettings(KeyboardTypingSettings(autocorrect: true, layout: .minimal))
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.recordingPanel, .hidden)
        XCTAssertEqual(controller.surface, .dictate)
        controller.primaryAction()
        XCTAssertEqual(try d.store.pendingCommand()?.action, .stop)
    }

    // B16: a host with no document identifier (PR 14) must not trap anywhere in a panel dictation.
    func testAHostWithNoDocumentIdentifierCompletesAPanelDictation() throws {
        try make(before: "Hello ")
        controller.typing.document.identifierReader = { nil }
        try d.startRecording()
        try d.hear("hello world")
        XCTAssertEqual(controller.recordingPanel, .recording)
        controller.stopFromStatusPill()
        try d.appWrites(.stopAcknowledged)
        try d.appWrites(.transcribingStarted)
        XCTAssertEqual(controller.recordingPanel, .transcribing)
        try d.finish("Hello world.")
        XCTAssertEqual(controller.recordingPanel, .hidden)
        XCTAssertEqual(d.document, "Hello Hello world.")
    }
}
