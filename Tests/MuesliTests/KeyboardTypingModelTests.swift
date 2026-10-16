import UIKit
import XCTest
@testable import Muesli

private final class FakeTraits: NSObject, UITextInputTraits {
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var autocorrectionType: UITextAutocorrectionType = .default
    var spellCheckingType: UITextSpellCheckingType = .default
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false
}

/// The keyboard-target half of the typing work: the controller wiring, the UIKit trait mapping and the real
/// `UITextChecker`. The pure logic is covered by KeyboardTypingKitTests on the Mac.
@MainActor
final class KeyboardTypingModelTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var controller: KeyboardController!
    private var inserted: [String] = []
    private var deletes = 0
    private var switches = 0
    private var before = ""

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kb-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bus = StubEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        inserted = []
        deletes = 0
        switches = 0
        before = ""
        controller.textInserter = { [weak self] in self?.inserted.append($0); self?.before += $0 }
        controller.textDeleter = { [weak self] count in
            self?.deletes += count
            if let self { self.before = String(self.before.dropLast(count)) }
        }
        controller.inputModeSwitcher = { [weak self] in self?.switches += 1 }
        controller.typing.document.beforeReader = { [weak self] in
            (self?.before.isEmpty ?? true) ? nil : self?.before
        }
        controller.typing.document.afterReader = { nil }
        controller.typing.document.identifierReader = { nil }
        controller.typing.setDocumentLanguage("en-US")
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func startListening() throws {
        let request = DictationRequest()
        try store.claimRequest(request)
        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, activeRequestID: request.id, phase: .recording, message: "x",
            supportsBackgroundStart: true, inputLevel: 0.5))
        try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
        controller.prepareInitialPresentationState()
    }

    // MARK: Pages and dictation

    /// Matrix row: switching pages mid-dictation keeps the recording and shows it on both.
    func testSwitchingPagesMidDictationKeepsTheRecording() throws {
        try startListening()
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertEqual(controller.surface, .type)
        controller.selectedSurface = .dictate
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertTrue(controller.showsActiveWaveform)
        controller.selectedSurface = .type
        XCTAssertEqual(controller.dictationPhase, .recording)
        XCTAssertTrue(controller.showsActiveWaveform)
    }

    func testTheTypePageIsTheDefault() {
        XCTAssertEqual(controller.selectedSurface, .type)
        XCTAssertEqual(controller.surface, .type)
    }

    /// Matrix row: setup verification pending forces the Dictate page, where the Verify row lives.
    func testPendingSetupVerificationShowsTheDictatePage() {
        let now = Date()
        controller.setupVerificationChallenge = KeyboardSetupVerificationChallenge(
            id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(controller.hasPendingSetupVerification)
        XCTAssertEqual(controller.surface, .dictate)
    }

    /// Matrix row: Record while the mic session is not running opens Muesli, like the Start pill.
    func testRecordOpensMuesliWhenTheMicSessionIsNotRunning() {
        controller.prepareLaunchRequestIfNeeded()
        XCTAssertNotNil(controller.launchURL)
        XCTAssertEqual(controller.opensMuesliFromPrimaryButton, controller.recordKeyMode == .openMuesli)
        XCTAssertEqual(controller.recordKeyMode, .openMuesli, "no runtime status yet, so the app must be opened")
    }

    /// Matrix row: suggestions while recording or transcribing.
    func testSuggestionsStopWhileADictationRuns() throws {
        before = "I will see you tomorrow at the offi"
        controller.typing.hostDidChange(traits: FakeTraits())
        XCTAssertFalse(controller.typing.state.suggestions.isEmpty, "the real checker should complete \"offi\"")
        let suggestion = try XCTUnwrap(controller.typing.state.suggestions.first)

        try startListening()
        XCTAssertEqual(controller.typing.state.suggestions, [])
        controller.typing.accept(suggestion)
        XCTAssertEqual(before, "I will see you tomorrow at the offi", "a suggestion cannot edit while dictating")
    }

    func testTheGlobeKeyCallsTheInputModeSwitch() {
        controller.switchInputMode()
        XCTAssertEqual(switches, 1)
    }

    // MARK: Typing through the controller

    func testTypingRetiresAnUndoEditButLeavesTheStatusAlone() throws {
        controller.typing.perform(.character("a"))
        XCTAssertEqual(inserted, ["a"])
        let status = controller.statusText
        controller.typing.perform(.backspace)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(controller.statusText, status, "typing must not rewrite the dictation status text")
        XCTAssertFalse(controller.canUndoRewrite)
    }

    func testBackspaceAtTheStartOfTheFieldDoesNotCrash() {
        controller.typing.perform(.backspace)
        controller.typing.perform(.backspace)
        XCTAssertEqual(deletes, 2)
    }

    func testTappingASuggestionReplacesThePartialWordThroughTheController() throws {
        before = "I will see you tomorrow at the offi"
        controller.typing.hostDidChange(traits: FakeTraits())
        let suggestion = try XCTUnwrap(controller.typing.state.suggestions.first { $0.kind == .completion })
        controller.typing.accept(suggestion)
        XCTAssertEqual(before, "I will see you tomorrow at the \(suggestion.text) ")
        XCTAssertEqual(deletes, 4)
    }

    // MARK: Traits

    /// Matrix row: secure fields. iOS forces the system keyboard, but late traits must not crash or read text.
    func testASecureFieldNeverShowsSuggestions() {
        before = "hunter"
        let traits = FakeTraits()
        traits.isSecureTextEntry = true
        controller.typing.hostDidChange(traits: traits)
        XCTAssertEqual(controller.typing.state.suggestions, [])
    }

    func testTraitMappingCoversEveryReturnKeyAndKeyboardType() {
        let returnKeys: [UIReturnKeyType] = [
            .default, .go, .google, .join, .next, .route, .search, .send, .yahoo, .done, .emergencyCall, .continue,
        ]
        XCTAssertEqual(
            returnKeys.map { TypingTraits.returnKey($0) },
            [.default, .go, .google, .join, .next, .route, .search, .send, .yahoo, .done, .emergencyCall, .continue]
        )
        XCTAssertEqual(TypingTraits.variant(.emailAddress), .email)
        XCTAssertEqual(TypingTraits.variant(.URL), .url)
        XCTAssertEqual(TypingTraits.variant(.webSearch), .url)
        for numeric in [UIKeyboardType.phonePad, .numberPad, .decimalPad, .numbersAndPunctuation] {
            XCTAssertEqual(TypingTraits.variant(numeric), .numeric)
        }
        XCTAssertEqual(TypingTraits.variant(.default), .standard)
        XCTAssertEqual(TypingTraits.variant(nil), .standard)
        XCTAssertEqual(TypingTraits.autocapitalization(.some(.none)), TypingAutocapitalization.none)
        XCTAssertEqual(TypingTraits.autocapitalization(.words), .words)
        XCTAssertEqual(TypingTraits.autocapitalization(.allCharacters), .allCharacters)
        XCTAssertEqual(TypingTraits.autocapitalization(nil), .sentences)
        XCTAssertEqual(TypingTraits.appearance(.dark), .dark)
        XCTAssertEqual(TypingTraits.appearance(.light), .light)
        XCTAssertEqual(TypingTraits.appearance(.default), .unspecified)
    }

    func testTraitsFromAFieldThatTurnedAutocorrectOff() {
        let traits = FakeTraits()
        traits.autocorrectionType = .no
        XCTAssertTrue(TypingTraits(traits).suggestionsDisabled)
        XCTAssertFalse(TypingTraits(FakeTraits()).suggestionsDisabled)
    }

    // MARK: The real UITextChecker

    func testTheRealCheckerCompletesCorrectsAndSkipsUnsupportedLanguages() {
        let checker = UITextCheckerAdapter()
        XCTAssertTrue(checker.availableLanguages.contains { $0.hasPrefix("en") })
        XCTAssertTrue(checker.isMisspelled("teh", language: "en_US"))
        XCTAssertFalse(checker.isMisspelled("the", language: "en_US"))
        XCTAssertTrue(checker.guesses(forWord: "teh", language: "en_US").contains("the"))
        XCTAssertTrue(checker.completions(forPartial: "offi", language: "en_US").contains("office"))
        XCTAssertNil(TypingLanguageResolver.resolve(candidates: ["xx-YY"], available: checker.availableLanguages))
    }

    /// Simulator figures, not a device ceiling: the cost of the first checker and of one lookup. Run with
    /// MUESLI_MEASURE_CHECKER=1 to print them.
    func testMeasureCheckerCost() throws {
        guard ProcessInfo.processInfo.environment["MUESLI_MEASURE_CHECKER"] != nil
                || FileManager.default.fileExists(atPath: "/tmp/muesli-measure-checker") else {
            throw XCTSkip("set MUESLI_MEASURE_CHECKER=1 to measure")
        }
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return Double(info.phys_footprint) / 1_048_576
        }
        let base = footprint()
        let clock = ContinuousClock()
        var checker: UITextCheckerAdapter?
        let create = clock.measure { checker = UITextCheckerAdapter() }
        let first = clock.measure { _ = checker?.completions(forPartial: "offi", language: "en_US") }
        let afterFirst = footprint()
        let warm = clock.measure { for word in ["hel", "tomor", "mee", "calend", "sche"] { _ = checker?.completions(forPartial: word, language: "en_US") } }
        let guess = clock.measure { _ = checker?.guesses(forWord: "teh", language: "en_US") }
        let afterAll = footprint()
        print("MEASURE checker create=\(create) firstCompletions=\(first) fiveWarmCompletions=\(warm) guesses=\(guess)")
        print("MEASURE footprintMB base=\(base) afterFirstLookup=\(afterFirst) afterWarm=\(afterAll)")
        checker = nil
    }
}
