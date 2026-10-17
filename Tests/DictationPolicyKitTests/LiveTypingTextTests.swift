import XCTest
@testable import DictationPolicyKit

final class LiveTypingTextTests: XCTestCase {
    // MARK: Matching what the host reports

    func testTheContextEndingWithTheMarkedTextMatches() {
        XCTAssertTrue(LiveTypingText.contextEnds(with: "hello world", in: "Dear Sam, hello world"))
    }

    func testTheContextNotEndingWithTheMarkedTextDoesNotMatch() {
        XCTAssertFalse(LiveTypingText.contextEnds(with: "hello world", in: "hello world and more"))
        XCTAssertFalse(LiveTypingText.contextEnds(with: "hello world", in: "Dear Sam,"))
    }

    // P7: a host that capitalizes the first letter of marked text still counts as showing it.
    func testCaseDoesNotMatter() {
        XCTAssertTrue(LiveTypingText.contextEnds(with: "hello world", in: "Hello world"))
    }

    // P8: smart punctuation changes the characters, not the words.
    func testSmartQuotesDashesAndEllipsesMatchTheirPlainForms() {
        XCTAssertTrue(LiveTypingText.contextEnds(with: "don't stop - go...", in: "don\u{2019}t stop \u{2013} go\u{2026}"))
        XCTAssertTrue(LiveTypingText.contextEnds(with: "say \"hi\"", in: "say \u{201C}hi\u{201D}"))
    }

    func testANonBreakingSpaceMatchesASpace() {
        XCTAssertTrue(LiveTypingText.contextEnds(with: "two words", in: "two\u{00A0}words"))
    }

    func testAContextShorterThanTheMarkedTextDoesNotMatch() {
        XCTAssertFalse(LiveTypingText.contextEnds(with: "a longer phrase", in: "phrase"))
    }

    func testEmptyMarkedTextAlwaysMatches() {
        XCTAssertTrue(LiveTypingText.contextEnds(with: "", in: "anything"))
    }

    // P9: right-to-left text, emoji and combining marks are compared as typed.
    func testRightToLeftEmojiAndCombiningMarksMatch() {
        XCTAssertTrue(LiveTypingText.contextEnds(with: "שלום עולם", in: "אני אומר שלום עולם"))
        XCTAssertTrue(LiveTypingText.contextEnds(with: "ok 👩\u{200D}👩\u{200D}👧", in: "x ok 👩\u{200D}👩\u{200D}👧"))
        XCTAssertTrue(LiveTypingText.contextEnds(with: "cafe\u{301}", in: "a cafe\u{301}"))
    }

    // MARK: Partials

    func testPartialsAreTrimmed() {
        XCTAssertEqual(LiveTypingText.trimmedPartial("  hello there \n"), "hello there")
        XCTAssertEqual(LiveTypingText.trimmedPartial(" \n "), "")
    }

    // MARK: The marked range, in UTF-16 units

    func testTheMarkedSelectionPutsTheCursorAtTheEndInUTF16Units() {
        XCTAssertEqual(LiveTypingText.markedSelection(for: "abc"), NSRange(location: 3, length: 0))
        // A family emoji is 8 UTF-16 units but one character.
        XCTAssertEqual(LiveTypingText.markedSelection(for: "👩\u{200D}👩\u{200D}👧"), NSRange(location: 8, length: 0))
        XCTAssertEqual(LiveTypingText.markedSelection(for: "e\u{301}"), NSRange(location: 2, length: 0))
        XCTAssertEqual(LiveTypingText.markedSelection(for: ""), NSRange(location: 0, length: 0))
    }

    // MARK: Chunking a long dictation (C1, C5)

    func testATextUnderTheThresholdIsNeverSplit() {
        XCTAssertNil(LiveTypingText.sentenceSplit("One. Two. Three.", threshold: 100))
    }

    func testALongTextCommitsEverythingThroughTheLastFinishedSentence() throws {
        let text = "First sentence here. Second sentence here! Third one is still being spo"
        let split = try XCTUnwrap(LiveTypingText.sentenceSplit(text, threshold: 40))
        XCTAssertEqual(split.commit, "First sentence here. Second sentence here! ")
        XCTAssertEqual(split.rest, "Third one is still being spo")
        XCTAssertEqual(split.commit + split.rest, text)
    }

    func testADecimalPointOrAbbreviationWithoutASpaceIsNotASentenceEnd() throws {
        let text = "Version 3.5 shipped. The ratio was 2.75 and still going on and on"
        let split = try XCTUnwrap(LiveTypingText.sentenceSplit(text, threshold: 30))
        XCTAssertEqual(split.commit, "Version 3.5 shipped. ")
    }

    func testQuestionMarksEllipsesAndCJKTerminatorsEndASentence() throws {
        XCTAssertEqual(
            LiveTypingText.sentenceSplit("Is it? Yes it is and we go on and on", threshold: 20)?.commit,
            "Is it? "
        )
        XCTAssertEqual(
            LiveTypingText.sentenceSplit("Well\u{2026} I think so and we go on and on", threshold: 20)?.commit,
            "Well\u{2026} "
        )
        XCTAssertEqual(
            LiveTypingText.sentenceSplit("你好。 我们继续说话很长很长很长", threshold: 8)?.commit,
            "你好。 "
        )
    }

    // A text that ends exactly at a sentence end has nothing to leave marked: wait for more words.
    func testNothingIsCommittedWhenNothingWouldStayMarked() {
        XCTAssertNil(LiveTypingText.sentenceSplit("Aaaa bbbb cccc dddd eeee ffff. ", threshold: 10))
        XCTAssertNil(LiveTypingText.sentenceSplit("Aaaa bbbb cccc dddd eeee ffff.", threshold: 10))
    }

    func testARunOnWithNoSentenceEndSplitsAtAWordBoundaryOnceFarPastTheThreshold() throws {
        let words = Array(repeating: "word", count: 40).joined(separator: " ")
        let split = try XCTUnwrap(LiveTypingText.sentenceSplit(words, threshold: 40))
        XCTAssertTrue(split.commit.hasSuffix(" "))
        XCTAssertFalse(split.rest.isEmpty)
        XCTAssertEqual(split.commit + split.rest, words)
        XCTAssertNil(LiveTypingText.sentenceSplit(Array(repeating: "word", count: 10).joined(separator: " "), threshold: 40))
    }

    // The threshold: above what a dictation under the 60 s long-voice-note default produces.
    func testTheThresholdSitsAboveASixtySecondDictation() {
        // 60 s at a brisk 180 words per minute is 180 words, about 5 characters each with the space.
        XCTAssertGreaterThan(LiveTypingText.chunkThreshold, 180 * 6)
    }
}
