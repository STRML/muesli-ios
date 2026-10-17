import XCTest
@testable import KeyboardTypingKit

/// Matrix rows C1-C30: the decision to correct a finished word, with a fake checker. The real checker runs in
/// the simulator corpus test.
@MainActor
final class TypingAutocorrectorTests: XCTestCase {
    private var checker = FakeSpellChecker()
    private var traits = TypingTraits()
    private var enabled = true
    private var languages = ["en-US"]
    private var ignored: [String] = []
    private var corrector: TypingAutocorrector!

    override func setUp() async throws {
        checker = FakeSpellChecker()
        traits = TypingTraits()
        enabled = true
        languages = ["en-US"]
        ignored = []
        corrector = TypingAutocorrector(
            checker: { [unowned self] in self.checker },
            languageCandidates: { [unowned self] in self.languages },
            traits: { [unowned self] in self.traits },
            isEnabled: { [unowned self] in self.enabled },
            ignoreWord: { [unowned self] in self.ignored.append($0) }
        )
        checker.misspelled = ["teh", "recieve", "definately", "wich", "adn", "Teh", "TEH", "iPhone", "omw",
                              "hashtg", "gmial", "sam", "githb", "kubectl", "json", "tomorow"]
        checker.guessTable = [
            "teh": ["the"], "recieve": ["receive"], "definately": ["definitely"], "wich": ["which"],
            "adn": ["and"], "Teh": ["the"], "TEH": ["THE"], "iPhone": ["phone"], "omw": ["own"],
            "hashtg": ["hashtag"], "gmial": ["gmail"], "sam": ["same"], "githb": ["github"],
            "kubectl": ["cubicle"], "json": ["Jason"], "tomorow": ["tomorrow"],
        ]
        checker.listGuessesAsUsed()
    }

    private func event(
        _ word: String, _ boundary: TypingBoundary = .space, before: String? = nil
    ) -> TypingWordCompletedEvent {
        TypingWordCompletedEvent(
            word: word, boundary: boundary, contextBefore: before ?? "I think \(word)", documentIdentifier: nil
        )
    }

    private func plan(_ word: String, _ boundary: TypingBoundary = .space, before: String? = nil) -> TypingEditPlan? {
        corrector.wordCompleted(event(word, boundary, before: before))
    }

    private func plan(for word: String, to fixed: String, boundary: String = " ") -> TypingEditPlan {
        TypingEditPlan(
            deleteCount: word.count, insertText: fixed, expectedSuffix: word,
            undo: TypingReplacementUndo(
                replacedText: word + boundary, insertedText: fixed + boundary, originalWord: word
            )
        )
    }

    // C1
    func testAMisspelledWordWithAClearGuessIsCorrectedOnSpace() {
        XCTAssertEqual(plan("teh"), plan(for: "teh", to: "the"))
        XCTAssertEqual(plan("recieve"), plan(for: "recieve", to: "receive"))
    }

    // C2
    func testItCorrectsBeforeEachSentencePunctuation() {
        for mark in [".", ",", "!", "?", ";", ":"] {
            XCTAssertEqual(plan("teh", .punctuation(mark)), plan(for: "teh", to: "the", boundary: mark), mark)
        }
    }

    func testOtherPunctuationIsNotATrigger() {
        for mark in ["/", "@", "#", "(", ")", "\"", "'", "-", "_", "&", "*", "=", "+", "<", "\\", "|"] {
            XCTAssertNil(plan("teh", .punctuation(mark)), mark)
        }
    }

    // C3
    func testItCorrectsBeforeReturn() {
        XCTAssertEqual(plan("teh", .returnKey), plan(for: "teh", to: "the", boundary: "\n"))
    }

    // C4
    func testAWordAtTheStartOfTheFieldIsCorrected() {
        XCTAssertEqual(plan("teh", before: "teh"), plan(for: "teh", to: "the"))
    }

    func testAWordAfterANewlineIsCorrected() {
        XCTAssertEqual(plan("teh", before: "hello\nteh"), plan(for: "teh", to: "the"))
    }

    func testTheFirstLetterFollowsTheCaseTyped() {
        XCTAssertEqual(plan("Teh", before: "Teh")?.insertText, "The", "a capital at the start of a sentence stays")
        XCTAssertEqual(plan("Teh", before: "Done. Teh")?.insertText, "The")
    }

