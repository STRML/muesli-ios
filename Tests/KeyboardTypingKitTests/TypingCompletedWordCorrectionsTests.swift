import XCTest
@testable import KeyboardTypingKit

/// Matrix rows K1-K10: the checker side of the just-finished word: guesses for a misspelled one, nothing otherwise.
@MainActor
final class TypingCompletedWordCorrectionsTests: XCTestCase {
    private var checker = FakeSpellChecker()
    private var languages = ["en-US"]

    private func builder(limit: Int = 3) -> TypingSuggestionBuilder {
        checker = FakeSpellChecker()
        return TypingSuggestionBuilder(
            makeChecker: { [unowned self] in self.checker },
            languageCandidates: { [unowned self] in self.languages },
            limit: limit
        )
    }

    private func texts(_ suggestions: [TypingSuggestion]) -> [String] { suggestions.map(\.text) }

    // K1
    func testAMisspelledWordGetsItsGuessesAsCorrectionsAndNotItself() {
        let builder = builder()
        checker.misspelled = ["teh"]
        checker.guessTable["teh"] = ["the", "tech", "ten", "tea"]
        let result = builder.corrections(forCompletedWord: "teh")
        XCTAssertEqual(texts(result), ["the", "tech", "ten"])
        XCTAssertEqual(Set(result.map(\.kind)), [.correction])
    }

    // K2
    func testACorrectWordGetsNothingAndAsksNoGuesses() {
        let builder = builder()
        XCTAssertEqual(builder.corrections(forCompletedWord: "hello"), [])
        XCTAssertFalse(checker.calls.contains { $0.hasPrefix("guesses") })
    }

    // K3
    func testAMissingApostropheOffersTheContractionFirst() {
        let builder = builder()
        checker.misspelled = ["dont"]
        checker.guessTable["dont"] = ["font", "dot"]
        XCTAssertEqual(texts(builder.corrections(forCompletedWord: "dont")), ["don't", "font", "dot"])
    }

    func testAContractionThatTheCheckerAcceptsIsStillOffered() {
        let builder = builder()
        XCTAssertEqual(texts(builder.corrections(forCompletedWord: "cant")), ["can't"])
    }

    // K4
    func testAWordWithAnApostropheGetsNothing() {
        let builder = builder()
        checker.misspelled = ["don't"]
        checker.guessTable["don't"] = ["dont"]
        XCTAssertEqual(builder.corrections(forCompletedWord: "don't"), [])
    }

    // K5: the user's own words
    func testAContactNameOrShortcutIsNeverFlagged() {
        let builder = builder()
        builder.setLexicon([TypingLexiconEntry(userInput: "Sandra", documentText: "Sandra")])
        checker.misspelled = ["Sandra", "sandra"]
        checker.guessTable["Sandra"] = ["Sandy"]
        XCTAssertEqual(builder.corrections(forCompletedWord: "Sandra"), [])
        XCTAssertEqual(builder.corrections(forCompletedWord: "sandra"), [])
    }

    // K6
    func testALanguageWithNoDictionaryGetsNothing() {
        let builder = builder()
        languages = ["xx-XX"]
        checker.misspelled = ["teh"]
        checker.guessTable["teh"] = ["the"]
        XCTAssertEqual(builder.corrections(forCompletedWord: "teh"), [])
        languages = ["en-US"]
    }

    // K7
    func testGuessesFollowTheCaseTheWordWasTypedIn() {
        let builder = builder()
        checker.misspelled = ["Teh"]
        checker.guessTable["Teh"] = ["the", "tech"]
        XCTAssertEqual(texts(builder.corrections(forCompletedWord: "Teh")), ["The", "Tech"])
    }

    // K8: the contraction table is English only
    func testContractionsAreNotOfferedInOtherLanguages() {
        let builder = builder()
        languages = ["fr-FR"]
        XCTAssertEqual(builder.corrections(forCompletedWord: "dont"), [])
        languages = ["en-US"]
    }

    // K9
    func testGuessesEqualToTheWordAreDropped() {
        let builder = builder()
        checker.misspelled = ["teh"]
        checker.guessTable["teh"] = ["teh", "the"]
        XCTAssertEqual(texts(builder.corrections(forCompletedWord: "teh")), ["the"])
    }

    // K10
    func testAnEmptyWordGetsNothing() {
        XCTAssertEqual(builder().corrections(forCompletedWord: ""), [])
    }
}
