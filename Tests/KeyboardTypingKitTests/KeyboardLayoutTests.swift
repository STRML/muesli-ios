import XCTest
@testable import KeyboardTypingKit

/// Matrix rows L1-L9: the layout value as the shared store carries it.
final class KeyboardLayoutTests: XCTestCase {
    private func decode(_ json: String) throws -> KeyboardTypingSettings {
        try JSONDecoder().decode(KeyboardTypingSettings.self, from: Data(json.utf8))
    }

    // L1: nothing chosen means Full.
    func testFullIsTheDefault() {
        XCTAssertEqual(KeyboardTypingSettings.default.layout, .full)
        XCTAssertEqual(KeyboardTypingSettings(autocorrect: false).layout, .full)
        XCTAssertEqual(KeyboardLayout.fallback, .full)
    }

    // L2
    func testStoredValuesRoundTrip() {
        for layout in KeyboardLayout.allCases {
            XCTAssertEqual(KeyboardLayout(storedValue: layout.storedValue), layout)
        }
        XCTAssertEqual(KeyboardLayout.full.storedValue, "full")
        XCTAssertEqual(KeyboardLayout.minimal.storedValue, "minimal")
    }

    // L3: a build from before the setting stored no layout. Reading that keeps the other two choices.
    func testSettingsStoredBeforeTheLayoutExistedDecodeAsFullAndKeepTheOtherChoices() throws {
        let decoded = try decode(#"{"autocorrect":false,"liveTyping":false}"#)
        XCTAssertEqual(decoded, KeyboardTypingSettings(autocorrect: false, liveTyping: false, layout: .full))
    }

    // L4
    func testMinimalDecodesAsMinimal() throws {
        let decoded = try decode(#"{"autocorrect":true,"liveTyping":true,"layout":"minimal"}"#)
        XCTAssertEqual(decoded.layout, .minimal)
    }

    // L5: a value from a newer build, or the wrong case, is Full and does not throw.
    func testAnUnknownLayoutDecodesAsFullAndKeepsTheOtherChoices() throws {
        for junk in ["compact", "", "Minimal", "MINIMAL", "minimal ", "full-v2", "\u{0}"] {
            let decoded = try decode(#"{"autocorrect":false,"liveTyping":false,"layout":"\#(junk)"}"#)
            XCTAssertEqual(decoded, KeyboardTypingSettings(autocorrect: false, liveTyping: false, layout: .full), "\(junk.debugDescription)")
        }
    }

    // L6: a layout of the wrong type must not take the whole record down, or a user who turned Autocorrect off
    // gets it back.
    func testACorruptedLayoutKeepsTheOtherChoices() throws {
        for junk in ["3", "true", "null", "[\"minimal\"]", "{}", "1.5"] {
            let decoded = try decode(#"{"autocorrect":false,"liveTyping":false,"layout":\#(junk)}"#)
            XCTAssertEqual(decoded, KeyboardTypingSettings(autocorrect: false, liveTyping: false, layout: .full), junk)
        }
    }

    // L7
    func testTheLayoutRoundTrips() throws {
        for layout in KeyboardLayout.allCases {
            let settings = KeyboardTypingSettings(autocorrect: false, liveTyping: true, layout: layout)
            let decoded = try JSONDecoder().decode(KeyboardTypingSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded, settings)
        }
    }

    // L8: the layout is a string on the wire, so an older build that ignores unknown keys keeps working.
    func testTheLayoutIsWrittenAsItsStoredString() throws {
        let data = try JSONEncoder().encode(KeyboardTypingSettings(autocorrect: true, liveTyping: true, layout: .minimal))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["layout"] as? String, "minimal")
        XCTAssertEqual(object["autocorrect"] as? Bool, true)
        XCTAssertEqual(object["liveTyping"] as? Bool, true)
    }

    // L9: a record that is not an object at all is a decode error; the keyboard then uses the defaults (Full).
    func testARecordThatIsNotAnObjectFailsToDecode() {
        XCTAssertThrowsError(try decode("[1,2]"))
        XCTAssertThrowsError(try decode("\"minimal\""))
    }
}
