import XCTest
@testable import KeyboardTypingKit

/// Rewrites the document inside the handler call: the world changing between the event and the edit.
@MainActor
private final class MutatingHandler: TypingWordCompletionHandling {
    let inner: TypingWordCompletionHandling
    let mutate: @MainActor () -> Void
    init(inner: TypingWordCompletionHandling, mutate: @escaping @MainActor () -> Void) {
        self.inner = inner
        self.mutate = mutate
    }
    func wordCompleted(_ event: TypingWordCompletedEvent) -> TypingEditPlan? {
        let plan = inner.wordCompleted(event)
        mutate()
        return plan
    }
    func replacementWasRejected(_ undo: TypingReplacementUndo) { inner.replacementWasRejected(undo) }
}

/// Matrix rows E1-E40: autocorrect through the real engine and the real autocorrector, with a fake checker.
@MainActor
final class TypingEngineAutocorrectTests: XCTestCase {
    private var document = FakeDocument()
    private var source = FakeSuggestionSource()
    private var checker = FakeSpellChecker()
    private var enabled = true
    private var corrector: TypingAutocorrector!
    private var engine: TypingEngine!

    override func setUp() async throws {
        document = FakeDocument()
        source = FakeSuggestionSource()
        checker = FakeSpellChecker()
        enabled = true
        checker.misspelled = ["teh", "adn", "recieve", "wich", "Teh"]
        checker.guessTable = ["teh": ["the"], "adn": ["and"], "recieve": ["receive"], "wich": ["which"], "Teh": ["the"]]
        engine = TypingEngine(document: document, suggestionSource: source, now: { 0 })
        corrector = TypingAutocorrector(
            checker: { [unowned self] in self.checker },
            languageCandidates: { ["en-US"] },
            traits: { [unowned self] in self.engine.state.traits },
            isEnabled: { [unowned self] in self.enabled }
        )
        engine.completionHandler = corrector
    }

    private func typeWord(_ text: String) { text.forEach { engine.type(String($0)) } }
    private func correct(_ word: String, then boundary: () -> Void) { typeWord(word); boundary() }

