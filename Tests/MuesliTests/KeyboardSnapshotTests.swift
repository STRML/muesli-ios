import XCTest
import SwiftUI
@testable import Muesli

/// A dev tool, not a regression test: renders the keyboard panel in each state to PNGs so the layout can be
/// reviewed without a phone. Skipped unless `MUESLI_KEYBOARD_SNAPSHOT_DIR` (or the file
/// `/tmp/muesli-keyboard-snapshot-dir`) names a directory.
///
///     MUESLI_KEYBOARD_SNAPSHOT_DIR=/tmp/kb xcodebuild test ... -only-testing:MuesliTests/KeyboardSnapshotTests
@MainActor
final class KeyboardSnapshotTests: XCTestCase {
    private enum Setup {
        case ready
        case listening
        case transcribing
        case editListening
        case editTranscribing
        case undoAvailable
    }

    private struct Scene {
        let name: String
        let setup: Setup
        let rewriteAvailable: Bool
    }

    private let editText = "Next Amazon order, I want to get a desk mat, a rack for my Mac minis, and a holder for my pen holders."

    private func makeController(_ scene: Scene) throws -> KeyboardController {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let bus = StubEventBus()
        let store = SharedStore(containerURL: temp, eventPoster: bus)
        let controller = KeyboardController(store: store, eventBus: bus)
        var field = KeyboardTextContext(selectedText: nil, textBeforeCursor: editText)
        controller.textContextProvider = { field }
        controller.textInserter = { _ in }
        controller.textDeleter = { _ in }

        func publish(_ phase: DictationPhase, requestID: UUID?) throws {
            try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
                isActive: true, activeRequestID: requestID, phase: phase, message: "x",
                supportsBackgroundStart: true, inputLevel: 0.6, rewriteAvailable: scene.rewriteAvailable))
        }

        switch scene.setup {
        case .ready:
            try publish(.idle, requestID: nil)
            controller.prepareInitialPresentationState()
        case .listening, .transcribing:
            let request = DictationRequest()
            try store.claimRequest(request)
            let recording = scene.setup == .listening
            try publish(recording ? .recording : .transcribing, requestID: request.id)
            try store.saveKeyboardHandoffState(.init(
                requestID: request.id, phase: recording ? .recordingStarted : .transcribingStarted))
            controller.prepareInitialPresentationState()
        case .editListening, .editTranscribing:
            try publish(.idle, requestID: nil)
            controller.prepareInitialPresentationState()
            controller.startRewrite()
            let request = try XCTUnwrap(try store.pendingRequest())
            let recording = scene.setup == .editListening
            try publish(recording ? .recording : .transcribing, requestID: request.id)
            try store.saveKeyboardHandoffState(.init(
                requestID: request.id, phase: recording ? .recordingStarted : .transcribingStarted))
            controller.prepareInitialPresentationState()
        case .undoAvailable:
            try publish(.idle, requestID: nil)
            let context = RewriteContext(target: .textBeforeCursor, original: editText)
            let request = DictationRequest(rewrite: context)
            try store.claimRequest(request)
            try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .recordingStarted))
            controller.prepareInitialPresentationState()
            try store.saveResult(.init(
                requestID: request.id, text: "Next Amazon order, I want to get:\n- a desk mat",
                engineIdentifier: "test", rewrite: context))
            try store.saveKeyboardHandoffState(.init(requestID: request.id, phase: .resultReady))
            controller.prepareInitialPresentationState()
            field = KeyboardTextContext()
        }
        return controller
    }

    func testRenderKeyboardStates() throws {
        let environment = ProcessInfo.processInfo.environment
        let fileValue = (try? String(contentsOfFile: "/tmp/muesli-keyboard-snapshot-dir", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = environment["MUESLI_KEYBOARD_SNAPSHOT_DIR"] ?? fileValue, !path.isEmpty else {
            throw XCTSkip("set MUESLI_KEYBOARD_SNAPSHOT_DIR to render the keyboard")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenes = [
            Scene(name: "ready", setup: .ready, rewriteAvailable: true),
            Scene(name: "ready-no-llm", setup: .ready, rewriteAvailable: false),
            Scene(name: "listening", setup: .listening, rewriteAvailable: true),
            Scene(name: "transcribing", setup: .transcribing, rewriteAvailable: true),
            Scene(name: "edit-listening", setup: .editListening, rewriteAvailable: true),
            Scene(name: "edit-transcribing", setup: .editTranscribing, rewriteAvailable: true),
            Scene(name: "undo", setup: .undoAvailable, rewriteAvailable: true),
        ]
        for scene in scenes {
            for (suffix, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                let controller = try makeController(scene)
                let size = CGSize(width: 393, height: KeyboardRootView.preferredHeight)
                let host = UIHostingController(rootView: KeyboardRootView(controller: controller))
                host.view.frame = CGRect(origin: .zero, size: size)
                host.safeAreaRegions = []
                host.overrideUserInterfaceStyle = style
                host.view.backgroundColor = style == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.93, alpha: 1)
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.overrideUserInterfaceStyle = style
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))

                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(scene.name)-\(suffix).png"))
                window.isHidden = true
            }
        }
    }
}
