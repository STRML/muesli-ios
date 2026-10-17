import XCTest
@testable import KeyboardTypingKit

/// Rows B3 and B4 of live typing: words the dictation put in the field, marked or committed, are never read as
/// keystrokes and never corrected. Autocorrect only ever judges a word the user typed key by key, so these hold
/// without any hook in the engine; the tests keep it that way.
@MainActor
final class TypingEngineLiveDictationTests: XCTestCase {
    private var document = FakeDocument()
    private var checker = FakeSpellChecker()
    private var engine: TypingEngine!

    override func setUp() async throws {
        document = FakeDocument()
        checker = FakeSpellChecker()
        checker.misspelled = ["teh", "adn", "recieve"]
        checker.guessTable = ["teh": ["the"], "adn": ["and"], "recieve": ["receive"]]
        engine = TypingEngine(document: document, suggestionSource: FakeSuggestionSource(), now: { 0 })
        let corrector = TypingAutocorrector(
            checker: { [unowned self] in self.checker },
            languageCandidates: { ["en-US"] },
            traits: { [unowned self] in self.engine.state.traits },
            isEnabled: { true }
        )
        engine.completionHandler = corrector
    }

    private func typeWord(_ text: String) { text.forEach { engine.type(String($0)) } }

    // B3: a misspelled word in the marked text, with a space tapped right after it, is left alone.
    func testAMisspelledWordInTheMarkedTextIsNotCorrectedBySpace() {
        document.before = "Hello teh"
        engine.documentDidChange()
        engine.noteExternalInsertion()
        engine.tapSpace()
        XCTAssertEqual(document.before, "Hello teh ")
    }

    func testPunctuationAndReturnAfterMarkedTextCorrectNothing() {
        for boundary in [".", ",", "?"] {
            document.before = "Hello adn"
            engine.documentDidChange()
            engine.noteExternalInsertion()
            engine.type(boundary)
            XCTAssertEqual(document.before, "Hello adn" + boundary)
        }
        document.before = "Hello adn"
        engine.documentDidChange()
        engine.tapReturn()
        XCTAssertEqual(document.before, "Hello adn\n")
    }

    // Even without the note the engine's own check (the word must be exactly what was typed) holds.
    func testMarkedTextIsNotTypedEvenWithoutTheExternalInsertionNote() {
        document.before = "Hello recieve"
        engine.documentDidChange()
        engine.tapSpace()
        XCTAssertEqual(document.before, "Hello recieve ")
    }

    // B4: a word typed before the dictation is forgotten once words were written after it.
    func testAWordTypedBeforeTheDictationIsNotCorrectedAfterTheDictationAddedWords() {
        typeWord("teh")
        document.before += " and then"
        engine.noteExternalInsertion()
        engine.tapSpace()
        XCTAssertEqual(document.before, "teh and then ")
    }

    // The user typing a suffix onto a dictated word does not make the whole word a typed one.
    func testKeysTypedOntoADictatedWordDoNotCorrectTheWholeWord() {
        document.before = "Hello te"
        engine.documentDidChange()
        engine.noteExternalInsertion()
        engine.type("h")
        engine.tapSpace()
        XCTAssertEqual(document.before, "Hello teh ")
    }

    // A word typed after the dictation is still corrected: live typing does not switch autocorrect off.
    func testAWordTypedAfterTheDictationIsStillCorrected() {
        document.before = "Hello there. "
        engine.documentDidChange()
        engine.noteExternalInsertion()
        typeWord("teh")
        engine.tapSpace()
        XCTAssertEqual(document.before, "Hello there. the ")
    }
}
