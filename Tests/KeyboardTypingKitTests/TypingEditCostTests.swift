import XCTest
@testable import KeyboardTypingKit

/// Matrix rows W1-W9: the weighted edit distance that ranks candidates.
final class TypingEditCostTests: XCTestCase {
    private func cost(_ typed: String, _ candidate: String) -> Double { TypingEditCost.between(typed, candidate) }

    // W1
    func testIdenticalWordsCostNothingAndCaseIsIgnored() {
        XCTAssertEqual(cost("the", "the"), 0)
        XCTAssertEqual(cost("Teh", "the"), cost("teh", "the"), accuracy: 1e-9)
    }

    // W2: a swapped pair is the cheapest slip there is.
    func testATranspositionCostsLessThanAnySubstitution() {
        XCTAssertEqual(cost("recieve", "receive"), TypingEditWeights().transposition, accuracy: 1e-9)
        XCTAssertLessThan(cost("teh", "the"), cost("tha", "the") + 1e-9)
    }

    // W3
    func testANeighbourKeyCostsLessThanAKeyFromAcrossTheKeyboard() {
        XCTAssertLessThan(cost("wirk", "work"), cost("wmrk", "work"))
        XCTAssertEqual(cost("dpme", "dome"), TypingEditWeights().neighbourSubstitution, accuracy: 1e-9)
    }

    // W4
    func testAVowelForAVowelIsCheaperThanAnArbitraryLetter() {
        XCTAssertEqual(cost("definately", "definitely"), TypingEditWeights().vowelSubstitution, accuracy: 1e-9)
        XCTAssertLessThan(cost("seperate", "separate"), cost("sxperate", "separate"))
    }

    // W5
    func testADroppedDoubledLetterIsCheaperThanAnyOtherDroppedLetter() {
        XCTAssertLessThan(cost("tomorow", "tomorrow"), cost("tomoro", "tomorrow"))
        XCTAssertEqual(cost("tomorow", "tomorrow"), TypingEditWeights().doubledInsertion, accuracy: 1e-9)
    }

    // W6
    func testATypedExtraLetterThatRepeatsItsNeighbourIsCheaperThanOtherExtraLetters() {
        XCTAssertLessThan(cost("thhe", "the"), cost("thxe", "the"))
        XCTAssertEqual(cost("thhe", "the"), TypingEditWeights().doubledDeletion, accuracy: 1e-9)
    }

    // W7: nobody misspells how a word starts as often as how it ends.
    func testChangingTheFirstLetterCostsExtra() {
        XCTAssertGreaterThan(cost("rhe", "the"), cost("thr", "the"))
        XCTAssertEqual(cost("he", "the"), TypingEditWeights().insertion + TypingEditWeights().firstLetter, accuracy: 1e-9)
    }

    // W8
    func testTwoSlipsCostAboutTwice() {
        let one = cost("definately", "definitely")
        XCTAssertEqual(cost("definatly", "definitely"), one + TypingEditWeights().insertion, accuracy: 1e-9)
    }

    // W9
    func testEmptyWordsAreHandled() {
        XCTAssertEqual(cost("", "the"), 3)
        XCTAssertEqual(cost("the", ""), 3)
        XCTAssertEqual(cost("", ""), 0)
    }
}
