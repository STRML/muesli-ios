import XCTest
@testable import KeyboardTypingKit

final class KeyboardTypingSettingsTests: XCTestCase {
    // S1: live typing is on until the user turns it off.
    func testLiveTypingIsOnByDefault() {
        XCTAssertTrue(KeyboardTypingSettings.default.liveTyping)
        XCTAssertTrue(KeyboardTypingSettings(autocorrect: false).liveTyping)
    }

    // S3: a build that stored only autocorrect must not turn the new switch off, or autocorrect back on.
    func testSettingsStoredBeforeLiveTypingExistedDecodeWithItOnAndAutocorrectKept() throws {
        let legacy = Data(#"{"autocorrect":false}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardTypingSettings.self, from: legacy)
        XCTAssertFalse(decoded.autocorrect)
        XCTAssertTrue(decoded.liveTyping)
    }

    func testBothSwitchesRoundTrip() throws {
        let settings = KeyboardTypingSettings(autocorrect: true, liveTyping: false)
        let decoded = try JSONDecoder().decode(KeyboardTypingSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.liveTyping)
        XCTAssertTrue(decoded.autocorrect)
    }

    // An older keyboard reading what a newer app stored ignores the extra key.
    func testAnExtraKeyIsIgnored() throws {
        let newer = Data(#"{"autocorrect":true,"liveTyping":false,"somethingNew":1}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardTypingSettings.self, from: newer)
        XCTAssertEqual(decoded, KeyboardTypingSettings(autocorrect: true, liveTyping: false))
    }
}
