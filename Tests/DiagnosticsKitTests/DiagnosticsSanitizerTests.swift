import XCTest
@testable import DiagnosticsKit

/// The allowlist sanitizer is the privacy boundary: only listed keys with values of the right shape survive.
final class DiagnosticsSanitizerTests: XCTestCase {
    private let transcript = "Please remind me to call Dr. Okafor about the biopsy results tomorrow"

    /// Writes a line the way the app does, reads it back the way the uploader does, and sanitizes it.
    private func sanitize(
        _ event: String,
        _ detail: [String: String],
        process: String = "Muesli"
    ) -> DiagnosticsSanitizeResult {
        let text = Fixture.line(0, event, process: process, detail) + "\n"
        guard let line = DiagnosticsLogParser.parse(text).lines.first else { return DiagnosticsSanitizeResult() }
        return DiagnosticsSanitizer.sanitize(line)
    }

    func testAllowlistedFieldsSurviveUnchanged() {
        let result = sanitize("insert.performed", ["request": "04fcc3fc", "characters": "37", "localPhase": "idle"])
        XCTAssertEqual(result.event?.name, "insert.performed")
        XCTAssertEqual(result.event?.fields, ["request": "04fcc3fc", "characters": "37", "localPhase": "idle"])
        XCTAssertEqual(result.droppedFields, 0)
    }

    func testAnUnknownKeyIsDroppedAndCounted() {
        let result = sanitize("recording.started", ["elapsed_ms": "412", "transcript": "hello"])
        XCTAssertEqual(result.event?.fields, ["elapsed_ms": "412"])
        XCTAssertEqual(result.droppedFields, 1)
    }

    func testATranscriptPastedIntoAnAllowlistedValueIsDropped() {
        let result = sanitize("recording.startFailed", ["request": transcript, "elapsed_ms": "5"])
        XCTAssertEqual(result.event?.fields, ["elapsed_ms": "5"])
        XCTAssertEqual(result.droppedFields, 1)
        for field in result.event?.fields.values ?? [:].values { XCTAssertFalse(field.contains("Okafor")) }
    }

    /// `reason=Recording was interrupted` renders as `reason=Recording was interrupted`: the words after the first
    /// are stray tokens, and they poison the pair they follow instead of leaving a plausible-looking `reason=Recording`.
    func testAMultiWordValueIsDroppedWholeNotTruncatedToItsFirstWord() {
        let result = sanitize("handoff.observed", ["phase": "failed", "reason": "Recording was interrupted"])
        XCTAssertEqual(result.event?.fields, ["phase": "failed"])
        XCTAssertEqual(result.droppedFields, 1)
    }

    /// A value can fake extra `key=value` pairs, and the format cannot tell them from real ones. What it cannot do is
    /// get past a key's rule or add a key that is not on the list.
    func testAValueThatForgesExtraPairsStillFacesEachKeysRule() {
        let result = sanitize("handoff.observed", ["reason": "x request=04fcc3fc note=secret characters=Okafor"])
        XCTAssertEqual(result.event?.fields, ["reason": "x", "request": "04fcc3fc"])
        XCTAssertEqual(result.droppedFields, 2, "the unknown note key and the characters value that is not a number")
        for value in result.event?.fields.values ?? [:].values { XCTAssertFalse(value.contains("secret")) }
    }

    /// The receiver's value alphabet has no comma, so route port lists go out joined with a plus sign.
    func testAPortListIsJoinedWithPlusSignsForTheReceiver() {
        let result = sanitize("recorder_start_failed", ["input_ports": "MicrophoneBuiltIn,BluetoothHFP"])
        XCTAssertEqual(result.event?.fields["input_ports"], "MicrophoneBuiltIn+BluetoothHFP")
    }

    func testVeryLongValuesAreDropped() {
        let result = sanitize("recording.startFailed", ["error": String(repeating: "a", count: 500), "elapsed_ms": "1"])
        XCTAssertEqual(result.event?.fields, ["elapsed_ms": "1"])
    }

    func testATruncatedValueIsDropped() {
        // The log cuts values at 64 characters and appends "...". A cut value is not the value.
        let result = sanitize("recording.startFailed", ["error": String(repeating: "a", count: 70)])
        XCTAssertEqual(result.event?.fields, [:])
        XCTAssertEqual(result.droppedFields, 1)
    }

