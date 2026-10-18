import XCTest
@testable import Muesli

/// The Full keyboard shows the Dictate page while a dictation runs and returns to the Type page when it ends, without
/// touching the page the user chose. Row ids (C1..) match the PR's failure matrix.
@MainActor
final class KeyboardDictationSurfaceTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var bus: StubEventBus!
    private var store: SharedStore!
    private var controller: KeyboardController!
    private let requestID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kb-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "kb-surface-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        bus = StubEventBus()
        store = LiveAppFixture.store(directory: directory, bus: bus)
        controller = makeController()
        controller.textInserter = { _ in }
        // These rows describe the switch, so they start with it on; the default is off (see the last tests).
        try publish(.full)
    }

    override func tearDown() async throws {
        controller = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeController() -> KeyboardController {
        KeyboardController(store: store, eventBus: bus, surfaceDefaults: defaults)
    }

    private var rememberedPage: String? { defaults.string(forKey: KeyboardController.selectedSurfaceDefaultsKey) }

    private func enter(_ phase: KeyboardHandoffPhase, runtime: DictationPhase, id: UUID? = nil) throws {
        let id = id ?? requestID
        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, activeRequestID: id, phase: runtime, supportsBackgroundStart: true, inputLevel: 0.4))
        try store.saveKeyboardHandoffState(.init(requestID: id, phase: phase))
        controller.prepareInitialPresentationState()
    }

    private func requestStart(id: UUID? = nil) throws {
        try store.claimRequest(.init(id: id ?? requestID))
        try enter(.startRequested, runtime: .idle, id: id)
    }

    private func startRecording(id: UUID? = nil) throws {
        try requestStart(id: id)
        try enter(.recordingStarted, runtime: .recording, id: id)
    }

    private func publish(_ layout: KeyboardLayout, showsDictatePanel: Bool = true) throws {
        try store.saveKeyboardTypingSettings(
            KeyboardTypingSettings(autocorrect: true, layout: layout, showsDictatePanelWhileRecording: showsDictatePanel)
        )
        controller.loadTypingSettings(appliesLayout: true)
    }

    // C13: the default keeps the Type page for the whole dictation: requested, recording, transcribing.
    func testTheTypePageStaysWhileRecordingWhenTheSwitchIsOff() throws {
        try publish(.full, showsDictatePanel: false)
        try startRecording()
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.surface, .type)
        try enter(.stopAcknowledged, runtime: .transcribing)
        XCTAssertEqual(controller.surface, .type)
        XCTAssertTrue(controller.showsActiveWaveform, "the strip still carries the live status")
    }

    // C14: with the switch off the user can still choose the Dictate page, and it stays.
    func testChoosingTheDictatePageStillWorksWhenTheSwitchIsOff() throws {
        try publish(.full, showsDictatePanel: false)
        controller.selectedSurface = .dictate
        try startRecording()
        XCTAssertEqual(controller.surface, .dictate)
    }

    // C15: no published settings (no Full Access) mean the default: the Type page stays.
    func testWithoutPublishedSettingsTheTypePageStaysWhileRecording() throws {
        let emptyDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kb-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let fresh = KeyboardController(store: LiveAppFixture.store(directory: emptyDirectory, bus: bus), eventBus: bus)
        fresh.loadTypingSettings(appliesLayout: true)
        XCTAssertFalse(fresh.showsDictatePanelWhileRecording)
        XCTAssertEqual(fresh.surface, .type)
    }

    // C16: a settings record from before this choice reads as off, keeping the other choices.
    func testAnOlderSettingsRecordReadsAsOff() throws {
        let old = Data(#"{"autocorrect":false,"liveTyping":false,"layout":"minimal"}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardTypingSettings.self, from: old)
        XCTAssertFalse(decoded.showsDictatePanelWhileRecording)
        XCTAssertFalse(decoded.autocorrect)
        XCTAssertEqual(decoded.layout, .minimal)
        let on = KeyboardTypingSettings(autocorrect: true, showsDictatePanelWhileRecording: true)
        let roundTripped = try JSONDecoder().decode(KeyboardTypingSettings.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(roundTripped, on)
    }

    // C1: recording shows the Dictate page; the remembered page is untouched.
    func testRecordingShowsTheDictatePageWithoutChangingTheRememberedPage() throws {
        controller.selectedSurface = .dictate
        controller.selectedSurface = .type
        XCTAssertEqual(rememberedPage, "type")
        XCTAssertEqual(controller.surface, .type)
        try startRecording()
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertEqual(controller.selectedSurface, .type, "the switch overwrote the user's page")
        XCTAssertEqual(rememberedPage, "type", "the switch was written to the remembered page")
    }

    // C2: a start that is only requested stays on the Type page, and so does one that fails.
    func testARequestedStartAndAFailedStartNeverShowTheDictatePage() throws {
        var seen: [TypingSurface] = [controller.surface]
        try requestStart()
        XCTAssertEqual(controller.dictationPhase, .requested)
        seen.append(controller.surface)
        try enter(.startAcknowledged, runtime: .idle)
        seen.append(controller.surface)
        try enter(.failed, runtime: .idle)
        seen.append(controller.surface)
        XCTAssertEqual(seen, [.type, .type, .type, .type])
    }

    // C3: the final pass and the delivery stay on the Dictate page.
    func testTranscribingAndTheDeliveryStayOnTheDictatePage() throws {
        try startRecording()
        try enter(.stopAcknowledged, runtime: .transcribing)
        XCTAssertEqual(controller.surface, .dictate)
        try enter(.transcribingStarted, runtime: .transcribing)
        XCTAssertEqual(controller.surface, .dictate)
        try store.saveResult(.init(requestID: requestID, text: "Hello.", engineIdentifier: "test"))
        try enter(.resultReady, runtime: .transcribing)
        // resultReady delivers the text and moves the handoff to inserted in the same refresh.
        XCTAssertEqual(try store.keyboardHandoffState().phase, .inserted)
    }

    // C4: every ending returns to the Type page: inserted, failed, cancelled, copy required.
    func testEveryEndingReturnsToTheTypePage() throws {
        for ending in [KeyboardHandoffPhase.inserted, .failed, .cancelled, .copyRequired] {
            let id = UUID()
            try startRecording(id: id)
            XCTAssertEqual(controller.surface, .dictate, "\(ending) while recording")
            if ending == .inserted {
                try store.saveResult(.init(requestID: id, text: "Hello.", engineIdentifier: "test"))
            }
            try enter(ending, runtime: .idle, id: id)
            XCTAssertEqual(controller.surface, .type, "\(ending)")
            XCTAssertFalse(controller.showsActiveWaveform, "\(ending)")
        }
    }

    // C5: the keyboard hidden and shown again mid-recording comes back on the Dictate page.
    func testTheKeyboardHiddenAndShownMidRecordingComesBackOnTheDictatePage() throws {
        try startRecording()
        controller.stopObservingSharedState()
        controller.loadTypingSettings(appliesLayout: true)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.surface, .dictate)
        let reopened = makeController()
        reopened.loadTypingSettings(appliesLayout: true)
        reopened.prepareInitialPresentationState()
        XCTAssertEqual(reopened.dictationPhase, .recording)
        XCTAssertEqual(reopened.surface, .dictate)
        XCTAssertEqual(reopened.selectedSurface, .type)
    }

    // C6: the user is on Dictate by choice: nothing moves, before, during or after.
    func testAUserOnTheDictatePageByChoiceStaysThere() throws {
        controller.selectedSurface = .dictate
        XCTAssertEqual(controller.surface, .dictate)
        try startRecording()
        XCTAssertEqual(controller.surface, .dictate)
        try enter(.stopAcknowledged, runtime: .transcribing)
        XCTAssertEqual(controller.surface, .dictate)
        try store.saveResult(.init(requestID: requestID, text: "Hello.", engineIdentifier: "test"))
        try enter(.inserted, runtime: .idle)
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertEqual(rememberedPage, "dictate")
    }

    // C7: ABC tapped mid-recording is honoured for the rest of that dictation, then the next one switches again.
    func testABCTappedMidRecordingKeepsTheTypePageUntilTheNextDictation() throws {
        try startRecording()
        XCTAssertEqual(controller.surface, .dictate)
        controller.showTypePage()
        XCTAssertEqual(controller.surface, .type)
        try enter(.stopAcknowledged, runtime: .transcribing)
        XCTAssertEqual(controller.surface, .type, "the tap was undone when the final pass began")
        try store.saveResult(.init(requestID: requestID, text: "Hello.", engineIdentifier: "test"))
        try enter(.inserted, runtime: .idle)
        XCTAssertEqual(controller.surface, .type)

        let next = UUID()
        try startRecording(id: next)
        XCTAssertEqual(controller.surface, .dictate, "the next dictation did not switch")
    }

    // C7b: ABC on a Dictate page the user chose is a normal page choice, remembered as ever, and held for the dictation.
    func testABCFromADictatePageChosenByTheUserGoesToTheTypePage() throws {
        controller.selectedSurface = .dictate
        try startRecording()
        controller.showTypePage()
        XCTAssertEqual(controller.surface, .type)
        XCTAssertEqual(rememberedPage, "type")
        try enter(.stopAcknowledged, runtime: .transcribing)
        XCTAssertEqual(controller.surface, .type)
    }

    // C7c: ABC at rest is just the page choice.
    func testABCAtRestIsAPlainPageChoice() throws {
        controller.selectedSurface = .dictate
        controller.showTypePage()
        XCTAssertEqual(controller.surface, .type)
        XCTAssertEqual(rememberedPage, "type")
    }

    // C8: setup verification forces Dictate before, during and after a dictation. (The presentation refresh reads the
    // challenge back from its own store, which this test does not fill, so it is set again after each step.)
    func testSetupVerificationShowsTheDictatePageThroughout() throws {
        func verify() {
            let now = Date()
            controller.setupVerificationChallenge = KeyboardSetupVerificationChallenge(
                id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(600))
        }
        verify()
        XCTAssertEqual(controller.surface, .dictate)
        try requestStart()
        verify()
        XCTAssertEqual(controller.surface, .type, "a start still being requested is not forced")
        try enter(.recordingStarted, runtime: .recording)
        verify()
        XCTAssertEqual(controller.surface, .dictate)
        try store.saveResult(.init(requestID: requestID, text: "Hello.", engineIdentifier: "test"))
        try enter(.inserted, runtime: .idle)
        verify()
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertNil(rememberedPage)
    }

    // C9: Minimal is unaffected: the Dictate page throughout, ABC offers nothing and writes nothing.
    func testMinimalIsUnaffected() throws {
        try publish(.minimal)
        XCTAssertEqual(controller.surface, .dictate)
        try startRecording()
        XCTAssertEqual(controller.surface, .dictate)
        controller.showTypePage()
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertNil(rememberedPage)
        try store.saveResult(.init(requestID: requestID, text: "Hello.", engineIdentifier: "test"))
        try enter(.inserted, runtime: .idle)
        XCTAssertEqual(controller.surface, .dictate)
    }

    // C10: the layout changes at the next appearance while a dictation records: Full's switch simply stops applying.
    func testMinimalAtTheNextAppearanceMidRecordingStaysOnTheDictatePage() throws {
        try startRecording()
        XCTAssertEqual(controller.surface, .dictate)
        try publish(.minimal)
        XCTAssertEqual(controller.surface, .dictate)
        try publish(.full)
        XCTAssertEqual(controller.surface, .dictate, "still recording")
    }

    // C11: the 3 s hold opens Dictate as before (idle only) and is remembered.
    func testTheHoldStillOpensTheDictatePageAndIsRemembered() throws {
        controller.selectedSurface = .dictate  // what TypingRecordKeyControl.holdElapsed does
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertEqual(rememberedPage, "dictate")
    }
}

