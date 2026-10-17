import XCTest
@testable import KeyboardTypingKit

/// A host text field: text before and after the cursor, an optional selection, and the proxy's habit of
/// returning nil for an empty side.
@MainActor
final class FakeDocument: TypingDocument {
    var before = ""
    var after = ""
    var selection: String?
    var documentIdentifier: UUID? = UUID()
    private(set) var beforeReads = 0
    private(set) var afterReads = 0
    private(set) var deleteCalls = 0
    private(set) var inserted: [String] = []

    var selectedText: String? { selection }
    /// What the proxy reports while it lags behind the keystrokes it was just given.
    var staleBefore: String?
    var contextBefore: String? {
        beforeReads += 1
        let shown = staleBefore ?? before
        return shown.isEmpty ? nil : shown
    }
    var contextAfter: String? { afterReads += 1; return after.isEmpty ? nil : after }

    func insert(_ text: String) {
        inserted.append(text)
        selection = nil
        before += text
    }

    func deleteBackward() {
        deleteCalls += 1
        if selection != nil { selection = nil; return }
        if !before.isEmpty { before.removeLast() }
    }
}

@MainActor
final class FakeSuggestionSource: TypingSuggestionSource {
    var table: [String: [TypingSuggestion]] = [:]
    private(set) var requested: [String] = []
    private(set) var documentChanges = 0
    /// Alternatives for a just-finished word, by the word.
    var completedTable: [String: [TypingSuggestion]] = [:]
    private(set) var completedRequested: [String] = []

    func suggestions(forPartial partial: String) -> [TypingSuggestion] {
        requested.append(partial)
        return table[partial] ?? []
    }

    func corrections(forCompletedWord word: String) -> [TypingSuggestion] {
        completedRequested.append(word)
        return completedTable[word] ?? []
    }

    func documentDidChange() { documentChanges += 1 }
}

@MainActor
final class FakeCompletionHandler: TypingWordCompletionHandling {
    var events: [TypingWordCompletedEvent] = []
    var plan: TypingEditPlan?

    func wordCompleted(_ event: TypingWordCompletedEvent) -> TypingEditPlan? {
        events.append(event)
        return plan
    }
}

/// Matrix rows Y1-Y24: the engine that turns key taps into document edits, shift changes and suggestions.
@MainActor
final class TypingEngineTests: XCTestCase {
    private var document = FakeDocument()
    private var source = FakeSuggestionSource()
    private var clock = 0.0
    private var engine: TypingEngine!

    override func setUp() async throws {
        document = FakeDocument()
        source = FakeSuggestionSource()
        clock = 0
        engine = TypingEngine(document: document, suggestionSource: source, now: { [unowned self] in self.clock })
    }

    private func typeWord(_ text: String) { text.forEach { engine.type(String($0)) } }

    /// The user is at the end of `text` and the strip has been computed for it.
    private func prime(_ text: String, after: String = "", suggestions: [String: [TypingSuggestion]] = [:]) {
        document.before = text
        document.after = after
        for (partial, list) in suggestions { source.table[partial] = list }
        engine.documentDidChange()
    }
    private func suggestion(_ text: String, kind: TypingSuggestion.Kind = .completion) -> TypingSuggestion {
        TypingSuggestion(text: text, kind: kind)
    }

    // MARK: Typing, shift and auto-capitalize