    // C5
    func testTheEditNamesWhatItReplaces() {
        let result = plan("teh")
        XCTAssertEqual(result?.deleteCount, 3)
        XCTAssertEqual(result?.expectedSuffix, "teh")
        XCTAssertEqual(result?.undo?.originalWord, "teh")
    }

    // C6
    func testATextReplacementAppliesOnSpaceAndBeatsTheSpellChecker() {
        corrector.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        let result = plan("omw")
        XCTAssertEqual(result?.insertText, "On my way!")
        XCTAssertEqual(result?.undo?.replacedText, "omw ")
        XCTAssertEqual(result?.undo?.insertedText, "On my way! ")
        XCTAssertTrue(checker.calls.isEmpty, "the checker was not even asked")
    }

    func testATextReplacementMatchesIgnoringCase() {
        corrector.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        XCTAssertEqual(plan("Omw", before: "ok Omw")?.insertText, "On my way!")
    }

    func testATextReplacementDoesNotFireOnPunctuationOrReturn() {
        corrector.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        XCTAssertNil(plan("omw", .punctuation(",")))
        XCTAssertNil(plan("omw", .returnKey))
    }

    // C7
    func testAContactNameIsNeverCorrected() {
        corrector.setLexicon([TypingLexiconEntry(userInput: "Sam", documentText: "Sam")])
        XCTAssertNil(plan("sam"), "the checker flags it and has a guess, the contact wins")
        XCTAssertTrue(checker.calls.isEmpty)
    }

    func testAContactBeyondTheStripsCapIsStillKnown() {
        var entries = (0..<2500).map { TypingLexiconEntry(userInput: "contact\($0)", documentText: "Contact \($0)") }
        entries.append(TypingLexiconEntry(userInput: "kubectl", documentText: "kubectl"))
        corrector.setLexicon(entries)
        XCTAssertGreaterThan(entries.count, TypingSuggestionBuilder.maximumLexiconEntries)
        XCTAssertNil(plan("kubectl"))
    }

    // C8
    func testTheContractionTableFixesAWordTheCheckerDoesNotFlag() {
        XCTAssertEqual(plan("cant")?.insertText, "can't")
        XCTAssertEqual(plan("dont")?.insertText, "don't")
        XCTAssertEqual(plan("im")?.insertText, "I'm")
        XCTAssertEqual(plan("youre")?.insertText, "you're")
        XCTAssertTrue(checker.calls.isEmpty, "the table comes before the checker")
    }

    func testTheContractionTableAppliesBeforePunctuation() {
        XCTAssertEqual(plan("dont", .punctuation("."))?.insertText, "don't")
        XCTAssertEqual(plan("im", .punctuation(","))?.insertText, "I'm")
    }

    func testTheShortTableEntriesAreNotAppliedBeforeADotOrColon() {
        for mark in [".", ":"] {
            XCTAssertNil(plan("i", .punctuation(mark), before: "e.g. i"), "i.e. must stay")
            XCTAssertNil(plan("im", .punctuation(mark)), "im.com must stay")
            XCTAssertNil(plan("june", .punctuation(mark)), "june.app must stay")
            XCTAssertEqual(plan("dont", .punctuation(mark))?.insertText, "don't", "a sentence can end in dont.")
        }
        XCTAssertEqual(plan("i")?.insertText, "I", "before a space it is fine")
    }

    func testTheContractionTableIsEnglishOnly() {
        languages = ["fr-FR"]
        XCTAssertNil(plan("dont"), "\"dont\" is French for \"of which\"")
    }

    func testNoTableAppliesWithoutADictionaryForTheLanguage() {
        languages = ["xx-XX"]
        XCTAssertNil(plan("dont"))
    }

    func testAnEnglishVariantUsesTheTable() {
        languages = ["en-GB"]
        XCTAssertEqual(plan("dont")?.insertText, "don't")
    }

    // C9
    func testAllCapsIsNeverCorrected() {
        XCTAssertNil(plan("TEH"))
    }

    func testMixedCaseIsNeverCorrected() {
        XCTAssertNil(plan("iPhone"))
    }