/// What typing reaches during a dictation now that the Full keyboard shows the Dictate page for it: the Dictate
/// page's punctuation, space, return and delete keys. Letters are not there; ABC brings them back for that dictation.
@MainActor
final class KeyboardDictationSurfaceTypingTests: XCTestCase {
    private var d: LiveDictationDriver!

    override func tearDown() async throws {
        d?.tearDown()
        d = nil
        try await super.tearDown()
    }

    private func make(before: String = "Note") throws {
        d = try LiveDictationDriver(before: before)
    }

    // D1: each Dictate-page key takes the live words out of the field and the dictation continues strip-only.
    func testTheDictatePagesKeysStillYieldTheLiveWords() throws {
        let keys: [(String, (KeyboardController) -> Void, String)] = [
            ("space", { $0.insertSpace() }, "Note "),
            ("return", { $0.insertReturn() }, "Note\n"),
            ("punctuation", { $0.insertTextKey(",") }, "Note,"),
        ]
        for (name, press, expected) in keys {
            try make()
            try d.startRecording()
            XCTAssertEqual(d.controller.surface, .dictate, name)
            try d.hear("dictated words")
            XCTAssertEqual(d.document, "Notedictated words", name)
            press(d.controller)
            XCTAssertEqual(d.document, expected, name)
            XCTAssertEqual(d.controller.dictationPhase, .recording, name)
            XCTAssertEqual(d.controller.livePreview?.text, "dictated words", "\(name): the words stay in the strip")
            try d.stopAndTranscribe()
            XCTAssertEqual(d.controller.surface, .dictate, name)
            try d.finish("Final.")
            XCTAssertEqual(d.document, expected + "Final.", name)
            XCTAssertEqual(d.controller.surface, .type, name)
            d.tearDown()
        }
    }

