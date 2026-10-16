import XCTest
@testable import DictationPolicyKit

/// The dedicated live-preview engine: when it runs, when it holds memory, and how Settings offers its model.
final class LivePreviewEnginePolicyTests: XCTestCase {
    private func choose(
        selectedStreams: Bool = false,
        keyboard: Bool = true,
        notepad: Bool = false,
        downloaded: Bool = true
    ) -> LivePreviewEnginePolicy.Choice {
        LivePreviewEnginePolicy.choose(
            selectedModelStreams: selectedStreams,
            isKeyboardDictation: keyboard,
            startsAsNotepad: notepad,
            previewModelDownloaded: downloaded
        )
    }

    // MARK: When to run the preview engine

    // Row: default setup (non-streaming selected model, keyboard dictation, preview model present) gets a preview.
    func testKeyboardDictationWithANonStreamingModelRunsTheDedicatedPreviewEngine() {
        XCTAssertEqual(choose(), .dedicated)
        XCTAssertTrue(choose().streams)
    }

    // Row: selected == EOU reuses the one engine, on every surface, as today.
    func testSelectedPreviewModelReusesTheOneEngine() {
        XCTAssertEqual(choose(selectedStreams: true), .finalModel)
        XCTAssertEqual(choose(selectedStreams: true, keyboard: false), .finalModel)
        XCTAssertEqual(choose(selectedStreams: true, notepad: true), .finalModel)
        XCTAssertEqual(choose(selectedStreams: true, downloaded: false), .finalModel)
    }

    // Row: the preview model is missing, so nothing streams and the strip shows nothing.
    func testMissingPreviewModelTurnsThePreviewOff() {
        XCTAssertEqual(choose(downloaded: false), .off(.previewModelMissing))
        XCTAssertFalse(choose(downloaded: false).streams)
    }

    // Row: Action Button and in-app dictation have no strip, so they never pay for a second model.
    func testNonKeyboardDictationNeverLoadsTheDedicatedEngine() {
        XCTAssertEqual(choose(keyboard: false), .off(.notKeyboard))
    }

    // Row: notepad bursts keep their own path.
    func testNotepadNeverLoadsTheDedicatedEngine() {
        XCTAssertEqual(choose(notepad: true), .off(.notepad))
    }

    // MARK: Memory

    // Row: lazy load. Nothing is held until the first dictation streams.
    func testThePreviewModelLoadsOnlyWhenADictationStreams() {
        var residency = LivePreviewResidency()
        XCTAssertFalse(residency.isLoaded)
        residency.streamingStarted()
        XCTAssertTrue(residency.isLoaded)
        XCTAssertTrue(residency.isStreaming)
        XCTAssertEqual(residency.streamingEnded(), .none, "stays warm for the next dictation")
        XCTAssertTrue(residency.isLoaded)
    }

    // Row: memory pressure while idle unloads now.
    func testMemoryPressureWhileIdleUnloadsThePreviewModel() {
        var residency = LivePreviewResidency()
        residency.streamingStarted()
        _ = residency.streamingEnded()
        XCTAssertEqual(residency.memoryWarning(), .unload)
        XCTAssertFalse(residency.isLoaded)
        XCTAssertEqual(residency.memoryWarning(), .none, "nothing left to unload")
    }

    // Row: memory pressure mid-dictation waits for that dictation to end; the preview is not torn down under it.
    func testMemoryPressureMidDictationUnloadsWhenTheDictationEnds() {
        var residency = LivePreviewResidency()
        residency.streamingStarted()
        XCTAssertEqual(residency.memoryWarning(), .none)
        XCTAssertTrue(residency.isLoaded)
        XCTAssertEqual(residency.streamingEnded(), .unload)
        XCTAssertFalse(residency.isLoaded)
        residency.streamingStarted()
        XCTAssertEqual(residency.streamingEnded(), .none, "a reload starts fresh, without the old warning")
    }

    func testMemoryPressureBeforeAnyLoadDoesNothing() {
        var residency = LivePreviewResidency()
        XCTAssertEqual(residency.memoryWarning(), .none)
        XCTAssertEqual(residency.streamingEnded(), .none)
    }

