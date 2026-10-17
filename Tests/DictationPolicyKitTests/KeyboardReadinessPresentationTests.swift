import XCTest
@testable import DictationPolicyKit

/// What the keyboard says for each state (R18: both pages and both layouts read this one table), in words, for
/// VoiceOver, and on the Record key.
final class KeyboardReadinessPresentationTests: XCTestCase {
    private typealias P = KeyboardReadinessPresentation

    private func present(_ state: KeyboardReadinessState, escape: Bool = false, action: RecordAction = .openAppToPrepare) -> P {
        P.make(KeyboardReadiness(state: state, recordAction: action, offersEscape: escape))
    }

    func testElapsedTimeReadsInSecondsMinutesAndHours() {
        let cases: [(TimeInterval, String)] = [
            (0, "0 s"), (40, "40 s"), (59.9, "59 s"), (60, "1 min"), (125, "2 min 5 s"), (900, "15 min"),
            (3_599, "59 min 59 s"), (3_600, "1 h"), (3_725, "1 h 2 min"), (-5, "0 s"),
        ]
        for (seconds, text) in cases {
            XCTAssertEqual(P.elapsedText(seconds), text, "\(seconds)")
        }
    }

    func testReadyIsTheNormalKeyboard() {
        let ready = present(.ready, action: .startInPlace)
        XCTAssertNil(ready.caption)
        XCTAssertEqual(ready.recordTitle, "Start")
        XCTAssertEqual(ready.recordSymbol, "mic.fill")
        XCTAssertEqual(ready.tone, .normal)
        XCTAssertEqual(ready.accessibilityLabel, "Record")
        XCTAssertFalse(ready.showsSpinner)
    }

    func testLoadingShowsTheModelAndTheElapsedTime() {
        let loading = present(.loading(.preparing, progress: nil, elapsed: 40))
        XCTAssertEqual(loading.caption, "Loading speech model, 40 s")
        XCTAssertEqual(loading.tone, .busy)
        XCTAssertTrue(loading.showsSpinner)
        XCTAssertEqual(loading.recordTitle, "Open Muesli")
        XCTAssertEqual(loading.accessibilityLabel, "Record. Speech model loading, 40 s")
        XCTAssertEqual(loading.accessibilityHint, "Opens Muesli to finish loading")
    }

    func testLoadingWithProgress() {
        XCTAssertEqual(present(.loading(.preparing, progress: 0.4, elapsed: 125)).caption, "Loading speech model 40%, 2 min 5 s")
        XCTAssertEqual(present(.loading(.downloading, progress: 0.42, elapsed: 0)).caption, "Downloading speech model 42%")
        XCTAssertEqual(present(.loading(.downloading, progress: nil, elapsed: 0)).caption, "Downloading speech model")
        XCTAssertEqual(present(.loading(.preparing, progress: 7, elapsed: 3)).caption, "Loading speech model 100%, 3 s", "clamped")
    }

    func testALongLoadOffersTheWayOut() {
        let loading = present(.loading(.preparing, progress: nil, elapsed: 185), escape: true)
        XCTAssertEqual(loading.caption, "Still loading, 3 min 5 s. Tap to open Muesli")
        XCTAssertEqual(loading.tone, .attention)
    }

    func testNeedsAppSaysWhy() {
        let expected: [NeedsAppReason: String] = [
            .fullAccessOff: "Turn on Full Access to dictate",
            .neverOpened: "Open Muesli to set up dictation",
            .appUpdated: "Muesli was updated. Open it to continue",
            .appNotRunning: "Open Muesli to start",
            .loadInterrupted: "Open Muesli to finish loading",
            .modelMissing: "Open Muesli to download the model",
            .modelNotLoaded: "Speech model not loaded. Open Muesli to load it",
            .recovery: "Open Muesli to finish",
        ]
        XCTAssertEqual(Set(expected.keys), Set(NeedsAppReason.allCases))
        for (reason, text) in expected {
            let needs = present(.needsApp(reason))
            XCTAssertEqual(needs.caption, text, "\(reason)")
            XCTAssertEqual(needs.recordSymbol, "arrow.up.forward.app", "\(reason)")
            XCTAssertEqual(needs.recordTitle, "Open Muesli", "\(reason)")
            XCTAssertEqual(needs.tone, .attention, "\(reason)")
            XCTAssertFalse(needs.accessibilityLabel.isEmpty)
        }
    }

