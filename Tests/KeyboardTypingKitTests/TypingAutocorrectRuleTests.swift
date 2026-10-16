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

    // R2: at most a quarter of the letters may change, and never more than two edits.
    func testTheAllowedDistanceGrowsWithTheLengthOfTheWord() {
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 2), 0, "two letters are never corrected")
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 3), 1)
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 7), 1)
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 8), 2)
        XCTAssertEqual(TypingAutocorrectRule.maximumDistance(forWordLength: 20), 2)
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

    // R5: with three letters a swap is the only edit trusted: "teh" is a slip, "npm" and "faq" are words.
    func testAThreeLetterWordOnlyTakesAnAdjacentSwap() {
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "teh", guesses: ["the"]), "the")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "adn", guesses: ["and"]), "and")
        XCTAssertNil(TypingAutocorrectRule.correction(for: "npm", guesses: ["nom"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "faq", guesses: ["fae"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "btw", guesses: ["btu"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "cn", guesses: ["can"]), "and a guess that adds a letter")
    }

    func testTwoEditsNeedAnEightLetterWord() {
        XCTAssertEqual(TypingEditDistance.between("vercel", "verbal"), 2)
        XCTAssertNil(TypingAutocorrectRule.correction(for: "vercel", guesses: ["verbal"]))
        XCTAssertEqual(TypingEditDistance.between("tommorow", "tomorrow"), 2)
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "tommorow", guesses: ["tomorrow"]), "tomorrow")
    }

    func testAWordOfTwoLettersIsNeverCorrected() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "ok", guesses: ["OK", "of", "oh"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "hm", guesses: ["him", "ham"]))
    }

    // R6: "clear top guess": a later guess that is closer means the checker's order is not to be trusted.
    func testACloserGuessFurtherDownMeansTheTopGuessIsNotClear() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "abcdefgh", guesses: ["abcdefghij", "abcdefghi"]))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "abcdefgh", guesses: ["abcdefghi", "abcdefghij"]), "abcdefghi")
    }

    // R6b: a tie is not clear either, unless the top guess is a swap of the letters typed.
    func testATieBetweenGuessesIsAmbiguousUnlessTheTopIsASwap() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "wich", guesses: ["wish", "which"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "wich", guesses: ["which", "witch"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "hte", guesses: ["hate", "the"]))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "teh", guesses: ["the", "ten", "tech"]), "the")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "recieve", guesses: ["receive", "relieve"]), "receive")
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
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "tommorow", guesses: ["tomorrow"]), "tomorrow")
        XCTAssertNil(TypingAutocorrectRule.correction(for: "tommorow", guesses: ["tomorrow"], strict: true))
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "recieve", guesses: ["receive"], strict: true), "receive")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "teh", guesses: ["the"], strict: true), "the")
    }

    // R12: a guess is letters only. "linked-in" for "linkedin" is the checker splitting a name.
    func testAGuessWithAHyphenOrApostropheIsSkipped() {
        XCTAssertNil(TypingAutocorrectRule.correction(for: "linkedin", guesses: ["linked-in"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "webhook", guesses: ["web-hook"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "dockerfile", guesses: ["docker-file"]))
        XCTAssertNil(TypingAutocorrectRule.correction(for: "shes", guesses: ["she's"]))
    }

    // R13: a swapped-in letter must be a slip: a vowel for a vowel, or the key next door.
    func testASubstitutionMustBeAVowelSwapOrAnAdjacentKey() {
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "definately", guesses: ["definitely"]), "definitely")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "grammer", guesses: ["grammar"]), "grammar")
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "tesy", guesses: ["test"]), "test", "t and y are neighbours")
        XCTAssertNil(TypingAutocorrectRule.correction(for: "macos", guesses: ["mamos"]), "c to m is not a slip")
        XCTAssertNil(TypingAutocorrectRule.correction(for: "wich", guesses: ["wish"]))
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
