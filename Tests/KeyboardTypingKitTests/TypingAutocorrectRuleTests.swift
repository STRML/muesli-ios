import XCTest
@testable import KeyboardTypingKit

/// Matrix rows R1-R10: the pure rule that decides whether a checker guess is a safe correction.
final class TypingAutocorrectRuleTests: XCTestCase {
    // R1: an adjacent swap is one edit, or "teh" and "adn" (three-letter words) could never be fixed.
    func testAnAdjacentTranspositionIsOneEdit() {
        XCTAssertEqual(TypingEditDistance.between("teh", "the"), 1)
        XCTAssertEqual(TypingEditDistance.between("adn", "and"), 1)
        XCTAssertEqual(TypingEditDistance.between("thier", "their"), 1)
        XCTAssertEqual(TypingEditDistance.between("recieve", "receive"), 1)
    }

    func testInsertionDeletionAndSubstitutionAreOneEditEach() {
        XCTAssertEqual(TypingEditDistance.between("wich", "which"), 1)
        XCTAssertEqual(TypingEditDistance.between("untill", "until"), 1)
        XCTAssertEqual(TypingEditDistance.between("cat", "cut"), 1)
        XCTAssertEqual(TypingEditDistance.between("same", "same"), 0)
        XCTAssertEqual(TypingEditDistance.between("kitten", "sitting"), 3)
    }

    func testDistanceIgnoresCaseAndCountsCharacters() {
        XCTAssertEqual(TypingEditDistance.between("Teh", "the"), 1)
        XCTAssertEqual(TypingEditDistance.between("café", "cafe"), 1)
    }

    // R2
    func testTheAllowedDistanceGrowsWithTheLengthOfTheWord() {
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 2), 0, "two letters are never corrected")
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 3), 1)
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 4), 2)
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 12), 2)
    }

    // R3
    func testTheTopGuessWithinRangeIsTheCorrection() {
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "recieve", guesses: ["receive", "relieve"]), "receive")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "teh", guesses: ["the", "tech", "ten"]), "the")
    }

    // R4
    func testATopGuessBeyondTheAllowedDistanceIsNotACorrection() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "kubectl", guesses: ["cubicle", "kebab"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "json", guesses: ["Jason", "jigsaw"]))
    }

    // R5
    func testAThreeLetterWordNeverTakesTwoEdits() {
        XCTAssertEqual(TypingEditDistance.between("dgo", "dogs"), 2)
        XCTAssertNil(TypingAutocorrectRule.correction(for: "dgo", guesses: ["dogs"]))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "dgoo", guesses: ["dogs"]), "dogs", "four letters may")
    }

    func testAWordOfTwoLettersIsNeverCorrected() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "ok", guesses: ["OK", "of", "oh"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "hm", guesses: ["him", "ham"]))
    }

    // R6: "clear top guess": a later guess that is closer means the checker's order is not to be trusted.
    func testACloserGuessFurtherDownMeansTheTopGuessIsNotClear() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "wrold", guesses: ["wield", "world"]))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "wrold", guesses: ["world", "wield"]), "world")
    }

    // R7
    func testAGuessWithSpacesOrPunctuationIsSkipped() {
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "alot", guesses: ["a lot", "allot"]), "allot")
        XCTAssertNil(TypingAutocorrectRule.correction(for: "alot", guesses: ["a lot"]))
    }

    // R8
    func testNoGuessesNoCorrection() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "teh", guesses: []))
    }

    // R9: a guess that only changes the case (a name, a brand) is not a spelling fix.
    func testACaseOnlyGuessIsNotACorrection() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "tuesday", guesses: ["Tuesday"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "github", guesses: ["GitHub"]))
    }

    // R10: before a "." or ":" the word may be the start of a host name or a URL scheme, so only one edit.
    func testStrictModeAllowsOnlyOneEdit() {
        XCTAssertEqual(TypingEditDistance.between("recive", "relieve"), 2)
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "recive", guesses: ["relieve"]), "relieve")
        XCTAssertNil(TypingAutocorrectRule.correction(for: "recive", guesses: ["relieve"], strict: true))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "teh", guesses: ["the"], strict: true), "the")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "recieve", guesses: ["receive"], strict: true), "receive")
    }

    func testTheGuessMustKeepTheFirstLetter() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "eelcome", guesses: ["welcome"]),
                     "a different first letter is rarely a typo and often a different word")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "welcmoe", guesses: ["welcome"]), "welcome")
    }

    // R11: lowercase typing never becomes a proper noun or an acronym; the checker offers those for brands.
    func testALowercaseWordIsNeverCorrectedToACapitalizedGuess() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "wich", guesses: ["Which"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "githb", guesses: ["GitHub"]))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "Wich", guesses: ["Which"]), "Which",
                       "a capital the user typed can stay")
    }
}
