import XCTest
@testable import KeyboardTypingKit

@MainActor
private final class RecordingHandler: TypingWordCompletionHandling {
    private(set) var rejected: [TypingReplacementUndo] = []
    func wordCompleted(_ event: TypingWordCompletedEvent) -> TypingEditPlan? { nil }
    func replacementWasRejected(_ undo: TypingReplacementUndo) { rejected.append(undo) }
}

/// Matrix rows J1-J24: what the strip offers for the word the user just finished, once the cursor is past its
/// space, punctuation or line break.
@MainActor
final class TypingJustCompletedWordTests: XCTestCase {
    private var document = FakeDocument()
    private var source = FakeSuggestionSource()
    private var handler = RecordingHandler()
    private var engine: TypingEngine!

    override func setUp() async throws {
        document = FakeDocument()
        source = FakeSuggestionSource()
        handler = RecordingHandler()
        source.completedTable = [
            "teh": [fix("the"), fix("tech"), fix("ten")],
            "Teh": [fix("The")],
            "Samuel": [fix("Samuels")],
            "dont": [fix("don't")],
        ]
        engine = TypingEngine(document: document, suggestionSource: source, now: { 0 })
        engine.completionHandler = handler
    }

    private func fix(_ text: String) -> TypingSuggestion { TypingSuggestion(text: text, kind: .correction) }
    private func typeWord(_ text: String) { text.forEach { engine.type(String($0)) } }
    private func texts() -> [String] { engine.state.suggestions.map(\.text) }

    // J1: after a space
    func testAfterASpaceTheStripOffersAlternativesForTheWordJustFinished() {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(texts(), ["the", "tech", "ten"])
        XCTAssertEqual(Set(engine.state.suggestions.map(\.kind)), [.correction])
    }

    // J2: after punctuation
    func testAfterPunctuationTheStripOffersAlternativesForTheWordBeforeIt() {
        typeWord("teh")
        engine.type(".")
        XCTAssertEqual(texts(), ["the", "tech", "ten"])
    }

    // J3: after a line break
    func testAfterAReturnTheStripOffersAlternativesForTheWordBeforeIt() {
        typeWord("teh")
        engine.tapReturn()
        XCTAssertEqual(texts(), ["the", "tech", "ten"])
    }

    // J4: a correct word has nothing to offer
    func testAWordThatIsAlreadyCorrectLeavesTheStripEmpty() {
        typeWord("hello")
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
        XCTAssertEqual(source.completedRequested, ["hello"], "the source decides what is correct")
    }

    // J5: apostrophes
    func testAWordWithoutItsApostropheIsAskedAboutAndOneWithAnApostropheIsTooAndTheSourceDecides() {
        typeWord("dont")
        engine.tapSpace()
        XCTAssertEqual(texts(), ["don't"])
        typeWord("don't")
        engine.tapSpace()
        XCTAssertEqual(source.completedRequested.last, "don't")
    }

    // J6: cursor moved
    func testMovingTheCursorElsewhereClearsTheAlternatives() {
        typeWord("teh")
        engine.tapSpace()
        document.before = "something else entirely"
        engine.documentDidChange()
        XCTAssertEqual(texts(), [])
    }

    // J6b: placing the cursor after an old word offers nothing, only a word finished here does
    func testAnExistingWordTheCursorWasPlacedAfterGetsNoAlternatives() {
        document.before = "teh "
        engine.documentDidChange()
        XCTAssertEqual(texts(), [])
        XCTAssertTrue(source.completedRequested.isEmpty)
    }

    // J7: field changed
    func testAnotherFieldClearsTheAlternativesAndTheirTap() throws {
        typeWord("teh")
        engine.tapSpace()
        let first = try XCTUnwrap(engine.state.suggestions.first)
        document.documentIdentifier = UUID()
        document.before = "teh "
        engine.documentDidChange()
        XCTAssertEqual(texts(), [])
        XCTAssertFalse(engine.accept(first))
        XCTAssertEqual(document.before, "teh ")
    }

    // J8: stale suggestion
    func testATapAfterTheDocumentChangedEditsNothing() throws {
        typeWord("teh")
        engine.tapSpace()
        let first = try XCTUnwrap(engine.state.suggestions.first)
        document.before = "teh x"
        XCTAssertFalse(engine.accept(first))
        XCTAssertEqual(document.before, "teh x")
    }