    // D1b: the delete key takes back the last dictated word, and the dictation stays in the field.
    func testTheDictatePagesDeleteKeyTakesBackTheLastDictatedWord() throws {
        try make()
        try d.startRecording()
        try d.hear("dictated words")
        d.controller.deleteBackward()
        XCTAssertEqual(d.document, "Notedictated")
        XCTAssertEqual(d.controller.dictationPhase, .recording)
        XCTAssertNil(d.controller.livePreview, "the words are in the field, not the strip")
        try d.stopAndTranscribe()
        try d.finish("Dictated words.")
        XCTAssertEqual(d.document, "Notedictated.", "the final keeps the edit and the punctuation after the deleted slot")
    }

    // D2: letters are on the Type page only. ABC mid-recording brings them back, and a typed letter then yields as in PR 18.
    func testALetterTypedAfterABCMidRecordingYieldsAsBefore() throws {
        try make(before: "")
        try d.startRecording()
        try d.hear("hello wor")
        XCTAssertEqual(d.document, "hello wor")
        d.controller.showTypePage()
        XCTAssertEqual(d.controller.surface, .type)
        d.controller.typing.perform(.character("x"))
        XCTAssertEqual(d.document, "x")
        try d.hear("hello world")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.document, "xHello world.")
        XCTAssertEqual(d.controller.surface, .type)
    }

    // D3: a host with no document identifier (PR 14) completes a whole switched dictation without trapping.
    func testAHostWithNoDocumentIdentifierCompletesASwitchedDictation() throws {
        try make(before: "Hello ")
        d.controller.typing.document.identifierReader = { nil }
        try d.startRecording()
        XCTAssertEqual(d.controller.surface, .dictate)
        try d.hear("hello world")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.controller.surface, .type)
        XCTAssertEqual(d.document, "Hello Hello world.")
    }

    // D4: live typing off (strip only): same switch, the final inserted once.
    func testWithLiveTypingOffTheSwitchIsTheSame() throws {
        try make(before: "Hello ")
        try d.store.saveKeyboardTypingSettings(
            KeyboardTypingSettings(autocorrect: true, liveTyping: false, showsDictatePanelWhileRecording: true)
        )
        d.controller.loadTypingSettings(appliesLayout: true)
        try d.startRecording()
        try d.hear("so the plan")
        XCTAssertEqual(d.controller.surface, .dictate)
        XCTAssertEqual(d.document, "Hello ")
        try d.stopAndTranscribe()
        try d.finish("So the plan.")
        XCTAssertEqual(d.document, "Hello So the plan.")
        XCTAssertEqual(d.controller.surface, .type)
    }
}
