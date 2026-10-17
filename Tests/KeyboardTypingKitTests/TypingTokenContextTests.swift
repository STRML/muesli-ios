import XCTest
@testable import KeyboardTypingKit

/// Matrix rows C9a-C9m: whether the word that just ended is the whole token or a slice of a hashtag, handle,
/// URL, email, path or identifier. The word extractor stops at `#`, `@`, `.`, `/` and `_`, so the word alone
/// cannot tell; the text before it can.
final class TypingTokenContextTests: XCTestCase {
    private func standalone(_ word: String, in context: String) -> Bool {
        TypingTokenContext.isStandaloneWord(word, contextBefore: context)
    }

    func testAPlainWordIsStandalone() {
        XCTAssertTrue(standalone("teh", in: "teh"))
        XCTAssertTrue(standalone("teh", in: "I said teh"))
        XCTAssertTrue(standalone("teh", in: "line one\nteh"))
    }

    func testAHashtagIsNotStandalone() { XCTAssertFalse(standalone("hashtg", in: "so #hashtg")) }
    func testAHandleIsNotStandalone() { XCTAssertFalse(standalone("sameel", in: "ping @sameel")) }
    func testTheDomainOfAnEmailIsNotStandalone() { XCTAssertFalse(standalone("gmial", in: "me at sam@gmial")) }
    func testTheLocalPartOfAnEmailIsNotStandalone() { XCTAssertFalse(standalone("sam", in: "mail sam@")) }
    func testAHostInAUrlIsNotStandalone() { XCTAssertFalse(standalone("github", in: "see https://github")) }
    func testAPathSegmentIsNotStandalone() { XCTAssertFalse(standalone("docs", in: "see muesli.app/docs")) }
    func testADottedIdentifierIsNotStandalone() { XCTAssertFalse(standalone("id", in: "use user.id")) }
    func testASnakeCaseSegmentIsNotStandalone() { XCTAssertFalse(standalone("varr", in: "set my_varr")) }
    func testAFlagIsNotStandalone() { XCTAssertFalse(standalone("verbse", in: "run --verbse")) }
    func testAnEmojiGluedToTheWordIsNotStandalone() { XCTAssertFalse(standalone("teh", in: "wow😀teh")) }
    func testADigitGluedToTheWordIsNotStandalone() { XCTAssertFalse(standalone("km", in: "run 10km")) }

    func testAnOpeningQuoteOrBracketIsStillStandalone() {
        XCTAssertTrue(standalone("teh", in: "he said \"teh"))
        XCTAssertTrue(standalone("teh", in: "(teh"))
        XCTAssertTrue(standalone("teh", in: "\u{201C}teh"))
    }

    func testNoContextIsStandalone() {
        XCTAssertTrue(TypingTokenContext.isStandaloneWord("teh", contextBefore: nil))
    }

    // Sentence start decides whether a capital is just auto-capitalize or a name.
    func testAWordAtTheStartOfTheFieldStartsASentence() {
        XCTAssertTrue(TypingTokenContext.startsSentence(word: "Teh", contextBefore: "Teh"))
    }

    func testAWordAfterASentenceEndStartsASentence() {
        XCTAssertTrue(TypingTokenContext.startsSentence(word: "Teh", contextBefore: "Hello. Teh"))
        XCTAssertTrue(TypingTokenContext.startsSentence(word: "Teh", contextBefore: "Hello\nTeh"))
    }

    func testAWordInTheMiddleOfASentenceDoesNot() {
        XCTAssertFalse(TypingTokenContext.startsSentence(word: "Sam", contextBefore: "I met Sam"))
    }

    // Shape: what a dictionary can fairly judge.
    func testOrdinaryLowercaseAndCapitalizedWordsHaveACorrectableShape() {
        XCTAssertTrue(TypingTokenContext.hasCorrectableShape("recieve"))
        XCTAssertTrue(TypingTokenContext.hasCorrectableShape("Recieve"))
    }

    func testAllCapsMixedCaseApostropheHyphenAndDigitsAreNotCorrectable() {
        for word in ["TEH", "NASA", "iPhone", "GitHub", "macOS", "eBay", "don't", "well-knwn", "abc123", "a_b", "x"] {
            XCTAssertFalse(TypingTokenContext.hasCorrectableShape(word), word)
        }
    }

    func testAVeryLongWordIsNotCorrectable() {
        XCTAssertFalse(TypingTokenContext.hasCorrectableShape(String(repeating: "a", count: 25)))
        XCTAssertTrue(TypingTokenContext.hasCorrectableShape(String(repeating: "a", count: 24)))
    }
}