    func testAWordWithAnApostropheOrHyphenIsNeverSpellCorrected() {
        checker.misspelled.insert("teh's")
        checker.guessTable["teh's"] = ["the's"]
        XCTAssertNil(plan("teh's"))
        XCTAssertNil(plan("well-knwn"))
    }

    func testADigitWordIsNeverCorrected() {
        checker.misspelled.insert("teh2")
        checker.guessTable["teh2"] = ["the"]
        XCTAssertNil(plan("teh2"))
    }

    func testAHashtagIsNeverCorrected() { XCTAssertNil(plan("hashtg", before: "so #hashtg")) }
    func testAHandleIsNeverCorrected() { XCTAssertNil(plan("sam", before: "ping @sam")) }
    func testAnEmailIsNeverCorrected() { XCTAssertNil(plan("gmial", before: "me at sam@gmial")) }
    func testAUrlHostIsNeverCorrected() { XCTAssertNil(plan("githb", .punctuation("."), before: "see https://githb")) }

    func testACapitalizedWordMidSentenceIsAssumedToBeAName() {
        XCTAssertNil(plan("Teh", before: "I met Teh"))
    }

    func testAShortWordIsNeverSpellCorrected() {
        checker.misspelled.insert("hm")
        checker.guessTable["hm"] = ["him"]
        XCTAssertNil(plan("hm"))
    }

    func testAVeryLongWordNeverReachesTheChecker() {
        let long = String(repeating: "a", count: 40)
        XCTAssertNil(plan(long))
        XCTAssertTrue(checker.calls.isEmpty)
    }

    // C10
    func testAWordTheCheckerAcceptsIsLeftAlone() {
        XCTAssertNil(plan("hello"))
    }

    func testAMisspelledWordWithNoGuessIsLeftAlone() {
        checker.misspelled.insert("xyzzy")
        XCTAssertNil(plan("xyzzy"))
    }

    func testAGuessThatIsTooFarIsLeftAlone() {
        XCTAssertNil(plan("kubectl"))
        XCTAssertNil(plan("json"))
    }

    // C11
    func testARejectedWordIsNotCorrectedAgainAndIsIgnoredByTheChecker() throws {
        let first = try XCTUnwrap(plan("teh"))
        corrector.replacementWasRejected(try XCTUnwrap(first.undo))
        XCTAssertNil(plan("teh"))
        XCTAssertNil(plan("Teh", before: "Teh"), "case does not get around it")
        XCTAssertEqual(ignored, ["teh"])
        XCTAssertNotNil(plan("recieve"), "only that word")
    }

    func testARejectedTextReplacementIsNotAppliedAgain() throws {
        corrector.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        let first = try XCTUnwrap(plan("omw"))
        corrector.replacementWasRejected(try XCTUnwrap(first.undo))
        XCTAssertNil(plan("omw"))
    }

    // C12
    func testEmailUrlAndNumericFieldsAreNeverCorrected() {
        for variant in [TypingKeyboardVariant.email, .url, .numeric] {
            traits.variant = variant
            XCTAssertNil(plan("teh"), "\(variant)")
            XCTAssertNil(plan("dont"), "\(variant)")
        }
    }

    func testSecureAndAutocorrectOffFieldsAreNeverCorrected() {
        traits.isSecure = true
        XCTAssertNil(plan("teh"))
        traits.isSecure = false
        traits.suggestionsDisabled = true
        XCTAssertNil(plan("teh"))
    }

    // C13
    func testTheSettingOffMeansNoCorrectionAndNoChecker() {
        enabled = false
        XCTAssertNil(plan("teh"))
        XCTAssertNil(plan("dont"))
        corrector.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        XCTAssertNil(plan("omw"))
        XCTAssertTrue(checker.calls.isEmpty)
    }

    // C14
    func testALanguageWithoutADictionaryIsNeverCorrected() {
        languages = ["xx-XX"]
        XCTAssertNil(plan("teh"))
    }

    func testALanguageThatIsNotEnglishIsNeverSpellCorrected() {
        languages = ["fr-FR"]
        XCTAssertNil(plan("teh"), "the rule was only measured on English")
    }

    // C15: Full Access off means no lexicon at all; the spell path does not depend on it.
    func testAnEmptyLexiconStillCorrects() {
        corrector.setLexicon([])
        XCTAssertNotNil(plan("teh"))
    }
}