    // E1
    func testSpaceCorrectsTheWord() {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "the ")
    }

    // E2
    func testEachSentenceMarkCorrectsTheWordBeforeIt() {
        for mark in [".", ",", "!", "?", ";", ":"] {
            document.before = ""
            engine.documentDidChange()
            typeWord("teh")
            engine.type(mark)
            XCTAssertEqual(document.before, "the" + mark, mark)
        }
    }

    // E3
    func testReturnCorrectsTheWord() {
        typeWord("teh")
        engine.tapReturn()
        XCTAssertEqual(document.before, "the\n")
    }

    // E4
    func testAWordAfterANewlineIsCorrected() {
        document.before = "hello\n"
        engine.documentDidChange()
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "hello\nthe ")
    }

    func testACapitalAtTheStartOfASentenceIsKept() {
        typeWord("Teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "The ")
    }

    // E5
    func testBackspaceRightAfterACorrectionPutsBackTheWordAndTheSpace() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh ")
    }

    // E6
    func testUndoRestoresThePunctuationTheUserTyped() {
        typeWord("teh")
        engine.type(",")
        XCTAssertEqual(document.before, "the,")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh,")
    }

    func testUndoRestoresTheLineBreak() {
        typeWord("teh")
        engine.tapReturn()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh\n")
    }

    func testTheSecondBackspaceIsAnOrdinaryBackspace() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapBackspace()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh")
    }

    // E7
    func testTypingAnotherCharacterMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        engine.type("x")
        engine.tapBackspace()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the", "plain backspaces: x, then the space; never a restore of \"teh\"")
    }

    func testTypingASpaceMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapSpace()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the ")
    }

    // E8
    func testMovingTheCursorAwayMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        document.before = "somewhere else"
        document.after = "the end"
        engine.documentDidChange()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "somewhere els")
    }

    func testMovingTheCursorBeforeTheSpaceMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        document.before = "the"
        document.after = " "
        engine.documentDidChange()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "th")
    }

    func testTheCursorMovingToTheSameTextWithDifferentTextAfterItMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        document.after = "more text"
        engine.documentDidChange()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the")
    }

    // E9
    func testSwitchingPageMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        engine.switchPage(.numbers)
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the")
    }

    // E10
    func testAnotherFieldMakesBackspaceOrdinary() {
        typeWord("teh")
        engine.tapSpace()
        document.documentIdentifier = UUID()
        document.before = "the "
        engine.documentDidChange()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the")
    }

    // E11: the host echoes every keystroke back; that must not cost the user their undo.
    func testTheHostEchoingTheSameTextKeepsTheUndo() {
        typeWord("teh")
        engine.tapSpace()
        engine.documentDidChange()
        engine.documentDidChange()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh ")
    }

    // E12
    func testARejectedWordIsNotCorrectedAgain() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapBackspace()
        engine.tapBackspace()
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh teh ", "the same word, later in the text")
    }

    func testOtherWordsAreStillCorrectedAfterARejection() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapBackspace()
        typeWord("adn")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh and ")
    }

    // E13
    func testTheStripOffersTheOriginalWordFirstRightAfterACorrection() {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(engine.state.suggestions.first, TypingSuggestion(text: "teh", kind: .original))
    }

    // E14
    func testTappingTheOriginalInTheStripRestoresTheWordAndTheSpace() throws {
        typeWord("teh")
        engine.tapSpace()
        let original = try XCTUnwrap(engine.state.suggestions.first)
        XCTAssertTrue(engine.accept(original))
        XCTAssertEqual(document.before, "teh ")
        XCTAssertTrue(engine.state.suggestions.allSatisfy { $0.kind != .original })
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh teh ", "tapping the original is a rejection too")
    }

    func testTappingTheOriginalRestoresPunctuationToo() throws {
        typeWord("teh")
        engine.type("!")
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "teh!")
    }

    // E15
    func testTheOriginalLeavesTheStripWhenTheUserTypesOn() {
        typeWord("teh")
        engine.tapSpace()
        engine.type("a")
        XCTAssertTrue(engine.state.suggestions.allSatisfy { $0.kind != .original })
    }

    func testTheOriginalLeavesTheStripWhenTheCursorMoves() {
        typeWord("teh")
        engine.tapSpace()
        document.before = "elsewhere"
        engine.documentDidChange()
        XCTAssertTrue(engine.state.suggestions.allSatisfy { $0.kind != .original })
    }

    // E16
    func testATapOnTheOriginalAfterTheDocumentChangedEditsNothing() throws {
        typeWord("teh")
        engine.tapSpace()
        let original = try XCTUnwrap(engine.state.suggestions.first)
        document.before = "something else entirely"
        XCTAssertFalse(engine.accept(original))
        XCTAssertEqual(document.before, "something else entirely")
    }

    // E17
    func testAPlanIsDroppedWhenTheDocumentChangesBetweenTheEventAndTheEdit() {
        engine.completionHandler = MutatingHandler(inner: corrector) { [unowned self] in self.document.before += "x" }
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "tehx ")
    }

    // E18
    func testASelectionMeansNothingIsCorrected() {
        typeWord("teh")
        document.selection = "teh"
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    func testBackspaceWithASelectionDeletesTheSelectionNotTheCorrection() {
        typeWord("teh")
        engine.tapSpace()
        document.selection = "the"
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the ", "the host deleted the selection; nothing was restored")
        XCTAssertNil(document.selection)
    }

    // E19
    func testNoCorrectionInTheMiddleOfAWord() {
        document.before = "teh"
        document.after = "world"
        engine.documentDidChange()
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    // E20
    func testTwoCompletionsInARowAreBothCorrectedAndOnlyTheLastCanBeUndone() {
        typeWord("teh")
        engine.tapSpace()
        typeWord("adn")
        engine.tapSpace()
        XCTAssertEqual(document.before, "the and ")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the adn ")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the adn")
    }

    func testTwoCorrectionsInARowWithNoHostEchoBetween() {
        for _ in 0..<3 {
            typeWord("teh")
            engine.tapSpace()
        }
        XCTAssertEqual(document.before, "the the the ")
    }

    // E21: the proxy had not caught up with the last keystroke when the space arrived.
    func testALaggingProxyNeverCorrectsAHalfSeenWord() {
        typeWord("teh")
        document.staleBefore = "te"
        engine.tapSpace()
        document.staleBefore = nil
        XCTAssertEqual(document.before, "teh ", "\"te\" is not what was typed; leave it")
    }

    func testALaggingProxyShowingTheWordBeforeItIsAlsoLeftAlone() {
        document.before = "I think "
        engine.documentDidChange()
        typeWord("adn")
        document.staleBefore = "I think "
        engine.tapSpace()
        document.staleBefore = nil
        XCTAssertEqual(document.before, "I think adn ")
    }

    // E22: dictation and rewrites.
    func testDictatedTextIsNeverCorrected() {
        document.before = "I think teh recieve"
        engine.noteExternalInsertion()
        engine.tapSpace()
        XCTAssertEqual(document.before, "I think teh recieve ")
    }

    func testDictatedTextIsNeverCorrectedEvenWithoutTheHook() {
        document.before = "recieve"
        engine.documentDidChange()
        engine.tapSpace()
        XCTAssertEqual(document.before, "recieve ", "a word the user did not type here")
    }

    func testTypingAfterADictationIsCorrectedAgain() {
        document.before = "recieve "
        engine.noteExternalInsertion()
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "recieve the ")
    }

    func testADictationRetiresAPendingUndo() {
        typeWord("teh")
        engine.tapSpace()
        document.before += "dictated text"
        engine.noteExternalInsertion()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the dictated tex")
    }

    func testAnExistingWordTheCursorWasPlacedAfterIsNotCorrected() {
        document.before = "I wrote teh"
        engine.documentDidChange()
        engine.tapSpace()
        XCTAssertEqual(document.before, "I wrote teh ")
    }

    // E23
    func testNothingIsCorrectedWhileADictationRuns() {
        engine.setSuggestionsSuspended(true)
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    func testStartingADictationRetiresAPendingUndo() {
        typeWord("teh")
        engine.tapSpace()
        engine.setSuggestionsSuspended(true)
        engine.setSuggestionsSuspended(false)
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the")
    }

    // E23b: a single quote used as an opening quote is not part of the word.
    func testAWordAfterAnOpeningSingleQuoteIsCorrected() {
        document.before = "he said "
        engine.documentDidChange()
        engine.type("'")
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "he said 'the ")
    }

    // E24
    func testAnEmojiGluedToTheWordMeansNoCorrection() {
        engine.type("\u{1F600}")
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "\u{1F600}teh ")
    }

    func testAnEmojiAfterTheWordIsNotATrigger() {
        typeWord("teh")
        engine.type("\u{1F600}")
        XCTAssertEqual(document.before, "teh\u{1F600}")
    }

    // E25
    func testAVeryLongWordIsLeftAlone() {
        let long = String(repeating: "a", count: 60)
        typeWord(long)
        engine.tapSpace()
        XCTAssertEqual(document.before, long + " ")
        XCTAssertTrue(checker.calls.isEmpty)
    }

    // E26
    func testAnApostropheWordIsLeftAloneAndAMissingOneIsAdded() {
        typeWord("don't")
        engine.tapSpace()
        XCTAssertEqual(document.before, "don't ")
        typeWord("dont")
        engine.tapSpace()
        XCTAssertEqual(document.before, "don't don't ")
    }

    func testAHyphenWordIsLeftAlone() {
        checker.misspelled.insert("well-knwn")
        typeWord("well-knwn")
        engine.tapSpace()
        XCTAssertEqual(document.before, "well-knwn ")
    }

    // E27
    func testATextReplacementExpandsOnSpaceAndCanBeUndone() {
        corrector.setLexicon([TypingLexiconEntry(userInput: "omw", documentText: "On my way!")])
        typeWord("omw")
        engine.tapSpace()
        XCTAssertEqual(document.before, "On my way! ")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "omw ")
        engine.tapBackspace()
        engine.tapSpace()
        XCTAssertEqual(document.before, "omw ", "rejected, so it stays")
    }

    // E28
    func testTheSettingOffMeansNoCorrection() {
        enabled = false
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    func testTheSettingTurnedOnLaterTakesEffectOnTheNextWord() {
        enabled = false
        typeWord("teh")
        engine.tapSpace()
        enabled = true
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh the ")
    }

    // E29
    func testASecureFieldIsNeverCorrected() {
        var traits = TypingTraits()
        traits.isSecure = true
        engine.apply(traits: traits)
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    func testAnEmailFieldIsNeverCorrected() {
        var traits = TypingTraits()
        traits.variant = .email
        engine.apply(traits: traits)
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    // E30
    func testBackspaceHeldAfterACorrectionDeletesOneCharacterEachAfterTheUndo() {
        typeWord("teh")
        engine.tapSpace()
        for _ in 0..<4 { engine.tapBackspace() }
        XCTAssertEqual(document.before, "t", "the undo restores \"teh \" in one tap; three more delete \" \", \"h\", \"e\"")
    }

    func testAnUndoneCorrectionLeavesTheShiftStateAlone() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapBackspace()
        XCTAssertEqual(engine.state.shift, .off)
    }
}
