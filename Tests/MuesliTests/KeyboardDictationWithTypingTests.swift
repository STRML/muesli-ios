import UIKit
import XCTest
@testable import Muesli

/// A host text field the keyboard types into and reads back, the way `UITextDocumentProxy` behaves: an insert
/// shows up in `documentContextBeforeInput` and the host reports a change afterwards.
@MainActor
private final class FakeHostField {
    var text = ""
    let identifier = UUID()
    var onChange: (() -> Void)?

    func insert(_ string: String) {
        text += string
        onChange?()
    }

    func delete(_ count: Int) {
        text = String(text.dropLast(count))
        onChange?()
    }
}

/// The dictation sequence the app and the keyboard walk through together, with the typing model attached to a
/// real-looking host field. The Type page's Record key drives exactly this.
@MainActor
final class KeyboardDictationWithTypingTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var controller: KeyboardController!
    private var host: FakeHostField!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kb-dictation-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bus = StubEventBus()
        store = LiveAppFixture.store(directory: directory, bus: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        host = FakeHostField()
        attachHost()
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        host = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func attachHost() {
        let host = host!
        controller.textInserter = { host.insert($0) }
        controller.textDeleter = { host.delete($0) }
        let document = controller.typing.document
        document.beforeReader = { host.text.isEmpty ? nil : host.text }
        document.afterReader = { nil }
        document.identifierReader = { host.identifier }
        document.selectionReader = { nil }
        controller.typing.setDocumentLanguage("en-US")
        controller.typing.hostDidChange(traits: UITextInputTraitsStub())
    }

    // MARK: - The full sequence

    /// A dictation started from the Type page's Record key: start, recording, stop, transcribing, result.
    func testADictationFromTheTypePageInsertsTheTranscriptAndReturnsToIdle() throws {
        for character in "Hey is just gets stuck" { controller.typing.perform(.character(String(character))) }
        XCTAssertEqual(host.text, "Hey is just gets stuck")

        // The mic session is running, so Record acts in place.
        try store.saveKeyboardRuntimeStatus(.init(isActive: true, supportsBackgroundStart: true))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.recordKeyMode, .action)

        controller.primaryAction()
        let command = try XCTUnwrap(try store.pendingCommand())
        XCTAssertEqual(command.action, .start)
        let request = command.requestID
        XCTAssertEqual(controller.dictationPhase, .requested)

        try appWrites(.startAcknowledged, request)
        try appWrites(.recordingStarted, request)
        try store.saveKeyboardRuntimeStatus(.init(
            isActive: true, activeRequestID: request, phase: .recording, supportsBackgroundStart: true, inputLevel: 0.4
        ))
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.dictationPhase, .recording)

        controller.primaryAction()
        XCTAssertEqual(try store.pendingCommand()?.action, .stop)

        try appWrites(.stopAcknowledged, request)
        try appWrites(.transcribingStarted, request)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.dictationPhase, .transcribing)

        // What deliverKeyboardTranscript does: save the result, the final text, then resultReady.
        try store.saveResult(.init(requestID: request, text: " and now it works.", engineIdentifier: "test"))
        try store.saveKeyboardLiveTranscript(.init(requestID: request, text: " and now it works.", isFinal: true))
        try appWrites(.resultReady, request)
        controller.prepareInitialPresentationState()

        XCTAssertEqual(host.text, "Hey is just gets stuck and now it works.")
        XCTAssertEqual(controller.dictationPhase, .idle, "the keyboard stayed on Writing")
        XCTAssertFalse(controller.showsActiveWaveform)
        XCTAssertEqual(try store.keyboardHandoffState().phase, .inserted)
    }

    private func appWrites(_ phase: KeyboardHandoffPhase, _ request: UUID) throws {
        try store.saveKeyboardHandoffState(.init(requestID: request, phase: phase))
        controller.prepareInitialPresentationState()
    }
}

/// Traits of a plain text field, as `TypingTraits(UITextInputTraits)` reads them.
private final class UITextInputTraitsStub: NSObject, UITextInputTraits {}