    // Y3: an empty field starts in shift, so the first letter is a capital.
    func testTheFirstLetterInAnEmptyFieldIsCapitalized() {
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .once)
        XCTAssertTrue(engine.state.isUppercase)
        engine.type("H")
        engine.type("i")
        XCTAssertEqual(document.before, "Hi")
        XCTAssertEqual(engine.state.shift, .off)
    }

    // Y4
    func testTheLetterAfterASentenceEndIsCapitalized() {
        document.before = "Hello"
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .off)
        engine.type(".")
        engine.tapSpace()
        XCTAssertEqual(document.before, "Hello. ")
        XCTAssertEqual(engine.state.shift, .once)
    }

    // Y1
    func testAShiftTapCapitalizesOneLetter() {
        document.before = "hi "
        engine.documentDidChange()
        engine.tapShift()
        XCTAssertTrue(engine.state.isUppercase)
        engine.type("T")
        XCTAssertEqual(engine.state.shift, .off)
        engine.type("o")
        XCTAssertEqual(document.before, "hi To")
    }

    // Y2
    func testCapsLockSurvivesTyping() {
        document.before = "hi "
        engine.documentDidChange()
        engine.tapShift()
        clock = 0.1
        engine.tapShift()
        XCTAssertEqual(engine.state.shift, .locked)
        typeWord("AB")
        XCTAssertEqual(engine.state.shift, .locked)
        XCTAssertTrue(engine.state.isUppercase)
    }

    // S9 through the engine: cancelling an automatic shift must not re-arm until the text changes.
    func testCancellingAutoShiftSticksUntilTheTextChanges() {
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .once)
        engine.tapShift()
        XCTAssertEqual(engine.state.shift, .off)
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .off, "same context, the cancel stands")
        document.before = "Done. "
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .once)
    }

    func testTheHostEchoingTheSameTraitsDoesNotRearmACancelledShift() {
        let traits = TypingTraits()
        engine.apply(traits: traits)
        XCTAssertEqual(engine.state.shift, .once)
        engine.tapShift()
        engine.apply(traits: traits)
        XCTAssertEqual(engine.state.shift, .off)
    }

    func testTheHostEchoingTheSameTraitsDoesNotResetThePage() {
        let traits = TypingTraits()
        engine.apply(traits: traits)
        engine.switchPage(.numbers)
        engine.apply(traits: traits)
        XCTAssertEqual(engine.state.page, .numbers)
    }

    // S13 through the engine: the host moved the cursor away from a sentence start.
    func testAnAutomaticShiftIsDroppedWhenTheHostMovesTheCursorMidSentence() {
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .once)
        document.before = "Some text here"
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .off)
    }

    func testAllCharactersFieldsAreAlwaysUppercaseAndShiftIsInert() {
        var traits = TypingTraits()
        traits.autocapitalization = .allCharacters
        engine.apply(traits: traits)
        XCTAssertTrue(engine.state.isUppercase)
        engine.tapShift()
        XCTAssertTrue(engine.state.isUppercase)
        XCTAssertEqual(engine.state.shift, .off)
    }

    func testNoAutocapitalizationFieldsDoNotArmShift() {
        var traits = TypingTraits()
        traits.autocapitalization = .none
        engine.apply(traits: traits)
        engine.documentDidChange()
        XCTAssertEqual(engine.state.shift, .off)
    }

    // S14
    func testComingBackToLettersReevaluatesAutoCapitalize() {
        engine.documentDidChange()
        engine.switchPage(.numbers)
        engine.type("1")
        XCTAssertEqual(engine.state.shift, .off)
        document.before = ""
        engine.switchPage(.letters)
        XCTAssertEqual(engine.state.shift, .once)
        XCTAssertEqual(engine.state.page, .letters)
    }

    // MARK: Backspace

    // Y8
    func testBackspaceAtTheStartOfTheFieldIsHarmless() {
        engine.tapBackspace()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "")
        XCTAssertEqual(document.deleteCalls, 2, "an unreadable host must still get its backspace")
        XCTAssertEqual(engine.state.shift, .once)
    }

    func testBackspaceWithASelectionDeletesTheSelectionOnly() {
        document.before = "Hello "
        document.selection = "world"
        engine.tapBackspace()
        XCTAssertNil(document.selection)
        XCTAssertEqual(document.before, "Hello ", "one backspace removes the selection and nothing more")
        XCTAssertEqual(document.deleteCalls, 1)
    }

    func testBackspaceRefreshesTheSuggestions() {
        source.table["hel"] = [suggestion("hello")]
        document.before = "helo"
        engine.tapBackspace()
        XCTAssertEqual(document.before, "hel")
        XCTAssertEqual(engine.state.suggestions, [suggestion("hello")])
    }

    // MARK: Suggestions

    func testTypingAWordShowsItsSuggestions() {
        source.table["hel"] = [suggestion("hello"), suggestion("help")]
        typeWord("hel")
        XCTAssertEqual(engine.state.suggestions.map(\.text), ["hello", "help"])
    }

    // Y2b: after a space there is no word, so the strip empties.
    func testASpaceClearsTheSuggestions() {
        source.table["hel"] = [suggestion("hello")]
        typeWord("hel")
        engine.tapSpace()
        XCTAssertEqual(engine.state.suggestions, [])
    }

    // W3 through the engine
    func testNoSuggestionsInTheMiddleOfAWord() {
        source.table["hel"] = [suggestion("hello")]
        document.before = "hel"
        document.after = "lo"
        engine.documentDidChange()
        XCTAssertEqual(engine.state.suggestions, [])
        XCTAssertEqual(source.requested, [])
    }

    // Y9
    func testAcceptingASuggestionReplacesThePartialAndAddsASpace() {
        let hello = suggestion("hello")
        prime("say hel", suggestions: ["hel": [hello]])
        XCTAssertTrue(engine.accept(hello))
        XCTAssertEqual(document.before, "say hello ")
        XCTAssertEqual(engine.state.suggestions, [])
    }

    // Y10: the text changed after the suggestion was computed.
    func testAStaleSuggestionDoesNotEditTheDocument() {
        let hello = suggestion("hello")
        prime("say hel", suggestions: ["hel": [hello]])
        document.before = "say help"
        XCTAssertFalse(engine.accept(hello))
        XCTAssertEqual(document.before, "say help")
        XCTAssertEqual(document.deleteCalls, 0)
        XCTAssertTrue(document.inserted.isEmpty)
    }

    // Y11
    func testASuggestionFromAnotherDocumentDoesNotEdit() {
        let hello = suggestion("hello")
        prime("say hel", suggestions: ["hel": [hello]])
        document.documentIdentifier = UUID()
        XCTAssertFalse(engine.accept(hello))
        XCTAssertEqual(document.before, "say hel")
    }

    func testAMissingDocumentIdentifierOnBothSidesStillWorks() {
        document.documentIdentifier = nil
        let hello = suggestion("hello")
        prime("say hel", suggestions: ["hel": [hello]])
        XCTAssertTrue(engine.accept(hello))
        XCTAssertEqual(document.before, "say hello ")
    }

    // Y12
    func testAcceptingTheWordAlreadyTypedOnlyAddsASpace() {
        let verbatim = suggestion("hello", kind: .verbatim)
        prime("say hello", suggestions: ["hello": [verbatim]])
        XCTAssertTrue(engine.accept(verbatim))
        XCTAssertEqual(document.before, "say hello ")
        XCTAssertEqual(document.deleteCalls, 0)
    }

    func testAcceptingASuggestionBeforeExistingPunctuationAddsNoSpace() {
        let hello = suggestion("hello")
        prime("say hel", after: ", ok", suggestions: ["hel": [hello]])
        XCTAssertTrue(engine.accept(hello))
        XCTAssertEqual(document.before, "say hello")
    }

    func testAcceptingAMultiWordTextReplacement() {
        let phrase = suggestion("On my way!", kind: .lexicon)
        prime("omw", suggestions: ["omw": [phrase]])
        XCTAssertTrue(engine.accept(phrase))
        XCTAssertEqual(document.before, "On my way! ")
    }

    // Y15: while dictation owns the strip, no suggestion is computed or tappable.
    func testSuggestionsAreSuspendedWhileDictating() {
        source.table["hel"] = [suggestion("hello")]
        typeWord("hel")
        XCTAssertFalse(engine.state.suggestions.isEmpty)
        engine.setSuggestionsSuspended(true)
        XCTAssertEqual(engine.state.suggestions, [])
        let requests = source.requested.count
        engine.documentDidChange()
        XCTAssertEqual(source.requested.count, requests)
        engine.setSuggestionsSuspended(false)
        XCTAssertEqual(engine.state.suggestions, [suggestion("hello")])
    }

    func testAcceptingWhileSuspendedDoesNothing() {
        let hello = suggestion("hello")
        prime("say hel", suggestions: ["hel": [hello]])
        engine.setSuggestionsSuspended(true)
        XCTAssertFalse(engine.accept(hello))
        XCTAssertEqual(document.before, "say hel")
    }

    // Y13/Y14: secure fields are never read.
    func testASecureFieldIsNeverReadForSuggestions() {
        var traits = TypingTraits()
        traits.isSecure = true
        engine.apply(traits: traits)
        document.before = "hunter2"
        document.after = "x"
        let reads = document.beforeReads
        engine.documentDidChange()
        typeWord("ab")
        XCTAssertEqual(engine.state.suggestions, [])
        XCTAssertEqual(source.requested, [])
        XCTAssertEqual(document.beforeReads, reads)
        XCTAssertEqual(document.afterReads, 0)
    }

    func testTraitsArrivingLateClearTheStripAndStopReading() {
        source.table["hel"] = [suggestion("hello")]
        typeWord("hel")
        XCTAssertFalse(engine.state.suggestions.isEmpty)
        var traits = TypingTraits()
        traits.isSecure = true
        engine.apply(traits: traits)
        XCTAssertEqual(engine.state.suggestions, [])
        XCTAssertFalse(engine.accept(suggestion("hello")))
    }

    func testAutocorrectOffFieldsGetNoSuggestions() {
        var traits = TypingTraits()
        traits.suggestionsDisabled = true
        engine.apply(traits: traits)
        source.table["hel"] = [suggestion("hello")]
        typeWord("hel")
        XCTAssertEqual(engine.state.suggestions, [])
    }

    func testANewDocumentResetsTheSuggestionSource() {
        engine.documentDidChange()
        XCTAssertEqual(source.documentChanges, 0)
        document.documentIdentifier = UUID()
        engine.documentDidChange()
        XCTAssertEqual(source.documentChanges, 1)
        engine.documentDidChange()
        XCTAssertEqual(source.documentChanges, 1)
    }

    func testTraitsApplyThePageForNumericFields() {
        var traits = TypingTraits()
        traits.variant = .numeric
        engine.apply(traits: traits)
        XCTAssertEqual(engine.state.page, .numbers)
    }

    // MARK: Return key

    func testReturnInsertsANewlineAndClearsSuggestions() {
        source.table["hel"] = [suggestion("hello")]
        typeWord("hel")
        engine.tapReturn()
        XCTAssertEqual(document.before, "hel\n")
        XCTAssertEqual(engine.state.suggestions, [])
    }

    // Y16 (advisor row)
    func testEnablesReturnKeyAutomaticallyDimsReturnOnAnEmptyField() {
        var traits = TypingTraits()
        traits.enablesReturnKeyAutomatically = true
        engine.apply(traits: traits)
        XCTAssertFalse(engine.state.isReturnEnabled)
        typeWord("a")
        XCTAssertTrue(engine.state.isReturnEnabled)
        var plain = TypingTraits()
        plain.enablesReturnKeyAutomatically = false
        engine.apply(traits: plain)
        document.before = ""
        engine.documentDidChange()
        XCTAssertTrue(engine.state.isReturnEnabled)
    }

    // MARK: Phase 2 hook: word completed

    // Y5
    func testSpaceReportsTheWordThatJustEnded() {
        let handler = FakeCompletionHandler()
        engine.completionHandler = handler
        typeWord("hello")
        engine.tapSpace()
        XCTAssertEqual(handler.events.count, 1)
        XCTAssertEqual(handler.events.first?.word, "hello")
        XCTAssertEqual(handler.events.first?.boundary, .space)
        XCTAssertEqual(handler.events.first?.contextBefore, "hello")
        XCTAssertEqual(handler.events.first?.documentIdentifier, document.documentIdentifier)
        XCTAssertEqual(document.before, "hello ")
    }

    // Y6
    func testPunctuationReportsTheWordAndNamesTheCharacter() {
        let handler = FakeCompletionHandler()
        engine.completionHandler = handler
        typeWord("hello")
        engine.type(",")
        XCTAssertEqual(handler.events.map(\.boundary), [.punctuation(",")])
        XCTAssertEqual(handler.events.first?.word, "hello")
    }

    // Y7
    func testReturnReportsTheWord() {
        let handler = FakeCompletionHandler()
        engine.completionHandler = handler
        typeWord("hello")
        engine.tapReturn()
        XCTAssertEqual(handler.events.map(\.boundary), [.returnKey])
    }

    func testLettersApostrophesAndHyphensAreNotBoundaries() {
        let handler = FakeCompletionHandler()
        engine.completionHandler = handler
        typeWord("don't-")
        XCTAssertTrue(handler.events.isEmpty)
    }

    func testNoEventWithoutAWord() {
        let handler = FakeCompletionHandler()
        engine.completionHandler = handler
        engine.tapSpace()
        engine.type(".")
        engine.tapReturn()
        XCTAssertTrue(handler.events.isEmpty)
    }

    func testNoHandlerMeansNoReplacement() {
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    // Y18: a phase 2 handler slots in with no engine change.
    func testAHandlerPlanReplacesTheWordBeforeTheBoundaryAndTheNextBackspaceUndoesIt() {
        let handler = FakeCompletionHandler()
        handler.plan = TypingEditPlan(
            deleteCount: 3, insertText: "the", expectedSuffix: "teh",
            undo: TypingReplacementUndo(replacedText: "teh ", insertedText: "the ", originalWord: "teh")
        )
        engine.completionHandler = handler
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "the ")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh ", "one backspace puts the typed word back, boundary included")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "teh", "the undo is spent after one use")
    }

    // Y19
    func testAStaleHandlerPlanIsIgnored() {
        let handler = FakeCompletionHandler()
        handler.plan = TypingEditPlan(deleteCount: 3, insertText: "the", expectedSuffix: "xyz", undo: nil)
        engine.completionHandler = handler
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh ")
    }

    func testTypingAnythingElseRetiresThePendingUndo() {
        let handler = FakeCompletionHandler()
        handler.plan = TypingEditPlan(
            deleteCount: 3, insertText: "the", expectedSuffix: "teh",
            undo: TypingReplacementUndo(replacedText: "teh ", insertedText: "the ", originalWord: "teh")
        )
        engine.completionHandler = handler
        typeWord("teh")
        engine.tapSpace()
        handler.plan = nil
        engine.type("x")
        engine.tapBackspace()
        engine.tapBackspace()
        XCTAssertEqual(document.before, "the", "plain backspaces, not a restore of \"teh\"")
    }

    // MARK: Page switching

    // Y20
    func testSwitchingPagesKeepsShiftAndSuggestionsConsistent() {
        document.before = "hi "
        engine.documentDidChange()
        engine.tapShift()
        clock = 0.1
        engine.tapShift()
        engine.switchPage(.numbers)
        XCTAssertEqual(engine.state.page, .numbers)
        XCTAssertEqual(engine.state.shift, .locked)
        engine.switchPage(.letters)
        XCTAssertEqual(engine.state.shift, .locked)
    }

    /// The Observable shell only hears `onChange`: page and trait changes must reach it, not just shift.
    func testPageAndTraitChangesAreReportedToOnChange() {
        var seen: [TypingState] = []
        engine.onChange = { seen.append($0) }
        engine.switchPage(.symbols)
        XCTAssertEqual(seen.last?.page, .symbols)
        var traits = TypingTraits()
        traits.returnKey = .send
        engine.apply(traits: traits)
        XCTAssertEqual(seen.last?.traits.returnKey, .send)
    }

    func testOnChangeFiresWithTheNewState() {
        var seen: [TypingState] = []
        engine.onChange = { seen.append($0) }
        engine.tapShift()
        XCTAssertEqual(seen.last?.shift, .once)
    }
}
