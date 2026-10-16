import XCTest
@testable import KeyboardTypingKit

/// Matrix rows W1-W12: the word that ends at the cursor, from `documentContextBeforeInput` / `AfterInput`.
final class TypingWordExtractorTests: XCTestCase {
    private func word(_ before: String?, after: String? = nil) -> TypingCursorWord {
        TypingWordExtractor.word(before: before, after: after)
    }

    // W1
    func testEmptyAndMissingContextHaveNoWord() {
        XCTAssertEqual(word(nil), .none)
        XCTAssertEqual(word(""), .none)
    }

    // W2
    func testCursorAfterASpaceHasNoWord() {
        XCTAssertEqual(word("hello "), .none)
        XCTAssertEqual(word("hello   "), .none)
    }

    func testTheLastWordBeforeTheCursorIsThePartial() {
        XCTAssertEqual(word("say hel"), .partial("hel"))
        XCTAssertEqual(word("hel"), .partial("hel"))
    }

    // W3
    func testCursorInTheMiddleOfAWordIsReportedAsInside() {
        XCTAssertEqual(word("hel", after: "lo"), .insideWord)
        XCTAssertEqual(word("hel", after: "lo world"), .insideWord)
    }

    func testAWordFollowedByASpaceOrPunctuationOrNewlineStillHasAPartial() {
        XCTAssertEqual(word("hel", after: " world"), .partial("hel"))
        XCTAssertEqual(word("hel", after: ", world"), .partial("hel"))
        XCTAssertEqual(word("hel", after: "\nnext"), .partial("hel"))
    }

    func testCursorBeforeAWordHasNoPartial() {
        XCTAssertEqual(word("", after: "hello"), .none)
        XCTAssertEqual(word("hello ", after: "world"), .none)
    }

    // W4
    func testAnApostropheInsideAWordIsPartOfIt() {
        XCTAssertEqual(word("I don't"), .partial("don't"))
        XCTAssertEqual(word("I don\u{2019}t"), .partial("don\u{2019}t"))
    }

    func testATrailingApostropheHasNoWordYet() {
        XCTAssertEqual(word("I don'"), .none)
    }

    func testALeadingQuoteIsNotPartOfTheWord() {
        XCTAssertEqual(word("say 'hel"), .partial("hel"))
        XCTAssertEqual(word("say \u{2018}hel"), .partial("hel"))
    }

    // W5
    func testAHyphenInsideAWordIsPartOfIt() {
        XCTAssertEqual(word("a well-kno"), .partial("well-kno"))
    }

    func testATrailingHyphenHasNoWordYet() {
        XCTAssertEqual(word("a well-"), .none)
        XCTAssertEqual(word("a -"), .none)
    }

    // W6
    func testAWordWithDigitsGetsNoSuggestions() {
        XCTAssertEqual(word("abc123"), .none)
        XCTAssertEqual(word("3rd"), .none)
        XCTAssertEqual(word("a1b"), .none)
        XCTAssertEqual(word("room 42"), .none)
    }

    func testADigitSeparatedBySpaceDoesNotHideTheWord() {
        XCTAssertEqual(word("42 hel"), .partial("hel"))
    }

    // W7
    func testCursorRightAfterAnEmojiHasNoWord() {
        XCTAssertEqual(word("hi\u{1F600}"), .none)
        XCTAssertEqual(word("hi \u{1F44D}\u{1F3FD}"), .none)
    }

    func testAnEmojiBeforeTheWordIsABoundary() {
        XCTAssertEqual(word("\u{1F600}hel"), .partial("hel"))
        XCTAssertEqual(word("ok\u{1F600}hel"), .partial("hel"))
    }

    func testAKeycapEmojiIsNotADigitInsideAWord() {
        XCTAssertEqual(word("1\u{FE0F}\u{20E3}hel"), .partial("hel"))
    }

    // W8
    func testANewlineBeforeTheCursorEndsThePreviousWord() {
        XCTAssertEqual(word("line one\nhel"), .partial("hel"))
        XCTAssertEqual(word("line one\n"), .none)
        XCTAssertEqual(word("line one\r\nhel"), .partial("hel"))
    }

    // W9
    func testAVeryLongWordGetsNoSuggestions() {
        let long = String(repeating: "a", count: TypingWordExtractor.maximumWordLength + 1)
        XCTAssertEqual(word(long), .none)
        let limit = String(repeating: "a", count: TypingWordExtractor.maximumWordLength)
        XCTAssertEqual(word(limit), .partial(limit))
    }

    // W10
    func testNonEnglishLettersFormWords() {
        XCTAssertEqual(word("hola se\u{00F1}"), .partial("se\u{00F1}"))
        XCTAssertEqual(word("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"), .partial("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"))
    }

    // W11
    func testPunctuationEndsAWord() {
        XCTAssertEqual(word("hello,wor"), .partial("wor"))
        XCTAssertEqual(word("(hel"), .partial("hel"))
        XCTAssertEqual(word("hello."), .none)
        XCTAssertEqual(word("\"hel"), .partial("hel"))
    }

    // W12: a decomposed accent is one Character, so the delete count matches what backspace removes.
    func testADecomposedAccentCountsAsOneCharacter() {
        let cafe = "cafe\u{0301}"
        XCTAssertEqual(word("go to \(cafe)"), .partial(cafe))
        if case .partial(let partial) = word("go to \(cafe)") {
            XCTAssertEqual(partial.count, 4)
        }
    }
}