    func testNewlinesAndTabsInAValueNeverBecomeSeparateLines() {
        let result = sanitize("recording.startFailed", ["error": "line one\nrequest=04fcc3fc\tline two"])
        XCTAssertEqual(DiagnosticsLogParser.parse(Fixture.line(0, "recording.startFailed", ["error": "a\nb"]) + "\n").lines.count, 1)
        XCTAssertNil(result.event?.fields["error"])
    }

    func testUnicodeValuesAreDropped() {
        let fields = ["error": "caf\u{e9}", "model": "\u{1F600}", "elapsed_ms": "\u{FF11}\u{FF12}", "phase": "idle\u{202E}"]
        let result = sanitize("recording.startFailed", fields)
        XCTAssertEqual(result.event?.fields, [:])
        XCTAssertEqual(result.droppedFields, 4)
    }

    func testAnUnknownEventNameDropsTheWholeEvent() {
        let result = sanitize("user.typed.something", ["request": "04fcc3fc"])
        XCTAssertNil(result.event)
    }

    func testAnUnexpectedProcessNameDropsTheEvent() {
        XCTAssertNil(sanitize("recording.started", [:], process: "Sam's iPhone").event)
        XCTAssertNotNil(sanitize("recording.started", [:], process: "MuesliKeyboard").event)
    }

    func testAnUnparseableTimestampDropsTheEvent() {
        let raw = "yesterday-ish\tMuesli\trecording.started\telapsed_ms=1\n"
        let line = DiagnosticsLogParser.parse(raw).lines[0]
        XCTAssertNil(DiagnosticsSanitizer.sanitize(line).event)
    }

    func testADuplicateKeyKeepsTheFirstValue() {
        let line = DiagnosticsLogLine(
            id: "x", time: DiagnosticsLogFormat.timestamp(Fixture.t0), process: "Muesli", name: "recording.started",
            detail: "elapsed_ms=1 elapsed_ms=999"
        )
        let result = DiagnosticsSanitizer.sanitize(line)
        XCTAssertEqual(result.event?.fields, ["elapsed_ms": "1"])
        XCTAssertEqual(result.droppedFields, 1)
    }

    func testAStrayTokenBeforeAnyPairIsCounted() {
        let line = DiagnosticsLogLine(
            id: "x", time: DiagnosticsLogFormat.timestamp(Fixture.t0), process: "Muesli", name: "recording.started",
            detail: "stray elapsed_ms=1"
        )
        let result = DiagnosticsSanitizer.sanitize(line)
        XCTAssertEqual(result.event?.fields, ["elapsed_ms": "1"])
        XCTAssertEqual(result.droppedFields, 1)
    }

    func testRealisticKeyboardAndAppEventsKeepTheirFields() {
        let handoff = sanitize("handoff.observed", [
            "phase": "transcribingStarted", "request": "04fcc3fc", "localPhase": "transcribing",
            "active": "04fcc3fc", "inserted": "no",
        ])
        XCTAssertEqual(handoff.droppedFields, 0)
        let route = sanitize("audioSession.inputConfigured", [
            "stage": "start", "preference": "automatic",
            "input_ports": "MicrophoneBuiltIn", "output_ports": "Speaker",
        ])
        XCTAssertEqual(route.droppedFields, 0)
        let failure = sanitize("audioSession.failed", [
            "stage": "start", "step": "activate", "attempt": "2", "domain": "NSOSStatusErrorDomain", "code": "-50",
            "category": "AVAudioSessionCategoryPlayAndRecord", "mode": "AVAudioSessionModeDefault", "options": "4",
            "other_audio": "false", "input_available": "true",
        ])
        XCTAssertEqual(failure.droppedFields, 0)
    }

    func testEveryKeyRuleDescribesAKeyTheCodeActuallyUses() {
        // A rule for a key nobody logs is dead weight in the privacy table.
        XCTAssertFalse(DiagnosticsVocabulary.keyRules.isEmpty)
        for (key, _) in DiagnosticsVocabulary.keyRules {
            XCTAssertTrue(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }, key)
        }
    }
}