    // Row: switching the selected model to EOU means one engine does both jobs; the dedicated copy is released.
    func testSelectingThePreviewModelReleasesTheDedicatedCopy() {
        var residency = LivePreviewResidency()
        residency.streamingStarted()
        _ = residency.streamingEnded()
        XCTAssertEqual(residency.dedicatedEngineNotNeeded(), .unload)
        XCTAssertFalse(residency.isLoaded)
        var neverLoaded = LivePreviewResidency()
        XCTAssertEqual(neverLoaded.dedicatedEngineNotNeeded(), .none)
    }

    // MARK: Settings offer

    private func offer(
        downloaded: Bool = false,
        selectedStreams: Bool = false,
        progress: Double? = nil,
        downloading: Bool = false,
        other: Bool = false
    ) -> LivePreviewDownloadOffer {
        LivePreviewDownloadOffer.state(
            previewModelDownloaded: downloaded,
            selectedModelStreams: selectedStreams,
            previewDownloadProgress: progress,
            isPreviewDownloading: downloading,
            otherDownloadActive: other
        )
    }

    // Row: the preview model is missing, so Settings offers it with its real size.
    func testMissingPreviewModelIsOfferedWithItsSize() {
        XCTAssertEqual(offer(), .available(sizeLabel: "224 MB"))
    }

    func testTheOfferHidesOnceDownloadedOrWhenTheSelectedModelAlreadyStreams() {
        XCTAssertEqual(offer(downloaded: true), .hidden)
        XCTAssertEqual(offer(selectedStreams: true), .hidden)
    }

    func testTheOfferShowsDownloadProgress() {
        XCTAssertEqual(offer(progress: 0.4, downloading: true), .downloading(progress: 0.4))
        XCTAssertEqual(offer(downloading: true), .downloading(progress: nil))
    }

    // Starting it would cancel the selected model's download (one download at a time).
    func testTheOfferWaitsWhileAnotherModelDownloads() {
        XCTAssertEqual(offer(other: true), .waitingForOtherDownload)
    }

    func testSizeLabelUsesDecimalMegabytes() {
        XCTAssertEqual(LivePreviewDownloadOffer.sizeLabel(bytes: 224_240_384), "224 MB")
        XCTAssertEqual(LivePreviewDownloadOffer.sizeLabel(bytes: 1_500_000_000), "1.5 GB")
    }
}

/// Final text with a dedicated preview engine: the preview never decides the final text.
final class FinalTextPolicyPreviewSourceTests: XCTestCase {
    private struct StubFailure: Error {}
    private struct TimedOut: Error {}

    // Row: a long voice note streamed by the preview model still gets the selected model's pass, as before.
    func testLongVoiceNoteIgnoresPreviewModelTextAndRunsTheFinalPass() async throws {
        let decision = try await FinalTextPolicy.resolve(
            streamingText: "preview words",
            isLongForm: true,
            streamingIsFromFinalModel: false,
            timeoutError: TimedOut()
        ) { .init(text: "Selected model words.", isRemote: false) }
        XCTAssertEqual(decision, .init(text: "Selected model words.", source: .finalPass(isRemote: false)))
    }

    // Row: and its failure still fails the voice note (durable audio retries), instead of keeping preview text.
    func testLongVoiceNoteFinalPassFailureIsNotMaskedByPreviewText() async {
        do {
            _ = try await FinalTextPolicy.resolve(
                streamingText: "preview words",
                isLongForm: true,
                streamingIsFromFinalModel: false,
                timeoutError: TimedOut()
            ) { throw StubFailure() }
            XCTFail("a long voice note must not settle for preview text")
        } catch {
            XCTAssertTrue(error is StubFailure)
        }
    }

    // Row: a short dictation streamed by the preview model falls back to it when the pass fails.
    func testShortDictationFallsBackToPreviewModelText() async throws {
        let decision = try await FinalTextPolicy.resolve(
            streamingText: "preview words",
            isLongForm: false,
            streamingIsFromFinalModel: false,
            timeoutError: TimedOut()
        ) { throw StubFailure() }
        XCTAssertEqual(decision, .init(text: "preview words", source: .streaming))
    }
}