    // J9: a host that never gives a document identifier
    func testAHostWithNoDocumentIdentifierStillGetsAlternativesAndTheirTap() throws {
        document.documentIdentifier = nil
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(texts(), ["the", "tech", "ten"])
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "the ")
    }

    // J10: empty context
    func testAnEmptyFieldHasNoAlternatives() {
        engine.documentDidChange()
        XCTAssertEqual(texts(), [])
        document.before = ""
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
        XCTAssertTrue(source.completedRequested.isEmpty)
    }

    // J11: a tap replaces the word and keeps the boundary
    func testTappingAnAlternativeReplacesTheWordAndKeepsTheSpace() throws {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "the ")
    }

    func testTappingAnAlternativeKeepsPunctuationAndLineBreaks() throws {
        typeWord("teh")
        engine.type(",")
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "the,")
        document.before = ""
        engine.documentDidChange()
        typeWord("teh")
        engine.tapReturn()
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "the\n")
    }

    // J12: the same undo as autocorrect
    func testBackspaceAfterATapPutsTheOriginalWordAndBoundaryBack() throws {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh ")
        XCTAssertEqual(handler.rejected.map(\.originalWord), ["teh"])
    }

    func testAfterATapTheStripOffersTheOriginalInQuotes() throws {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(engine.state.suggestions, [TypingSuggestion(text: "teh", kind: .original)])
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "teh ")
    }

    // J12b: taking a replacement back is a rejection; the strip does not offer alternatives for the word again
    func testAfterTakingAReplacementBackTheStripStaysEmpty() throws {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertTrue(engine.accept(try XCTUnwrap(engine.state.suggestions.first)))
        XCTAssertEqual(document.before, "teh ")
        XCTAssertEqual(texts(), [])
    }

    // J13: the next keystroke changes the context
    func testTypingOnClearsTheAlternatives() {
        typeWord("teh")
        engine.tapSpace()
        engine.type("a")
        XCTAssertEqual(source.requested.last, "a")
        XCTAssertFalse(texts().contains("the"))
    }

    func testBackspacingTheBoundaryGoesBackToThePartialWord() {
        typeWord("teh")
        engine.tapSpace()
        engine.tapBackspace()
        XCTAssertEqual(source.requested.last, "teh")
        XCTAssertFalse(texts().contains("tech"))
    }

    func testTwoBoundariesInARowOfferNothing() {
        typeWord("teh")
        engine.type(".")
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
    }

    // J14: text Muesli inserted
    func testDictatedTextGetsNoAlternatives() {
        typeWord("teh")
        engine.tapSpace()
        document.insert("teh ")
        engine.noteExternalInsertion()
        XCTAssertEqual(texts(), [])
    }

    // J15: a running dictation owns the strip
    func testNoAlternativesWhileADictationRuns() throws {
        typeWord("teh")
        engine.tapSpace()
        let first = try XCTUnwrap(engine.state.suggestions.first)
        engine.setSuggestionsSuspended(true)
        XCTAssertEqual(texts(), [])
        XCTAssertFalse(engine.accept(first))
        XCTAssertEqual(document.before, "teh ")
    }

    // J16: a name in the middle of a sentence is not flagged; the first word of one is
    func testACapitalizedWordInTheMiddleOfASentenceIsAssumedToBeAName() {
        typeWord("hi")
        engine.tapSpace()
        engine.type("S")
        typeWord("amuel")
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
    }

    func testACapitalizedFirstWordOfASentenceGetsAlternatives() {
        typeWord("Teh")
        engine.tapSpace()
        XCTAssertEqual(texts(), ["The"])
    }

    // J17: words the strip never judges
    func testWordsWithDigitsOrHyphensOrTooLongAreNeverAskedAbout() {
        typeWord("abc123")
        engine.tapSpace()
        typeWord("well-known")
        engine.tapSpace()
        typeWord(String(repeating: "a", count: 40))
        engine.tapSpace()
        XCTAssertTrue(source.completedRequested.isEmpty)
    }

    // J18: glued to a handle, hashtag or address
    func testAWordGluedToAHashtagOrAddressGetsNoAlternatives() {
        typeWord("#teh")
        engine.tapSpace()
        typeWord("sam@teh")
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
    }

    // J19: autocorrect declined, so the word is still wrong and the strip helps
    func testWhenAutocorrectLeavesAWordAloneTheStripOffersAlternatives() {
        // The handler returns no plan: the word stays as typed.
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
        XCTAssertEqual(texts().first, "the")
    }

    // J20: secure and autocorrect-off fields
    func testSecureAndSuggestionsOffFieldsGetNoAlternatives() {
        var traits = TypingTraits()
        traits.isSecure = true
        engine.apply(traits: traits)
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
        traits.isSecure = false
        traits.suggestionsDisabled = true
        engine.apply(traits: traits)
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(texts(), [])
        XCTAssertTrue(source.completedRequested.isEmpty)
    }

    // J21: a selection
    func testASelectionHasNoAlternatives() {
        typeWord("teh")
        document.selection = "e"
        engine.tapSpace()
        document.selection = "e"
        engine.documentDidChange()
        XCTAssertEqual(texts(), [])
    }
}

final class TypingSuggestibleShapeTests: XCTestCase {
    func testLettersAndInnerApostrophesAreSuggestible() {
        for word in ["teh", "dont", "don't", "Teh", "I", "it\u{2019}s"] {
            XCTAssertTrue(TypingTokenContext.isSuggestibleShape(word), word)
        }
    }

    func testDigitsHyphensEmptyAndLongWordsAreNot() {
        for word in ["", "abc123", "well-known", "a_b", "'", String(repeating: "a", count: 25)] {
            XCTAssertFalse(TypingTokenContext.isSuggestibleShape(word), word)
        }
    }
}
