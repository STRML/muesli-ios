import XCTest
import SwiftUI
@testable import Muesli

private final class FieldBuffer: @unchecked Sendable {
    var text = ""
}

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
        /// Streaming words for the live preview strip.
        var liveText: String?
        /// The Dictate page unless a scene asks for the Type page.
        var surface: TypingSurface = .dictate
        var before: String?
        /// Typed key by key into a fake field, so the strip shows what typing leaves behind (Autocorrect optional).
        var typed: String?
        var autocorrect = true
        var traits = TypingTraits()
        var page: TypingPage = .letters
        var lockCaps = false
        var width: CGFloat = 393
        /// The system asked for our globe (`needsInputModeSwitchKey` true). Off by default, as on a Face ID iPhone.
        var globe = false
        var layout: KeyboardLayout = .full
        /// ABC was tapped during the dictation.
        var takesTypePageBack = false
    }


    private let editText = "Next Amazon order, I want to get a desk mat, a rack for my Mac minis, and a holder for my pen holders."

    private func makeController(_ scene: Scene) throws -> KeyboardController {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let bus = StubEventBus()
        let store = SharedStore(containerURL: temp, eventPoster: bus)
        // The layout goes through the store and the appearance read, the way the keyboard gets it.
        try store.saveKeyboardTypingSettings(KeyboardTypingSettings(autocorrect: true, layout: scene.layout))
        let controller = KeyboardController(store: store, eventBus: bus)
        controller.loadTypingSettings(appliesLayout: true)
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
            if let liveText = scene.liveText {
                try store.saveKeyboardLiveTranscript(.init(requestID: request.id, text: liveText))
                controller.prepareInitialPresentationState()
            }
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
        controller.selectedSurface = scene.surface
        controller.typing.setNeedsInputModeSwitchKey(scene.globe)
        if scene.takesTypePageBack { controller.showTypePage() }
        if let before = scene.before { controller.typing.document.beforeReader = { before } }
        controller.typing.setDocumentLanguage("en-US")
        controller.typing.engine.apply(traits: scene.traits)
        controller.typing.autocorrectEnabled = scene.autocorrect
        controller.typing.engine.switchPage(scene.page)
        if scene.lockCaps {
            controller.typing.perform(.shift)
            controller.typing.perform(.shift)
        }
        if let typed = scene.typed {
            let field = FieldBuffer()
            controller.textInserter = { field.text += $0 }
            controller.textDeleter = { field.text = String(field.text.dropLast($0)) }
            controller.typing.document.beforeReader = { field.text.isEmpty ? nil : field.text }
            for character in typed {
                switch character {
                case " ": controller.typing.perform(.space)
                default: controller.typing.perform(.character(String(character)))
                }
            }
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
            Scene(name: "preview-listening", setup: .listening, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first and then head over to the shop"),
            Scene(name: "preview-finalizing", setup: .transcribing, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first and then head over to the shop"),
            Scene(name: "edit-listening", setup: .editListening, rewriteAvailable: true),
            Scene(name: "edit-transcribing", setup: .editTranscribing, rewriteAvailable: true),
            Scene(name: "undo", setup: .undoAvailable, rewriteAvailable: true),
            // The Type page.
            Scene(name: "type-empty", setup: .ready, rewriteAvailable: true, surface: .type),
            Scene(name: "type-suggest-complete", setup: .ready, rewriteAvailable: true, surface: .type,
                  before: "See you tomorrow at the offi"),
            Scene(name: "type-suggest-correct", setup: .ready, rewriteAvailable: true, surface: .type,
                  before: "I think teh"),
            Scene(name: "type-after-space", setup: .ready, rewriteAvailable: true, surface: .type,
                  before: "Sounds good. "),
            Scene(name: "type-after-space-typo", setup: .ready, rewriteAvailable: true, surface: .type,
                  typed: "I think teh ", autocorrect: false),
            Scene(name: "type-after-space-correct", setup: .ready, rewriteAvailable: true, surface: .type,
                  typed: "Hey is just gets stuck "),
            Scene(name: "type-after-autocorrect", setup: .ready, rewriteAvailable: true, surface: .type,
                  typed: "I think teh "),
            Scene(name: "type-caps-lock", setup: .ready, rewriteAvailable: false, surface: .type,
                  before: "hello ", lockCaps: true),
            Scene(name: "type-numbers", setup: .ready, rewriteAvailable: true, surface: .type, page: .numbers),
            Scene(name: "type-symbols", setup: .ready, rewriteAvailable: true, surface: .type, page: .symbols),
            Scene(name: "type-send", setup: .ready, rewriteAvailable: true, surface: .type, before: "ok",
                  traits: TypingTraits(returnKey: .send, enablesReturnKeyAutomatically: false)),
            Scene(name: "type-email", setup: .ready, rewriteAvailable: true, surface: .type, before: "sam",
                  traits: TypingTraits(autocapitalization: .none, variant: .email)),
            Scene(name: "type-listening", setup: .listening, rewriteAvailable: true, surface: .type),
            Scene(name: "type-preview", setup: .listening, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first and then head over to the shop",
                  surface: .type),
            Scene(name: "type-transcribing", setup: .transcribing, rewriteAvailable: true, surface: .type),
            Scene(name: "type-edit-listening", setup: .editListening, rewriteAvailable: true, surface: .type),
            Scene(name: "type-undo", setup: .undoAvailable, rewriteAvailable: true, surface: .type),
            Scene(name: "type-empty-globe", setup: .ready, rewriteAvailable: true, surface: .type, globe: true),
            Scene(name: "ready-globe", setup: .ready, rewriteAvailable: true, globe: true),
            Scene(name: "type-landscape", setup: .ready, rewriteAvailable: true, surface: .type, before: "See you at the offi",
                  width: 852),
            Scene(name: "dictate-landscape", setup: .ready, rewriteAvailable: true, width: 852),
            // The layout setting, and the Full keyboard showing the Dictate page while a dictation runs.
            Scene(name: "full-idle", setup: .ready, rewriteAvailable: true, surface: .type,
                  before: "See you tomorrow at the offi"),
            Scene(name: "full-recording", setup: .listening, rewriteAvailable: true, surface: .type),
            Scene(name: "full-recording-words", setup: .listening, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first and then head over to the shop",
                  surface: .type),
            Scene(name: "full-recording-landscape", setup: .listening, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first", surface: .type, width: 852),
            Scene(name: "full-recording-abc", setup: .listening, rewriteAvailable: true, surface: .type,
                  takesTypePageBack: true),
            Scene(name: "full-recording-edit", setup: .editListening, rewriteAvailable: true, surface: .type),
            Scene(name: "full-transcribing", setup: .transcribing, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first and then head over to the shop",
                  surface: .type),
            Scene(name: "minimal-idle", setup: .ready, rewriteAvailable: true, layout: .minimal),
            Scene(name: "minimal-recording", setup: .listening, rewriteAvailable: true,
                  liveText: "so the plan for tomorrow is to pick up the parts first", layout: .minimal),
            Scene(name: "minimal-transcribing", setup: .transcribing, rewriteAvailable: true, layout: .minimal),
        ]
        for scene in scenes {
            for (suffix, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                let controller = try makeController(scene)
                let size = CGSize(width: scene.width, height: KeyboardRootView.preferredHeight)
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
                XCTAssertEqual(image.size.height, CGFloat(TypingMetrics.preferredHeight), "\(scene.name) height")
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(scene.name)-\(suffix).png"))
                window.isHidden = true
            }
        }
    }
}
