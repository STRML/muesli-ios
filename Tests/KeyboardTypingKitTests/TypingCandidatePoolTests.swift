import XCTest
@testable import KeyboardTypingKit

/// Matrix rows P1-P11: where the candidates for a flagged word come from.
@MainActor
final class TypingCandidatePoolTests: XCTestCase {
    private let words = ["the", "that", "this", "which", "with", "wish", "witch", "tomorrow", "receive", "hello", "help"]
    private var checker: DictionaryChecker!

    override func setUp() async throws {
        checker = DictionaryChecker(words: words)
    }

    private func pool(_ options: TypingCandidatePool.Options = .init()) -> TypingCandidatePool {
        TypingCandidatePool(checker: checker, language: "en_US", options: options)
    }

    // P1: the checker's guesses are candidates, in its order.
    func testTheCheckersGuessesAreCandidatesWithTheirPositions() {
        let candidates = pool().candidates(for: "wich", guesses: ["wish", "which"])
        XCTAssertEqual(candidates.map(\.word), ["wish", "which"])
        XCTAssertEqual(candidates.map(\.guessPosition), [0, 1])
    }

    // P4: a guess that the checker itself calls misspelled is not a candidate.
    func testAGuessThatIsNotAWordIsDropped() {
        let candidates = pool().candidates(for: "wich", guesses: ["whihc", "which"])
        XCTAssertEqual(candidates.map(\.word), ["which"])
        XCTAssertEqual(candidates.map(\.guessPosition), [1], "the position is the checker's, not the filtered list's")
    }

    // P5: only plain words; a hyphenated, spaced or apostrophe guess is another kind of fix.
    func testGuessesThatAreNotSingleWordsOfLettersAreDropped() {
        checker = DictionaryChecker(words: words + ["web-hook", "web hook", "don't"])
        let candidates = pool().candidates(for: "webhok", guesses: ["web-hook", "web hook", "don't"])
        XCTAssertTrue(candidates.isEmpty)
    }

    // P6: a word the user took back is not offered as the target of some other typo.
    func testExcludedWordsAreNeverCandidates() {
        let candidates = pool().candidates(for: "tomorow", guesses: ["tomorrow"], excluding: ["tomorrow"])
        XCTAssertTrue(candidates.isEmpty)
    }

    // P11: lowercase typing is never turned into a name; a capital the user typed can stay.
    func testALowercaseWordIsNeverOfferedACapitalizedGuess() {
        checker = DictionaryChecker(words: words + ["Jason", "Which"])
        XCTAssertTrue(pool().candidates(for: "json", guesses: ["Jason"]).isEmpty)
        XCTAssertEqual(pool().candidates(for: "Wich", guesses: ["Which"]).map(\.word), ["which"])
    }

    // P7: the typed word itself is never its own candidate, and case does not matter.
    func testTheTypedWordIsNotACandidate() {
        let candidates = pool().candidates(for: "Wich", guesses: ["Wich", "which"])
        XCTAssertFalse(candidates.contains { $0.word == "wich" })
        XCTAssertTrue(candidates.contains { $0.word == "which" })
    }

    // P8: usage comes from the checker's own completions.
    func testUsageIsThePlaceInTheCompletionsOfEachPrefix() {
        let candidates = pool(.init(usageDepth: 3)).candidates(for: "wich", guesses: ["which"])
        let which = candidates.first { $0.word == "which" }
        XCTAssertEqual(which?.usage.count, 3)
        // "w": the completions in dictionary order are which, with, wish, witch.
        XCTAssertEqual(which?.usage.first, 0)
    }

    func testAWordThatIsNotListedUnderAPrefixHasMinusOne() {
        let crowd = (100..<125).map { "wa\($0)" }
        checker = DictionaryChecker(words: crowd + ["which"])
        let which = pool(.init(usageDepth: 2)).candidates(for: "wich", guesses: ["which"]).first
        XCTAssertEqual(which?.usage, [-1, 0], "twenty-five words crowd it out of the top 20 for \"w\", not for \"wh\"")
    }

    // P9: only the cheapest candidates are looked up in the completions.
    func testUsageIsOnlyLookedUpForTheCheapestCandidates() {
        let candidates = pool(.init(usageLimit: 1)).candidates(for: "wich", guesses: ["wish", "with", "which"])
        XCTAssertEqual(candidates.filter { !$0.usage.isEmpty }.count, 1)
    }

    // P10: a long word is handed to the checker as it is; nothing is expanded.
    func testAVeryLongWordCostsOneGuessCall() {
        XCTAssertTrue(pool().candidates(for: String(repeating: "a", count: 30), guesses: []).isEmpty)
    }
}
