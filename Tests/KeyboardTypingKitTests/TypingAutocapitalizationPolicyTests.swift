import XCTest
@testable import KeyboardTypingKit

/// Matrix rows A1-A10: when the next letter is a capital.
final class TypingAutocapitalizationPolicyTests: XCTestCase {
    private func sentences(_ before: String?) -> Bool {
        TypingAutocapitalizationPolicy.capitalizesNext(mode: .sentences, before: before)
    }

    // A1
    func testFieldStartCapitalizes() {
        XCTAssertTrue(sentences(nil))
        XCTAssertTrue(sentences(""))
        XCTAssertTrue(sentences("   "))
    }

    // A2
    func testAfterASentenceTerminatorAndASpaceCapitalizes() {
        XCTAssertTrue(sentences("Hello. "))
        XCTAssertTrue(sentences("Really? "))
        XCTAssertTrue(sentences("Stop! "))
        XCTAssertTrue(sentences("Wait\u{2026} "))
        XCTAssertTrue(sentences("He said \"go.\" "))
        XCTAssertTrue(sentences("(see above.) "))
    }

    // A3
    func testATerminatorWithoutASpaceDoesNot() {
        XCTAssertFalse(sentences("Hello."))
        XCTAssertFalse(sentences("3.14"))
        XCTAssertFalse(sentences("Really?"))
    }

    // A4
    func testMidSentenceDoesNot() {
        XCTAssertFalse(sentences("Hello "))
        XCTAssertFalse(sentences("Hello, "))
        XCTAssertFalse(sentences("Hello wor"))
        XCTAssertFalse(sentences("a: "))
    }

    // A5
    func testAfterANewlineCapitalizes() {
        XCTAssertTrue(sentences("first line\n"))
        XCTAssertTrue(sentences("first line\n  "))
    }

    // A6
    func testModes() {
        XCTAssertFalse(TypingAutocapitalizationPolicy.capitalizesNext(mode: .none, before: nil))
        XCTAssertFalse(TypingAutocapitalizationPolicy.capitalizesNext(mode: .none, before: "Hello. "))
        XCTAssertTrue(TypingAutocapitalizationPolicy.capitalizesNext(mode: .words, before: "hello "))
        XCTAssertTrue(TypingAutocapitalizationPolicy.capitalizesNext(mode: .words, before: nil))
        XCTAssertFalse(TypingAutocapitalizationPolicy.capitalizesNext(mode: .words, before: "hello"))
        XCTAssertTrue(TypingAutocapitalizationPolicy.capitalizesNext(mode: .allCharacters, before: "anything"))
    }

    // A9
    func testSeveralSpacesAfterATerminatorStillCount() {
        XCTAssertTrue(sentences("Hello.   "))
    }

    // A10
    func testAClosingQuoteWithoutATerminatorDoesNot() {
        XCTAssertFalse(sentences("He said \"go\" "))
    }
}
