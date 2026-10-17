import XCTest
@testable import DiagnosticsKit

/// The silence guard's events must pass the allowlist, or they are logged on the phone and never shipped.
final class SilenceGuardEventsTests: XCTestCase {
    func testTheGuardEventsAreAllowlisted() {
        for name in ["transcribe.trimmed", "transcribe.tail_dropped", "transcribe.skipped_silent"] {
            XCTAssertTrue(DiagnosticsVocabulary.events.contains(name), name)
        }
    }

    func testTheGuardValuesPassTheirRules() {
        let samples: [(String, String)] = [
            ("leading_ms", "1750"), ("trailing_ms", "3750"), ("phrase_len", "10"), ("duration_ms", "3000"),
            ("reason", "silent_segment"), ("reason", "silent_tail"), ("reason", "silent_clip"),
            ("text_source", "onDevice"), ("text_source", "remote"),
        ]
        for (key, value) in samples {
            XCTAssertEqual(DiagnosticsVocabulary.keyRules[key]?.accepts(value), true, "\(key)=\(value)")
        }
    }

    func testTheGuardNeverCarriesAKeyThatCouldHoldText() {
        let guardKeys = ["leading_ms", "trailing_ms", "phrase_len", "duration_ms", "reason", "text_source"]
        for key in guardKeys {
            XCTAssertEqual(DiagnosticsVocabulary.keyRules[key]?.accepts("Thank you."), false, "\(key) must refuse a phrase")
        }
    }
}
