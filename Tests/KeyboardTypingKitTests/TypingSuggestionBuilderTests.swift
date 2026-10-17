import XCTest
@testable import KeyboardTypingKit

@MainActor
final class FakeSpellChecker: TypingSpellChecking {
    var availableLanguages = ["en_US", "en_GB", "fr_FR", "es_ES"]
    var misspelled = Set<String>()
    var completionTable: [String: [String]] = [:]
    var guessTable: [String: [String]] = [:]
    private(set) var calls: [String] = []

    func isMisspelled(_ word: String, language: String) -> Bool {
        calls.append("misspelled:\(language)")
        return misspelled.contains(word)
    }

    func completions(forPartial partial: String, language: String) -> [String] {
        calls.append("completions:\(language)")
        return completionTable[partial] ?? []
    }

    func guesses(forWord word: String, language: String) -> [String] {
        calls.append("guesses:\(language)")
        return guessTable[word] ?? []
    }
}

/// Matrix rows G1-G12: what the strip offers for the partial word.
@MainActor
final class TypingSuggestionBuilderTests: XCTestCase {
    private var checker = FakeSpellChecker()
    private var made = 0
    private var languages = ["en-US"]

    private func builder(limit: Int = 3) -> TypingSuggestionBuilder {
        checker = FakeSpellChecker()
        made = 0
        return TypingSuggestionBuilder(
            makeChecker: { [unowned self] in
                self.made += 1
                return self.checker
            },
            languageCandidates: { [unowned self] in self.languages },
            limit: limit
        )
    }

    private func texts(_ suggestions: [TypingSuggestion]) -> [String] { suggestions.map(\.text) }

    // G1
    func testACorrectlySpelledPartialGetsCompletions() {
        let builder = builder()
        checker.completionTable["hel"] = ["help", "hello", "helmet", "helicopter"]
        let result = builder.suggestions(forPartial: "hel")
        XCTAssertEqual(texts(result), ["help", "hello", "helmet"])
        XCTAssertEqual(Set(result.map(\.kind)), [.completion])
    }

    // G2
    func testAMisspelledWordOffersWhatWasTypedThenGuesses() {
        let builder = builder()
        checker.misspelled = ["teh"]
        checker.guessTable["teh"] = ["the", "tech", "ten"]
        let result = builder.suggestions(forPartial: "teh")
        XCTAssertEqual(texts(result), ["teh", "the", "tech"])
        XCTAssertEqual(result.map(\.kind), [.verbatim, .correction, .correction])
    }

    func testGuessesComeBeforeCompletionsForAMisspelledWord() {
        let builder = builder(limit: 5)
        checker.misspelled = ["helo"]
        checker.guessTable["helo"] = ["hello"]
        checker.completionTable["helo"] = ["helot"]
        XCTAssertEqual(texts(builder.suggestions(forPartial: "helo")), ["helo", "hello", "helot"])
    }

    func testAPartialWordKeepsRoomForItsCompletionAmongTheGuesses() {
        let builder = builder()
        checker.misspelled = ["offi"]
        checker.guessTable["offi"] = ["off", "offa", "offs"]
        checker.completionTable["offi"] = ["office", "officer"]
        XCTAssertEqual(texts(builder.suggestions(forPartial: "offi")), ["offi", "off", "office"])
    }

    // G3: a text replacement matches its shortcut exactly and leads the strip.
    func testATextReplacementShortcutIsOfferedFirst() {
        let builder = builder()
        builder.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        checker.misspelled = ["omw"]
        checker.guessTable["omw"] = ["own"]
        let result = builder.suggestions(forPartial: "omw")
        XCTAssertEqual(result.first, TypingSuggestion(text: "On my way!", kind: .lexicon))
        XCTAssertTrue(texts(result).contains("omw"))
    }

    // G4
    func testContactNamesMatchByPrefixCaseInsensitively() {
        let builder = builder()
        builder.setLexicon([
            TypingLexiconEntry(userInput: "Samuel", documentText: "Samuel"),
            TypingLexiconEntry(userInput: "Sandra", documentText: "Sandra"),
            TypingLexiconEntry(userInput: "Bob", documentText: "Bob"),
        ])
        checker.completionTable["sa"] = ["sad", "safe"]
        let result = builder.suggestions(forPartial: "sa")
        XCTAssertEqual(texts(result), ["Samuel", "Sandra", "sad"])
        XCTAssertEqual(result.map(\.kind), [.lexicon, .lexicon, .completion])
    }

    // G5
    func testDuplicatesAndTheTypedWordAreDroppedFromCompletions() {
        let builder = builder()
        checker.completionTable["hel"] = ["hel", "hello", "Hello", "HELLO", "help"]
        XCTAssertEqual(texts(builder.suggestions(forPartial: "hel")), ["hello", "help"])
    }

