import XCTest
@testable import KeyboardTypingKit

/// Matrix row C8: the explicit contraction table. These are the highest-value fixes, and several of the
/// words ("cant") are in the dictionary, so the table cannot depend on the checker flagging them.
final class TypingContractionsTests: XCTestCase {
    func testTheClassicContractionsAreFixed() {
        let expected = [
            "dont": "don't", "cant": "can't", "im": "I'm", "youre": "you're", "doesnt": "doesn't",
            "isnt": "isn't", "wasnt": "wasn't", "couldnt": "couldn't", "wouldnt": "wouldn't",
            "shouldnt": "shouldn't", "didnt": "didn't", "havent": "haven't", "ive": "I've",
            "theyre": "they're", "thats": "that's", "arent": "aren't", "hasnt": "hasn't",
        ]
        for (typed, fixed) in expected {
            XCTAssertEqual(TypingContractions.correction(for: typed), fixed, typed)
        }
    }

    func testTheFirstLetterFollowsTheCaseTyped() {
        XCTAssertEqual(TypingContractions.correction(for: "Dont"), "Don't")
        XCTAssertEqual(TypingContractions.correction(for: "Cant"), "Can't")
        XCTAssertEqual(TypingContractions.correction(for: "Im"), "I'm")
        XCTAssertEqual(TypingContractions.correction(for: "Youre"), "You're")
    }

    func testAllCapsIsNotTouched() {
        XCTAssertNil(TypingContractions.correction(for: "DONT"))
        XCTAssertNil(TypingContractions.correction(for: "IM"))
    }

    func testAStandaloneLowercaseIIsCapitalized() {
        XCTAssertEqual(TypingContractions.correction(for: "i"), "I")
    }

    func testWeekdaysAndMonthsGetTheirCapital() {
        XCTAssertEqual(TypingContractions.correction(for: "monday"), "Monday")
        XCTAssertEqual(TypingContractions.correction(for: "september"), "September")
        XCTAssertNil(TypingContractions.correction(for: "may"), "a real word")
        XCTAssertNil(TypingContractions.correction(for: "march"), "a real word")
    }

    /// Words that are a contraction without its apostrophe and also a real word: a wrong guess is worse.
    func testRealWordsAreNeverInTheTable() {
        for word in ["ill", "id", "well", "were", "its", "hell", "shell", "wed", "lets", "wont", "hes", "shes"] {
            XCTAssertNil(TypingContractions.correction(for: word), word)
            XCTAssertNil(TypingContractions.table[word], word)
        }
    }

    func testEveryContractionIsTheSameLettersPlusAnApostropheOrACapital() {
        for (typed, fixed) in TypingContractions.table {
            XCTAssertEqual(
                fixed.lowercased().replacingOccurrences(of: "'", with: ""), typed,
                "\(typed) must only gain an apostrophe or a capital"
            )
        }
        XCTAssertGreaterThanOrEqual(TypingContractions.table.count, 25)
    }

    func testAnOrdinaryWordHasNoEntry() {
        XCTAssertNil(TypingContractions.correction(for: "hello"))
        XCTAssertNil(TypingContractions.correction(for: ""))
    }

    // Review round 1: before a "." or ":" the word may be the start of "i.e.", "im.com" or "june.app".
    func testStrictBoundariesOnlyTakeLongerContractions() {
        XCTAssertEqual(TypingContractions.correction(for: "dont", strict: true), "don't")
        XCTAssertEqual(TypingContractions.correction(for: "doesnt", strict: true), "doesn't")
        XCTAssertNil(TypingContractions.correction(for: "i", strict: true))
        XCTAssertNil(TypingContractions.correction(for: "im", strict: true))
        XCTAssertNil(TypingContractions.correction(for: "ive", strict: true))
        XCTAssertNil(TypingContractions.correction(for: "june", strict: true))
        XCTAssertNil(TypingContractions.correction(for: "april", strict: true))
        XCTAssertEqual(TypingContractions.correction(for: "june", strict: false), "June")
    }
}
