import XCTest
@testable import DiagnosticsKit

/// Every rule is strict ASCII and short. These are the hostile inputs the matrix names: a transcript pasted into a
/// value, very long values, newlines and tabs, and unicode.
final class DiagnosticsValueRuleTests: XCTestCase {
    private let transcript = "Please remind me to call Dr. Okafor about the biopsy results tomorrow"

    private func assertRejected(_ rule: DiagnosticsValueRule, _ values: [String], file: StaticString = #filePath, line: UInt = #line) {
        for value in values {
            XCTAssertFalse(rule.accepts(value), "\(rule) accepted \(value.debugDescription)", file: file, line: line)
        }
    }

    func testUUIDAcceptsOnlyAFullUUID() {
        XCTAssertTrue(DiagnosticsValueRule.uuid.accepts("04FCC3FC-0000-4000-8000-000000000001"))
        XCTAssertTrue(DiagnosticsValueRule.uuid.accepts("04fcc3fc-0000-4000-8000-000000000001"))
        assertRejected(.uuid, ["04fcc3fc", "", "04fcc3fc-0000-4000-8000-00000000000", transcript])
    }

    func testRequestIDAcceptsFullUUIDOrEightHexPrefix() {
        XCTAssertTrue(DiagnosticsValueRule.requestID.accepts("04fcc3fc"))
        XCTAssertTrue(DiagnosticsValueRule.requestID.accepts("04FCC3FC-0000-4000-8000-000000000001"))
        assertRejected(.requestID, ["04fcc3f", "04fcc3fcc", "04FCC3FC", "zzzzzzzz", "none", transcript])
        XCTAssertTrue(DiagnosticsValueRule.optionalID.accepts("none"))
        XCTAssertFalse(DiagnosticsValueRule.optionalID.accepts("None"))
    }

    func testIntegersAndDecimals() {
        for good in ["0", "42", "-3", "123456789012"] { XCTAssertTrue(DiagnosticsValueRule.int.accepts(good), good) }
        assertRejected(.int, ["", "1.5", "1234567890123", "١٢٣", "１２３", "12 3", "+1", "0x10", "1\n"])
        for good in ["48000.0", "44100", "0.5", "-1.25"] { XCTAssertTrue(DiagnosticsValueRule.decimal.accepts(good), good) }
        assertRejected(.decimal, ["", ".5", "1.", "1e9", "NaN", "1,5"])
    }

    func testFlagsAreFourWords() {
        for good in ["true", "false", "yes", "no"] { XCTAssertTrue(DiagnosticsValueRule.flag.accepts(good), good) }
        assertRejected(.flag, ["True", "maybe", "1", ""])
    }

    func testDurationsAcceptBothLogFormsAndTheWordsForNoValue() {
        for good in ["0.45", "1.2s", "12", "none", "never", "unlimited", "0.0s"] {
            XCTAssertTrue(DiagnosticsValueRule.duration.accepts(good), good)
        }
        assertRejected(.duration, ["", "1.2 s", "soon", "1.2ms", "s", "-"])
    }

    func testClosedSetAcceptsOnlyItsMembers() {
        let rule = DiagnosticsValueRule.oneOf(["saved", "failed"])
        XCTAssertTrue(rule.accepts("saved"))
        assertRejected(rule, ["Saved", "saved ", "cancelled", transcript])
    }

    func testIdentifierIsOneShortASCIIWord() {
        for good in ["foregroundCopyRequired", "AVAudioSessionCategoryPlayAndRecord", "DictationCoordinator.swift", "a_b-c:d"] {
            XCTAssertTrue(DiagnosticsValueRule.identifier.accepts(good), good)
        }
        assertRejected(.identifier, [
            "", "Recording was interrupted", transcript, "has\nnewline", "has\ttab", "caf\u{e9}", "\u{1F600}",
            "9starts-with-digit", String(repeating: "a", count: 49), "trailing...", "r\u{202E}tl",
        ])
    }

    func testCodeOrIntAcceptsAnIdentifierOrANumber() {
        XCTAssertTrue(DiagnosticsValueRule.codeOrInt.accepts("noEndpoint"))
        XCTAssertTrue(DiagnosticsValueRule.codeOrInt.accepts("3"))
        assertRejected(.codeOrInt, ["two words", "", "3 4"])
    }

    func testIdentifierListIsCommaSeparatedIdentifiers() {
        XCTAssertTrue(DiagnosticsValueRule.identifierList.accepts("MicrophoneBuiltIn,BluetoothHFP"))
        XCTAssertTrue(DiagnosticsValueRule.identifierList.accepts(""))
        assertRejected(.identifierList, ["a, b", transcript, "a,,b", String(repeating: "a,", count: 40)])
    }

    func testErrorDomainNeedsADotOrTheDomainSuffix() {
        for good in ["NSURLErrorDomain", "com.apple.coreaudio.avfaudio", "Muesli.VoiceNoteCaptureFailure"] {
            XCTAssertTrue(DiagnosticsValueRule.errorDomain.accepts(good), good)
        }
        // One dictated word must not pass for a domain.
        assertRejected(.errorDomain, ["hello", "password", transcript, ""])
    }

    func testVersionAndHardwareModelRejectAUserTypedDeviceName() {
        XCTAssertTrue(DiagnosticsValueRule.version.accepts("0.1.7"))
        XCTAssertTrue(DiagnosticsValueRule.version.accepts("26.0.1"))
        XCTAssertTrue(DiagnosticsValueRule.hardwareModel.accepts("iPhone18,1"))
        assertRejected(.hardwareModel, ["Sam's iPhone", "Sam\u{2019}s iPhone", "iPhone 18 Pro", ""])
        assertRejected(.version, ["1.0 beta", "", String(repeating: "1", count: 25)])
    }
}