    func testCompletionsFollowTheCaseTheUserIsTyping() {
        let builder = builder()
        checker.completionTable["Hel"] = ["help", "hello"]
        checker.completionTable["HEL"] = ["help"]
        XCTAssertEqual(texts(builder.suggestions(forPartial: "Hel")), ["Help", "Hello"])
        XCTAssertEqual(texts(builder.suggestions(forPartial: "HEL")), ["HELP"])
    }

    // G6
    func testACheckerWithNothingToSayGivesAnEmptyStrip() {
        let builder = builder()
        XCTAssertEqual(builder.suggestions(forPartial: "zzzq"), [])
    }

    // G7: Full Access off means the lexicon never arrives; the strip still works.
    func testWithoutALexiconTheCheckerStillWorks() {
        let builder = builder()
        checker.completionTable["hel"] = ["hello"]
        XCTAssertEqual(texts(builder.suggestions(forPartial: "hel")), ["hello"])
    }

    // G8
    func testAnUnsupportedLanguageGivesNoCheckerSuggestionsButStillTheLexicon() {
        let builder = builder()
        languages = ["zh-Hans"]
        checker.completionTable["hel"] = ["hello"]
        builder.setLexicon([TypingLexiconEntry(userInput: "Helen", documentText: "Helen")])
        XCTAssertEqual(texts(builder.suggestions(forPartial: "hel")), ["Helen"])
        XCTAssertFalse(checker.calls.contains { $0.hasPrefix("completions") })
    }

    // G9
    func testLanguageResolution() {
        let available = ["en_US", "en_GB", "fr_FR", "es_ES"]
        XCTAssertEqual(TypingLanguageResolver.resolve(candidates: ["en-US"], available: available), "en_US")
        XCTAssertEqual(TypingLanguageResolver.resolve(candidates: ["en-GB"], available: available), "en_GB")
        XCTAssertEqual(TypingLanguageResolver.resolve(candidates: ["en-AU"], available: available), "en_US", "same language, first region")
        XCTAssertEqual(TypingLanguageResolver.resolve(candidates: ["fr-CA"], available: available), "fr_FR")
        XCTAssertEqual(TypingLanguageResolver.resolve(candidates: ["es"], available: available), "es_ES")
        XCTAssertNil(TypingLanguageResolver.resolve(candidates: ["zh-Hans"], available: available))
        XCTAssertEqual(TypingLanguageResolver.resolve(candidates: ["zh-Hans", "fr-FR"], available: available), "fr_FR", "falls through to the next candidate")
        XCTAssertNil(TypingLanguageResolver.resolve(candidates: [], available: available))
        XCTAssertNil(TypingLanguageResolver.resolve(candidates: ["en-US"], available: []))
    }

    // G10: memory. The checker is made on first use and again after the document changes.
    func testTheCheckerIsMadeLazilyOncePerDocument() {
        let builder = builder()
        XCTAssertEqual(made, 0)
        XCTAssertFalse(builder.hasCreatedChecker)
        _ = builder.suggestions(forPartial: "hel")
        _ = builder.suggestions(forPartial: "help")
        XCTAssertEqual(made, 1)
        XCTAssertTrue(builder.hasCreatedChecker)
        builder.documentDidChange()
        XCTAssertFalse(builder.hasCreatedChecker)
        XCTAssertEqual(made, 1)
        _ = builder.suggestions(forPartial: "hel")
        XCTAssertEqual(made, 2)
    }

    // G11
    func testAnEmptyPartialMakesNoChecker() {
        let builder = builder()
        XCTAssertEqual(builder.suggestions(forPartial: ""), [])
        XCTAssertEqual(made, 0)
    }

    // G12
    func testTheLexiconIsCapped() {
        let builder = builder()
        let entries = (0..<(TypingSuggestionBuilder.maximumLexiconEntries + 500)).map {
            TypingLexiconEntry(userInput: "name\($0)", documentText: "Name\($0)")
        }
        builder.setLexicon(entries)
        XCTAssertEqual(builder.lexiconCount, TypingSuggestionBuilder.maximumLexiconEntries)
    }

    func testLexiconEntriesWithEmptyFieldsAreIgnored() {
        let builder = builder()
        builder.setLexicon([
            TypingLexiconEntry(userInput: "", documentText: "x"),
            TypingLexiconEntry(userInput: "x", documentText: ""),
            TypingLexiconEntry(userInput: "ok", documentText: "Okay"),
        ])
        XCTAssertEqual(builder.lexiconCount, 1)
    }

    func testTheLimitIsRespected() {
        let builder = builder(limit: 2)
        checker.completionTable["a"] = ["apple", "ant", "ask"]
        XCTAssertEqual(texts(builder.suggestions(forPartial: "a")), ["apple", "ant"])
    }
}