    func testFailureNamesTheReason() {
        XCTAssertEqual(present(.failed(.downloadFailed)).caption, "Model failed to download. Open Muesli")
        XCTAssertEqual(present(.failed(.loadFailed)).caption, "Model failed to load. Open Muesli")
        XCTAssertEqual(present(.failed(.loadInterrupted)).caption, "Model load was interrupted. Open Muesli")
        XCTAssertEqual(present(.failed(.unknown)).caption, "Model failed. Open Muesli")
        XCTAssertEqual(present(.failed(.unknown)).tone, .error)
        XCTAssertEqual(present(.failed(.unknown)).accessibilityLabel, "Record. Speech model failed")
    }

    // The stuck picture from a real phone: a recording nobody can hear, with a pill that does nothing.
    func testALostConnectionSaysSoAndOffersTheWayBack() {
        let lost = present(.connectionLost, escape: true, action: .openAppToRecover)
        XCTAssertEqual(lost.caption, "Lost connection to Muesli. Tap to reconnect")
        XCTAssertEqual(lost.recordTitle, "Reconnect")
        XCTAssertEqual(lost.recordSymbol, "arrow.up.forward.app")
        XCTAssertEqual(lost.tone, .attention)
        XCTAssertEqual(lost.accessibilityHint, "Opens Muesli")
    }

    func testCheckingIsQuiet() {
        let checking = present(.checking, action: .openAppToStart)
        XCTAssertEqual(checking.caption, "Checking Muesli…")
        XCTAssertEqual(checking.recordSymbol, "mic.fill")
        XCTAssertEqual(checking.tone, .busy)
    }

    func testRunningStatesAndTheirEscapes() {
        XCTAssertEqual(present(.starting).caption, "Starting…")
        XCTAssertEqual(present(.recording).caption, "Listening")
        XCTAssertEqual(present(.transcribing).caption, "Writing your text")
        XCTAssertEqual(present(.starting, escape: true).caption, "Muesli isn't answering. Tap to open it")
        XCTAssertEqual(present(.recording, escape: true).caption, "Stopping is taking a while. Tap to open Muesli")
        XCTAssertEqual(present(.transcribing, escape: true).caption, "Taking longer than usual. Tap to open Muesli")
    }

    // R18: every state has a caption rule, a symbol, a title and a label, so no page can show a blank.
    func testEveryStateIsPresentable() {
        var states: [KeyboardReadinessState] = [
            .checking, .ready, .starting, .recording, .transcribing, .connectionLost,
            .loading(.preparing, progress: nil, elapsed: 5), .loading(.downloading, progress: 0.5, elapsed: 0),
        ]
        states += NeedsAppReason.allCases.map { .needsApp($0) }
        states += ReadinessModelFailure.allCases.map { .failed($0) }
        for state in states {
            for escape in [false, true] {
                let presentation = present(state, escape: escape)
                XCTAssertFalse(presentation.recordSymbol.isEmpty, "\(state)")
                XCTAssertFalse(presentation.recordTitle.isEmpty, "\(state)")
                XCTAssertFalse(presentation.accessibilityLabel.isEmpty, "\(state)")
                if state != .ready { XCTAssertNotNil(presentation.caption, "\(state)") }
            }
        }
    }

    func testOnlyReadinessStatesNeedAttention() {
        XCTAssertFalse(present(.ready).needsAttention)
        XCTAssertFalse(present(.recording).needsAttention)
        XCTAssertFalse(present(.transcribing).needsAttention)
        XCTAssertTrue(present(.needsApp(.appNotRunning)).needsAttention)
        XCTAssertTrue(present(.loading(.preparing, progress: nil, elapsed: 1)).needsAttention)
        XCTAssertTrue(present(.failed(.unknown)).needsAttention)
        XCTAssertTrue(present(.checking).needsAttention)
    }
}
