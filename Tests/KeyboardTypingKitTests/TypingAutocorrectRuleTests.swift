import XCTest
@testable import KeyboardTypingKit

/// Matrix rows R1-R16: the pure rule that decides whether the best candidate is a safe correction.
final class TypingAutocorrectRuleTests: XCTestCase {
    /// A candidate the checker guessed at `guess`, listed under its first `listedAt` letters (1 is the most used).
    private func candidate(_ word: String, guess: Int? = 0, listedAt: Int? = 1, position: Int = 0) -> TypingCandidate {
        var usage = [Int](repeating: -1, count: max(word.count, 4))
        if let listedAt { usage[listedAt - 1] = position }
        return TypingCandidate(word: word, guessPosition: guess, usage: usage)
    }

    private func fix(_ typed: String, _ candidates: [TypingCandidate], strict: Bool = false) -> String? {
        TypingAutocorrectRule.correction(for: typed, candidates: candidates, strict: strict)
    }

    func testAnAdjacentTranspositionIsOneEdit() {
        XCTAssertEqual(TypingEditDistance.between("teh", "the"), 1)
        XCTAssertEqual(TypingEditDistance.between("adn", "and"), 1)
        XCTAssertEqual(TypingEditDistance.between("recieve", "receive"), 1)
    }

    func testInsertionDeletionAndSubstitutionAreOneEditEach() {
        XCTAssertEqual(TypingEditDistance.between("wich", "which"), 1)
        XCTAssertEqual(TypingEditDistance.between("cat", "cut"), 1)
        XCTAssertEqual(TypingEditDistance.between("same", "same"), 0)
        XCTAssertEqual(TypingEditDistance.between("kitten", "sitting"), 3)
        XCTAssertEqual(TypingEditDistance.between("Teh", "the"), 1)
    }

    // R1
    func testOneClearCandidateIsTheCorrection() {
        XCTAssertEqual(fix("recieve", [candidate("receive")]), "receive")
        XCTAssertEqual(fix("teh", [candidate("the")]), "the")
        XCTAssertEqual(fix("tomorow", [candidate("tomorrow", guess: nil)]), "tomorrow", "found by our own generation only")
    }

    // R2: a three-letter word only takes a swap: "npm" and "faq" are not typos, and "wel" for "well" and "ide" for
    // "idea" cost more wrong fixes than they gain on the generated corpus.
    func testAThreeLetterWordOnlyTakesASwap() {
        XCTAssertEqual(fix("adn", [candidate("and")]), "and")
        XCTAssertNil(fix("thw", [candidate("the")]), "w is beside e, but a swap is the only slip trusted")
        XCTAssertNil(fix("wel", [candidate("well")]))
        XCTAssertNil(fix("npm", [candidate("nom")]))
        XCTAssertNil(fix("cto", [candidate("cot", listedAt: nil)]), "a swap to a word nobody uses is an acronym, not a slip")
    }

    // R3
    func testTwoLettersOrFewerAreNeverCorrected() {
        XCTAssertNil(fix("cn", [candidate("can")]))
        XCTAssertNil(fix("im", [candidate("in")]))
    }

    // R4: too far from what was typed.
    func testACandidateOverTheCostBudgetIsNotACorrection() {
        XCTAssertNil(fix("kubectl", [candidate("cubicle", guess: 0)]))
        XCTAssertNil(fix("macos", [candidate("mamos", listedAt: nil)]), "c to m is not a slip")
    }

    // R5: ties are decided by the margin, not declined outright.
    func testTwoEquallyGoodCandidatesAreAmbiguous() {
        XCTAssertNil(fix("wich", [candidate("witch", position: 3), candidate("which", position: 3)]))
    }

    func testAClearlyMoreUsedCandidateWinsOverAnEquallyCloseOne() {
        let which = candidate("which", guess: 2, listedAt: 2, position: 6)
        let witch = candidate("witch", guess: 4, listedAt: nil)
        XCTAssertEqual(fix("wich", [witch, which]), "which")
    }

    // R6
    func testTheCheapestSlipBeatsAnArbitrarySubstitution() {
        XCTAssertEqual(fix("hte", [candidate("the", guess: 3), candidate("hue", guess: 0)]), "the")
    }

    // R7: a word nobody uses is not worth correcting to.
    func testACandidateTheCheckerNeverListsIsHeldBack() {
        XCTAssertNil(fix("oauth", [candidate("oath", listedAt: nil)]))
    }

    // R8: before a "." or ":" the word may be a host name, so only a single edit counts.
    func testStrictBoundariesNeedASingleEdit() {
        XCTAssertEqual(fix("teh", [candidate("the")], strict: true), "the")
        XCTAssertNil(fix("becuawe", [candidate("because")], strict: true), "two edits")
        XCTAssertEqual(fix("becuawe", [candidate("because")]), "because")
    }

