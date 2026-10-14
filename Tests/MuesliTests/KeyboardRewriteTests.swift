import XCTest
@testable import Muesli

/// The keyboard half of voice rewrite: the Fix key captures what to rewrite, and a rewrite result is
/// applied only to a field that still holds the text it was made from.
@MainActor
final class KeyboardRewriteTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var bus: StubEventBus!
    private var controller: KeyboardController!
    private var insertedText: [String] = []
    private var deletedCounts: [Int] = []
    private var field = KeyboardTextContext()

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyboard-rewrite-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bus = StubEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        insertedText = []
        deletedCounts = []
        field = KeyboardTextContext()
        controller.textInserter = { [weak self] in self?.insertedText.append($0) }
        controller.textDeleter = { [weak self] in self?.deletedCounts.append($0) }
        controller.textContextProvider = { [weak self] in self?.field ?? KeyboardTextContext() }
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        bus = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func publishRewriteAvailable(_ available: Bool) throws {
        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, supportsBackgroundStart: true, rewriteAvailable: available
        ))
        controller.prepareInitialPresentationState()
    }

    /// The app finished a rewrite: the request, its result and the resultReady handoff are in the store.
    private func deliverRewrite(_ context: RewriteContext, text: String) throws {
        let request = DictationRequest(rewrite: context)
        try store.claimRequest(request)
        try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
        controller.prepareInitialPresentationState()
        try store.saveResult(.init(requestID: request.id, text: text, engineIdentifier: "test", rewrite: context))
        try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .resultReady))
        controller.prepareInitialPresentationState()
    }

    // MARK: Fix key

    func testTheFixKeyRecordsAnInstructionForTheSelection() throws {
        try publishRewriteAvailable(true)
        field = KeyboardTextContext(selectedText: "Is this right?", textBeforeCursor: "Hello. Is this right?")
        controller.startRewrite()
        let pending = try XCTUnwrap(try store.pendingRequest())
        XCTAssertEqual(pending.rewrite, RewriteContext(target: .selection, original: "Is this right?"))
    }

    func testTheFixKeyFallsBackToTheTextBeforeTheCursor() throws {
        try publishRewriteAvailable(true)
        field = KeyboardTextContext(selectedText: nil, textBeforeCursor: "First.\n\nIs this right?")
        controller.startRewrite()
        let pending = try XCTUnwrap(try store.pendingRequest())
        XCTAssertEqual(pending.rewrite, RewriteContext(target: .textBeforeCursor, original: "Is this right?"))
    }

    func testTheFixKeyDoesNothingWhenThereIsNothingToFix() throws {
        try publishRewriteAvailable(true)
        field = KeyboardTextContext()
        controller.startRewrite()
        XCTAssertNil(try store.pendingRequest())
        XCTAssertEqual(controller.statusText, "Nothing to fix")
    }

    func testTheFixKeyRefusesATooLongSelectionBeforeRecording() throws {
        try publishRewriteAvailable(true)
        field = KeyboardTextContext(selectedText: String(repeating: "a", count: RewriteLimits.maximumSelectionCharacters + 1))
        controller.startRewrite()
        XCTAssertNil(try store.pendingRequest())
        XCTAssertEqual(controller.statusText, "Selection too long")
    }

    func testTheFixKeyExplainsWhenNoCustomLLMIsSetUp() throws {
        try publishRewriteAvailable(false)
        field = KeyboardTextContext(selectedText: "Is this right?")
        controller.startRewrite()
        XCTAssertNil(try store.pendingRequest())
        XCTAssertEqual(controller.statusText, "Set up a Custom LLM in Muesli")
        XCTAssertFalse(controller.canRewrite)
    }

    // MARK: Applying a result

    func testARewriteOfTheSelectionIsTypedOverIt() throws {
        let context = RewriteContext(target: .selection, original: "Is this right?")
        field = KeyboardTextContext(selectedText: "Is this right?", textBeforeCursor: "Hello. ")
        try deliverRewrite(context, text: "Is this right.")
        XCTAssertEqual(insertedText, ["Is this right."])
        XCTAssertTrue(deletedCounts.isEmpty)
    }

    func testARewriteOfTheTextBeforeTheCursorDeletesItThenInsertsTheReplacement() throws {
        let context = RewriteContext(target: .textBeforeCursor, original: "Is this right?")
        field = KeyboardTextContext(selectedText: nil, textBeforeCursor: "Hello. Is this right?")
        try deliverRewrite(context, text: "Is this right.")
        XCTAssertEqual(deletedCounts, [14])
        XCTAssertEqual(insertedText, ["Is this right."])
    }

    func testARewriteNeverTouchesAFieldThatChangedMeanwhile() throws {
        let context = RewriteContext(target: .textBeforeCursor, original: "Is this right?")
        field = KeyboardTextContext(selectedText: nil, textBeforeCursor: "Hello. Is this right? And more")
        try deliverRewrite(context, text: "Is this right.")
        XCTAssertTrue(insertedText.isEmpty)
        XCTAssertTrue(deletedCounts.isEmpty)
        XCTAssertEqual(controller.statusText, "Text changed. Nothing replaced")
        XCTAssertTrue(try store.pendingKeyboardDeliveries().isEmpty, "the result must not be retried forever")
    }

    func testAPlainDictationStillInsertsAtTheCursor() throws {
        let request = DictationRequest()
        try store.claimRequest(request)
        try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
        controller.prepareInitialPresentationState()
        try store.saveResult(.init(requestID: request.id, text: "hello", engineIdentifier: "test"))
        try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .resultReady))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(insertedText, ["hello"])
        XCTAssertTrue(deletedCounts.isEmpty)
    }
}
