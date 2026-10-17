import UIKit
import XCTest
@testable import Muesli

/// The finish-the-word path end to end: a typo typed key by key through the real `TypingEngine`, the real
/// `TypingAutocorrector` and the real `UITextChecker`, then the document read after the space.
@MainActor
final class AutocorrectFinishWordTests: XCTestCase {
    private var learnedCalls: [String] = []
    private var defaults: UserDefaults!

    override func setUp() async throws {
        learnedCalls = []
        defaults = UserDefaults(suiteName: "AutocorrectFinishWordTests-\(UUID().uuidString)")
    }

    /// A keyboard launch: a new checker, autocorrector and engine over the same stored words. `learnWord` is
    /// recorded, never sent to the real checker, which would change the simulator's dictionary for good.
    private func launch() -> CorpusRunner {
        CorpusRunner(
            learnedWords: TypingLearnedWordsDefaults(defaults: defaults),
            learnWord: { [unowned self] in self.learnedCalls.append($0) },
            makeChecker: { UITextCheckerAdapter() }
        )
    }

    private func typed(_ token: String, boundary: String = " ", in runner: CorpusRunner, prefix: String = "I think ") -> String {
        runner.run(prefix: prefix, token: token, boundary: boundary)
    }

    // F1: the typo classes, one real example each.
    func testATypoIsFixedWhenTheWordIsFinishedWithASpace() {
        let runner = launch()
        let cases: [(String, String)] = [
            ("teh", "the "), ("thier", "their "), ("recieve", "receive "), ("tomorow", "tomorrow "),
            ("definately", "definitely "), ("adn", "and "), ("dont", "don't "), ("im", "I'm "), ("i", "I "),
        ]
        for (typo, fixed) in cases {
            XCTAssertEqual(typed(typo, in: runner), fixed, typo)
        }
    }

    // F2: every sentence mark fixes the word before it and keeps the mark.
    func testASentenceMarkFixesTheWordBeforeIt() {
        let runner = launch()
        for mark in [",", "!", "?", ";"] {
            XCTAssertEqual(typed("recieve", boundary: mark, in: runner), "receive" + mark, mark)
        }
    }

    // F3: a name, a brand and a technical word are left alone.
    func testNamesBrandsAndTechnicalWordsAreLeftAlone() {
        let runner = launch()
        for word in ["Anthropic", "kubectl", "oauth", "github", "muesli", "form", "trail"] {
            XCTAssertEqual(typed(word, in: runner), word + " ", word)
        }
    }

    // F4: the user takes a fix back, and the keyboard is relaunched. The word stays as typed.
    func testATakenBackWordIsNotCorrectedAfterARelaunch() {
        let first = launch()
        XCTAssertEqual(typed("recieve", in: first), "receive ")
        let document = CorpusDocument()
        document.before = "I think "
        let engine = TypingEngine(document: document, suggestionSource: first.builder, now: { 0 })
        engine.completionHandler = first.autocorrector
        engine.documentDidChange()
        "recieve".forEach { engine.type(String($0)) }
        engine.tapSpace()
        XCTAssertEqual(document.before, "I think receive ")
        engine.tapBackspace()
        XCTAssertEqual(document.before, "I think recieve ", "the first backspace takes the fix back")

        let relaunched = launch()
        XCTAssertEqual(typed("recieve", in: relaunched), "recieve ", "persisted across the relaunch")
        XCTAssertEqual(typed("thier", in: relaunched), "their ", "other words are still fixed")
    }

    // F5: a word that is typed the same way three times without being undone is learned.
    func testAWordTypedThreeTimesIsLearnedAndThenLeftAlone() {
        let runner = launch()
        XCTAssertEqual(typed("zorblax", in: runner), "zorblax ")
        XCTAssertEqual(typed("zorblax", in: runner), "zorblax ")
        XCTAssertTrue(learnedCalls.isEmpty, "not yet")
        XCTAssertEqual(typed("zorblax", in: runner), "zorblax ")
        XCTAssertEqual(learnedCalls, ["zorblax"])
        let relaunched = launch()
        XCTAssertEqual(typed("zorblax", in: relaunched), "zorblax ")
        XCTAssertEqual(learnedCalls, ["zorblax"], "told once, not again")
    }

    // F6: a fix that the user keeps is not "typing a word the same way": three kept fixes of "teh" learn nothing.
    func testKeptFixesAreNeverLearned() {
        let runner = launch()
        for _ in 0..<4 { XCTAssertEqual(typed("teh", in: runner), "the ") }
        XCTAssertTrue(learnedCalls.isEmpty)
    }

    // F7: a document with no identifier (the path PR 14 made safe) corrects and does not trap.
    func testADocumentWithNoIdentifierIsStillCorrected() {
        let runner = launch()
        runner.documentIdentifier = nil
        XCTAssertEqual(typed("recieve", in: runner), "receive ")
    }

    // F8: the document is swapped for another in the middle of a word: nothing is corrected, nothing traps.
    func testAStaleDocumentIdentifierMidWordCorrectsNothing() {
        let runner = launch()
        let document = CorpusDocument()
        document.before = "I think "
        let engine = TypingEngine(document: document, suggestionSource: runner.builder, now: { 0 })
        engine.completionHandler = runner.autocorrector
        engine.documentDidChange()
        "recie".forEach { engine.type(String($0)) }
        document.identifier = UUID()
        engine.documentDidChange()
        "ve".forEach { engine.type(String($0)) }
        engine.tapSpace()
        XCTAssertEqual(document.before, "I think recieve ", "a word split across documents is not one word typed here")
    }

    // F9: two typos in a row, as fast as the keys come.
    func testTwoTyposInARowAreBothFixed() {
        let runner = launch()
        XCTAssertEqual(typed("teh recieve", in: runner), "the receive ")
    }

    // F10: a long run of letters never reaches the checker, and a number is never touched.
    func testAVeryLongWordAndADigitWordAreLeftAlone() {
        let runner = launch()
        let long = String(repeating: "abcdefghij", count: 6)
        XCTAssertEqual(typed(long, in: runner), long + " ")
        XCTAssertEqual(typed("t3h", in: runner), "t3h ")
    }

    // F11: the language is not English: nothing is corrected.
    func testANonEnglishDocumentIsNeverCorrected() {
        let runner = CorpusRunner(language: "fr-FR") { UITextCheckerAdapter() }
        XCTAssertEqual(typed("recieve", in: runner), "recieve ")
    }
}
