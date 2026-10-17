import XCTest
@testable import Muesli

/// The wide pill in the strip stops and saves a running dictation, through the same entry point as the Record key.
@MainActor
final class KeyboardStatusPillTests: XCTestCase {
    private var directory: URL!
    private var store: SharedStore!
    private var controller: KeyboardController!
    private let requestID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyboard-pill-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bus = StubEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
        controller = KeyboardController(store: store, eventBus: bus)
        controller.textInserter = { _ in }
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func enter(_ phase: KeyboardHandoffPhase, runtime: DictationPhase) throws {
        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, activeRequestID: requestID, phase: runtime,
            supportsBackgroundStart: true, inputLevel: 0.4))
        try store.saveKeyboardHandoffState(.init(requestID: requestID, phase: phase))
        controller.prepareInitialPresentationState()
    }

    private func startRecording(preview: String? = nil) throws {
        try store.claimRequest(.init(id: requestID))
        try enter(.recordingStarted, runtime: .recording)
        if let preview {
            try store.saveKeyboardLiveTranscript(.init(requestID: requestID, text: preview))
            controller.prepareInitialPresentationState()
        }
    }

    func testIdleIsNotTappable() {
        XCTAssertFalse(controller.canStopFromStatusPill)
    }

    func testRequestedIsNotTappable() throws {
        try store.claimRequest(.init(id: requestID))
        try enter(.startRequested, runtime: .idle)
        XCTAssertEqual(controller.dictationPhase, .requested)
        XCTAssertFalse(controller.canStopFromStatusPill)
    }

    func testRecordingWithoutPreviewTextIsTappable() throws {
        try startRecording()
        XCTAssertNil(controller.livePreview)
        XCTAssertTrue(controller.canStopFromStatusPill)
    }

    func testRecordingWithLongPreviewTextIsTappable() throws {
        try startRecording(preview: String(repeating: "so the plan for tomorrow is to pick up the parts ", count: 8))
        XCTAssertNotNil(controller.livePreview)
        XCTAssertTrue(controller.canStopFromStatusPill)
    }

    func testTappingSendsOneStopWithTheKeysState() throws {
        try startRecording(preview: "hello world")
        controller.stopFromStatusPill()
        XCTAssertEqual(try store.pendingCommand()?.action, .stop)
        XCTAssertEqual(try store.pendingCommand()?.requestID, requestID)
        XCTAssertEqual(try store.keyboardHandoffState().phase, .stopRequested)
        XCTAssertEqual(controller.statusText, "Stopping")
    }

    func testADoubleTapSendsOnlyOneStop() throws {
        try startRecording()
        controller.stopFromStatusPill()
        try store.clearPendingCommand(matching: requestID)
        controller.stopFromStatusPill()
        XCTAssertNil(try store.pendingCommand(), "the second tap sent another stop")
        XCTAssertFalse(controller.canStopFromStatusPill)
    }

    func testTheRecordKeyAfterThePillDoesNotSendASecondStop() throws {
        try startRecording()
        controller.stopFromStatusPill()
        try store.clearPendingCommand(matching: requestID)
        controller.primaryAction()
        XCTAssertNil(try store.pendingCommand())
    }

    func testTranscribingIsNotTappableAndSendsNothing() throws {
        try startRecording()
        try enter(.transcribingStarted, runtime: .transcribing)
        XCTAssertEqual(controller.dictationPhase, .transcribing)
        XCTAssertFalse(controller.canStopFromStatusPill)
        controller.stopFromStatusPill()
        XCTAssertNil(try store.pendingCommand())
    }

    func testATapAfterTheDictationFinishedDoesNothing() throws {
        try startRecording()
        try store.saveResult(.init(requestID: requestID, text: "Hello", engineIdentifier: "test"))
        try enter(.inserted, runtime: .idle)
        XCTAssertFalse(controller.canStopFromStatusPill)
        controller.stopFromStatusPill()
        XCTAssertNil(try store.pendingCommand())
    }

    func testCopyRequiredFailedAndCancelledAreNotTappable() throws {
        try startRecording()
        for phase in [KeyboardHandoffPhase.copyRequired, .failed, .cancelled] {
            try enter(phase, runtime: .idle)
            XCTAssertFalse(controller.canStopFromStatusPill, "\(phase)")
            controller.stopFromStatusPill()
            XCTAssertNil(try store.pendingCommand(), "\(phase)")
        }
    }

    func testACancelInFlightDisablesThePill() throws {
        try startRecording()
        controller.cancelActiveDictation()
        try store.clearPendingCommand(matching: requestID)
        XCTAssertFalse(controller.canStopFromStatusPill)
        controller.stopFromStatusPill()
        XCTAssertNil(try store.pendingCommand(), "a stop overrode the cancel")
    }

    func testANewRecordingIsTappableAgainAfterAStop() throws {
        try startRecording()
        controller.stopFromStatusPill()
        let next = UUID()
        try store.clearPendingCommand(matching: requestID)
        try store.saveKeyboardHandoffState(.init(requestID: requestID, phase: .inserted))
        controller.prepareInitialPresentationState()
        try store.claimRequest(.init(id: next))
        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(
            isActive: true, activeRequestID: next, phase: .recording,
            supportsBackgroundStart: true, inputLevel: 0.4))
        try store.saveKeyboardHandoffState(.init(requestID: next, phase: .recordingStarted))
        controller.prepareInitialPresentationState()
        XCTAssertTrue(controller.canStopFromStatusPill)
    }
}