    // R9: more edits for longer words, when the budget allows and the margin holds. The tuned budget is one
    // vowel swap plus one dropped letter short of this word, so it is declined until the budget is raised.
    func testALongWordMayTakeTwoSlipsOnlyWithinTheBudget() {
        XCTAssertNil(fix("definatly", [candidate("definitely", guess: 0), candidate("definately", guess: 1, listedAt: nil)]))
        var tuning = TypingAutocorrectTuning.standard
        tuning.budgetEightOrMore = 2.0
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "definatly", candidates: [candidate("definitely"), candidate("definately", guess: 1, listedAt: nil)], tuning: tuning), "definitely")
        XCTAssertNil(fix("flxm", [candidate("film")]), "a four-letter word is not given two slips")
    }

    func testTwoCheapSlipsFitTheBudgetOfALongWord() {
        // "becuawe" for "because": a swap and a neighbour key.
        XCTAssertEqual(fix("becuawe", [candidate("because", guess: 0)]), "because")
    }

    func testNoCandidatesNoCorrection() {
        XCTAssertNil(fix("zzzz", []))
    }

    // R10
    func testTheTypedWordItselfIsNeverTheCorrection() {
        XCTAssertNil(fix("teh", [candidate("teh")]))
    }

    // R11: a candidate more than two letters longer or shorter never scores.
    func testALengthDifferenceOfThreeIsNeverCorrected() {
        XCTAssertNil(fix("config", [candidate("configuration")]))
    }

    // R12
    func testScoredCandidatesAreSortedBestFirstWithTheirCost() {
        let scored = TypingAutocorrectRule.scored(
            for: "wich", candidates: [candidate("witch", guess: 4, listedAt: nil), candidate("which", guess: 2, listedAt: 2, position: 6)],
            tuning: .standard
        )
        XCTAssertEqual(scored.map(\.word), ["which", "witch"])
        XCTAssertLessThan(scored[0].score, scored[1].score)
    }

    // R13: the margin has to be met; widening it turns a correction into a decline.
    func testALargerMarginDeclinesWhatASmallerOneTakes() {
        // "wirk": "work" is a neighbour key away, "wark" a vowel swap.
        let candidates = [candidate("work"), candidate("wark", guess: 1)]
        var tuning = TypingAutocorrectTuning.standard
        tuning.margin = 0
        XCTAssertEqual(TypingAutocorrectRule.correction(for: "wirk", candidates: candidates, tuning: tuning), "work")
        tuning.margin = 10
        XCTAssertNil(TypingAutocorrectRule.correction(for: "wirk", candidates: candidates, tuning: tuning))
    }

    // R14: the usage depth is the number of prefix letters that count.
    func testAWordListedOnlyPastTheUsageDepthCountsAsUnlisted() {
        var tuning = TypingAutocorrectTuning.standard
        let deep = TypingCandidate(word: "work", guessPosition: 0, usage: [-1, -1, -1, 0])
        tuning.usageDepth = 3
        let shallow = TypingAutocorrectRule.scored(for: "wirk", candidates: [deep], tuning: tuning)
        tuning.usageDepth = 4
        let full = TypingAutocorrectRule.scored(for: "wirk", candidates: [deep], tuning: tuning)
        XCTAssertGreaterThan(shallow[0].score, full[0].score)
    }

    // R15: the budget table.
    func testTheBudgetGrowsWithTheLengthOfTheWord() {
        let tuning = TypingAutocorrectTuning.standard
        XCTAssertEqual(tuning.budget(forWordLength: 2), 0)
        XCTAssertLessThan(tuning.budget(forWordLength: 3), tuning.budget(forWordLength: 5))
        XCTAssertLessThanOrEqual(tuning.budget(forWordLength: 5), tuning.budget(forWordLength: 7))
        XCTAssertLessThan(tuning.budget(forWordLength: 7), tuning.budget(forWordLength: 12))
    }

    // R16: the rule works on lowercase; the pool lowercases candidates and the autocorrector restores a capital.
    func testCasingOfTheTypedWordDoesNotChangeTheDecision() {
        XCTAssertEqual(fix("Teh", [candidate("the")]), "the")
        XCTAssertEqual(fix("TEH", [candidate("the")]), "the")
    }

    // R17: when the checker offers exactly one candidate there is no runner-up to confuse it with, so the edit
    // budget is looser. Measured on the hand-made list: "truely", "maintainance", "tommorow", "arguement",
    // "dissapear" were each rejected only by the budget.
    func testASoleCandidateTakesALooserBudget() {
        XCTAssertEqual(fix("truely", [candidate("truly")]), "truly")
        XCTAssertEqual(fix("maintainance", [candidate("maintenance")]), "maintenance")
        XCTAssertEqual(fix("tommorow", [candidate("tomorrow")]), "tomorrow")
        XCTAssertEqual(fix("arguement", [candidate("argument")]), "argument")
        XCTAssertEqual(fix("dissapear", [candidate("disappear")]), "disappear")
    }

    func testTwoCandidatesAtEqualCostAreStillAmbiguous() {
        XCTAssertNil(fix("wich", [candidate("witch", position: 3), candidate("which", position: 3)]))
    }

    func testTheLooserBudgetDoesNotApplyWithTwoCandidates() {
        // "truly" costs 1.4, over the strict 1.0, and the second candidate is not a sole-pool excuse.
        XCTAssertNil(fix("truely", [candidate("truly"), candidate("trussly", guess: nil, listedAt: nil)]))
    }

    func testASoleCandidateBeyondTheLooserBudgetIsStillDeclined() {
        XCTAssertNil(fix("kubectl", [candidate("cubicle")]))
        XCTAssertNil(fix("flxm", [candidate("film")]), "a four-letter word is not given two slips")
    }

    func testAThreeLetterWordKeepsItsSwapOnlyRuleForASoleCandidate() {
        XCTAssertEqual(fix("adn", [candidate("and")]), "and")
        XCTAssertNil(fix("wel", [candidate("well")]))
        XCTAssertNil(fix("thw", [candidate("the")]))
    }

    func testTheStrictBoundaryStillNeedsASingleEditForASoleCandidate() {
        XCTAssertEqual(fix("truely", [candidate("truly")], strict: true), "truly", "one deletion")
        XCTAssertNil(fix("dissapear", [candidate("disappear")], strict: true), "a swap and a dropped letter: two edits")
    }
}
