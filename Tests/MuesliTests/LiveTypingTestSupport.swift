import UIKit
import XCTest
@testable import Muesli

/// Timers and a clock the test advances by hand.
@MainActor
final class ManualLiveTypingScheduler {
    private(set) var time: TimeInterval = 1_000
    private var timers: [(id: Int, due: TimeInterval, action: @MainActor () -> Void)] = []
    private var nextID = 0

    var scheduler: LiveTypingScheduler {
        LiveTypingScheduler(
            now: { [unowned self] in self.time },
            schedule: { [unowned self] delay, action in
                let id = self.nextID
                self.nextID += 1
                self.timers.append((id, self.time + delay, action))
                return { [weak self] in self?.timers.removeAll { $0.id == id } }
            }
        )
    }

    var pendingTimers: Int { timers.count }

    /// Moves time forward, running every timer that falls due on the way, in order.
    func advance(_ seconds: TimeInterval) {
        let target = time + seconds
        while let next = timers.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            time = max(time, next.due)
            next.action()
        }
        time = target
    }
}

/// A `LiveTypingHost` over the shared model of a host field. Writes land in the model at once; what the proxy
/// reports follows the model at once, or only on `pump()` when the model lags, which is also when the host's
/// `textDidChange` reaches the keyboard.
@MainActor
final class FakeProxyHost: LiveTypingHost {
    let model: ModelMarkedHost
    var onHostChange: (() -> Void)?
    private(set) var writes: [String] = []

    init(before: String = "", after: String = "", behavior: ModelMarkedHost.Behavior = .full) {
        model = ModelMarkedHost(before: before, after: after, behavior: behavior)
    }

    var document: String { model.document }
    var markedLength: Int { model.markedLength }
    var markedWrites: [String] { writes.filter { $0.hasPrefix("setMarked(") } }

    private func echo() {
        if !model.lags { model.flush() }
    }

    func setMarkedText(_ text: String) { writes.append("setMarked(\(text))"); model.setMarked(text); echo() }
    func unmarkText() { writes.append("unmark"); model.unmark(); echo() }
    func deleteBackward() { writes.append("deleteBackward"); model.deleteBackward(); echo() }
    func insertText(_ text: String) { writes.append("insert(\(text))"); model.insert(text); echo() }
    func snapshot() -> LiveTypingSnapshot { model.snapshot() }

    /// The host's change callback reaches the keyboard.
    func pump() {
        model.flush()
        onHostChange?()
    }

    /// Wires the keyboard's own edit closures and document readers to the same model.
    func attach(to controller: KeyboardController) {
        onHostChange = { [weak controller] in controller?.liveTypingHostDidChange() }
        controller.liveTypingHost = self
        controller.textInserter = { [unowned self] in self.insertText($0) }
        controller.textDeleter = { [unowned self] count in for _ in 0..<count { self.deleteBackward() } }
        let document = controller.typing.document
        document.beforeReader = { [unowned self] in self.snapshot().before.isEmpty ? nil : self.snapshot().before }
        document.afterReader = { [unowned self] in self.snapshot().after.isEmpty ? nil : self.snapshot().after }
        document.identifierReader = { [unowned self] in self.snapshot().documentID }
        document.selectionReader = { [unowned self] in self.snapshot().selection.isEmpty ? nil : self.snapshot().selection }
        controller.textContextProvider = { [unowned self] in
            KeyboardTextContext(selectedText: self.snapshot().selection.isEmpty ? nil : self.snapshot().selection,
                                textBeforeCursor: self.snapshot().before)
        }
    }
}

/// Drives a `KeyboardController` through a dictation the way the app and the keyboard walk through it together.
@MainActor
final class LiveDictationDriver {
    let directory: URL
    let store: SharedStore
    let bus = StubEventBus()
    let clock = ManualLiveTypingScheduler()
    let controller: KeyboardController
    let host: FakeProxyHost
    var requestID = UUID()
    private var transcriptTime = Date()

    init(before: String = "", after: String = "", behavior: ModelMarkedHost.Behavior = .full, attachHost: Bool = true) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus, liveTypingScheduler: clock.scheduler)
        host = FakeProxyHost(before: before, after: after, behavior: behavior)
        if attachHost { host.attach(to: controller) }
        controller.typing.setDocumentLanguage("en-US")
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    var document: String { host.document }

    // MARK: The app side

    /// Record is tapped with the mic session running: the keyboard sends start and the app starts recording.
    func startRecording() throws {
        try store.saveKeyboardRuntimeStatus(.init(isActive: true, supportsBackgroundStart: true))
        controller.prepareInitialPresentationState()
        controller.primaryAction()
        requestID = try XCTUnwrap(try store.pendingCommand()).requestID
        try appWrites(.startAcknowledged)
        try appWrites(.recordingStarted)
        try store.saveKeyboardRuntimeStatus(.init(
            isActive: true, activeRequestID: requestID, phase: .recording, supportsBackgroundStart: true, inputLevel: 0.4
        ))
        controller.prepareInitialPresentationState()
    }

    func appWrites(_ phase: KeyboardHandoffPhase) throws {
        try store.saveKeyboardHandoffState(.init(requestID: requestID, phase: phase))
        controller.prepareInitialPresentationState()
    }

    /// The streaming engine hears more words. `settle` lets the throttle window and the probe checks pass.
    func hear(_ text: String, settle: Bool = true) throws {
        transcriptTime = transcriptTime.addingTimeInterval(0.01)
        try store.saveKeyboardLiveTranscript(.init(requestID: requestID, text: text, isFinal: false, updatedAt: transcriptTime))
        controller.prepareInitialPresentationState()
        if settle { settleHost() }
    }

    /// Time passes and the host's callbacks arrive until nothing more happens.
    func settleHost(seconds: TimeInterval = 0.25) {
        for _ in 0..<4 {
            clock.advance(seconds / 4)
            host.pump()
        }
    }

    func stopAndTranscribe() throws {
        controller.primaryAction()
        XCTAssertEqual(try store.pendingCommand()?.action, .stop)
        try appWrites(.stopAcknowledged)
        try appWrites(.transcribingStarted)
    }

    /// What `deliverKeyboardTranscript` writes: the result, the final text as isFinal, then resultReady.
    func deliver(_ text: String, requestID: UUID? = nil) throws {
        let id = requestID ?? self.requestID
        try store.saveResult(.init(requestID: id, text: text, engineIdentifier: "test"))
        try store.saveKeyboardLiveTranscript(.init(requestID: id, text: text, isFinal: true))
        try store.saveKeyboardHandoffState(.init(requestID: id, phase: .resultReady))
        controller.prepareInitialPresentationState()
    }

    func finish(_ text: String) throws {
        try deliver(text)
        settleHost()
    }
}
