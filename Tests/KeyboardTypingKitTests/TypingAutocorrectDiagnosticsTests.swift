import XCTest
@testable import KeyboardTypingKit

@MainActor
private final class WordStore: TypingLearnedWordsStoring {
    var words = TypingLearnedWords()
    func load() -> TypingLearnedWords { words }
    func save(_ words: TypingLearnedWords) { self.words = words }
}

/// What the keyboard writes to its diagnostics log when autocorrect leaves a word alone: one line per decision,
/// a closed reason, lengths and booleans, never the word.
@MainActor
final class TypingAutocorrectDiagnosticsTests: XCTestCase {
    private var checker = FakeSpellChecker()
    private var document = FakeDocument()
    private var recorded: [(name: String, attrs: [String: String])] = []
    private var diagnostics: TypingAutocorrectDiagnostics!
    private var languages = ["en-US"]
    private var store = WordStore()
    private var corrector: TypingAutocorrector!
    private var engine: TypingEngine!

    override func setUp() async throws {
        checker = FakeSpellChecker()
        document = FakeDocument()
        recorded = []
        languages = ["en-US"]
        store = WordStore()
        diagnostics = TypingAutocorrectDiagnostics { [unowned self] name, attrs in self.recorded.append((name, attrs)) }
        engine = TypingEngine(document: document, suggestionSource: FakeSuggestionSource(), now: { 0 })
        engine.diagnostics = diagnostics
        corrector = makeCorrector()
        engine.completionHandler = corrector
    }

    private func makeCorrector() -> TypingAutocorrector {
        TypingAutocorrector(
            checker: { [unowned self] in self.checker },
            languageCandidates: { [unowned self] in self.languages },
            traits: { [unowned self] in self.engine.state.traits },
            isEnabled: { true },
            learnedWords: store,
            diagnostics: diagnostics
        )
    }

    private func finish(_ word: String, _ boundary: TypingBoundary = .space) -> TypingEditPlan? {
        corrector.wordCompleted(TypingWordCompletedEvent(
            word: word, boundary: boundary, contextBefore: "I think \(word)", documentIdentifier: nil
        ))
    }

    private func flag(_ word: String, guesses: [String], listed: Bool = true) {
        checker.misspelled.insert(word)
        checker.guessTable[word] = guesses
        if listed { checker.listGuessesAsUsed() }
    }

    private var declines: [[String: String]] { recorded.filter { $0.name == "autocorrect.declined" }.map(\.attrs) }

    private func assertOneDecline(_ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(declines.count, 1, "\(recorded)", file: file, line: line)
        XCTAssertEqual(declines.first?["decline_reason"], reason, "\(recorded)", file: file, line: line)
    }

    // MARK: One event per reason

    func testNoGuessesAtAll() {
        flag("qzxwv", guesses: [])
        XCTAssertNil(finish("qzxwv"))
        assertOneDecline("no_guesses")
    }

    func testEveryGuessTooDifferentInLength() {
        flag("abcde", guesses: ["abcdefgh"])
        XCTAssertNil(finish("abcde"))
        assertOneDecline("length_diff")
    }

    func testEveryGuessOverTheEditBudget() {
        flag("abcdef", guesses: ["abxxef"])
        XCTAssertNil(finish("abcdef"))
        assertOneDecline("budget")
    }

    func testAThreeLetterWordThatIsNotASwap() {
        flag("tej", guesses: ["ten"])
        XCTAssertNil(finish("tej"))
        assertOneDecline("short_word")
    }

    func testABestGuessThatScoresTooHigh() {
        flag("recieve", guesses: ["receive"], listed: false)
        checker.completionTable["r"] = ["run"]
        XCTAssertNil(finish("recieve"))
        assertOneDecline("max_score")
        XCTAssertEqual(declines.first?["completions_empty"], "false")
    }

    func testTwoGuessesTooCloseToCall() {
        flag("wich", guesses: ["which", "witch"])
        XCTAssertNil(finish("wich"))
        assertOneDecline("margin")
    }

    func testEmptyCompletionsReadAsUsageUnavailable() {
        flag("recieve", guesses: ["receive"], listed: false)
        XCTAssertNil(finish("recieve"))
        assertOneDecline("usage_unavailable")
        XCTAssertEqual(declines.first?["completions_empty"], "true")
    }

    func testAStrictBoundaryThatNeedsMoreThanOneEdit() {
        flag("thier", guesses: ["their"])
        // "thier" to "their" is a swap (one edit), so use two keys off instead.
        flag("tgeir", guesses: ["their"])
        XCTAssertNil(finish("tgeir", .punctuation(".")))
        assertOneDecline("strict_edit")
        XCTAssertEqual(declines.first?["boundary"], "punctuation")
    }

    func testAWordTheUserTookBack() {
        flag("teh", guesses: ["the"])
        store.words.reject("teh")
        corrector = makeCorrector()
        XCTAssertNil(finish("teh"))
        assertOneDecline("rejected_word")
    }

    func testAWordTheUserKeepsTyping() {
        flag("kubectl", guesses: [])
        var words = TypingLearnedWords()
        _ = words.noteLeftAsTyped("kubectl")
        _ = words.noteLeftAsTyped("kubectl")
        _ = words.noteLeftAsTyped("kubectl")
        store.words = words
        corrector = makeCorrector()
        XCTAssertNil(finish("kubectl"))
        assertOneDecline("learned_word")
    }

    func testALanguageThatIsNotCorrected() {
        languages = ["fr-FR"]
        flag("teh", guesses: ["the"])
        XCTAssertNil(finish("teh"))
        assertOneDecline("language_unsupported")
    }

    func testACorrectionThatAppliesLogsNothing() {
        flag("teh", guesses: ["the"])
        XCTAssertNotNil(finish("teh"))
        XCTAssertEqual(recorded.count, 0)
    }

    func testAWordTheCheckerAcceptsLogsNothing() {
        XCTAssertNil(finish("hello"))
        XCTAssertEqual(recorded.count, 0)
    }

    func testAttrsCarryLengthBoundaryAndVariant() {
        flag("qzxwv", guesses: [])
        _ = finish("qzxwv", .returnKey)
        XCTAssertEqual(declines.first?["word_len"], "5")
        XCTAssertEqual(declines.first?["boundary"], "return")
        XCTAssertEqual(declines.first?["field_variant"], "standard")
        XCTAssertEqual(declines.first?["count"], "1")
    }

    // MARK: Engine bails

    func testAProxyThatDisagreesWithWhatWasTypedLogsOnce() {
        flag("teh", guesses: ["the"])
        for _ in 0..<3 {
            document.before = ""
            engine.documentDidChange()
            "teh".forEach { engine.type(String($0)) }
            document.staleBefore = "something else"
            engine.tapSpace()
            document.staleBefore = nil
        }
        XCTAssertEqual(declines.filter { $0["decline_reason"] == "proxy_mismatch" }.count, declines.count)
        XCTAssertEqual(declines.map { $0["count"] }, ["1", "2"])
        XCTAssertEqual(declines.first?["word_len"], "3")
        XCTAssertEqual(declines.first?["boundary"], "space")
    }

    func testAFieldThatForbidsCorrectionLogsOncePerChangeNotPerKeystroke() {
        var traits = TypingTraits()
        traits.suggestionsDisabled = true
        engine.apply(traits: traits)
        engine.apply(traits: traits)
        engine.apply(traits: traits)
        "hello".forEach { engine.type(String($0)) }
        engine.apply(traits: traits)
        assertOneDecline("traits_gate")
        XCTAssertEqual(declines.first?["suggestions_off"], "true")
        XCTAssertNil(declines.first?["word_len"])
    }

    func testAUrlFieldIsAGateAndAPlainFieldIsNot() {
        var traits = TypingTraits()
        traits.variant = .url
        engine.apply(traits: traits)
        assertOneDecline("traits_gate")
        XCTAssertEqual(declines.first?["field_variant"], "url")
        recorded = []
        engine.apply(traits: TypingTraits())
        XCTAssertEqual(recorded.count, 0)
    }

    // MARK: Volume and privacy

    /// A new unrecognized word each time, so the learn-after-three-times rule does not change the reason.
    private func nonsenseWord(_ index: Int) -> String {
        var word = "qzx"
        var rest = index
        repeat {
            word.append(Character(UnicodeScalar(97 + rest % 26)!))
            rest /= 26
        } while rest > 0
        flag(word, guesses: [])
        return word
    }

    func testRepeatsAreCountedOnPowersOfTwo() {
        for index in 0..<9 { _ = finish(nonsenseWord(index)) }
        XCTAssertEqual(declines.map { $0["count"] }, ["1", "2", "4", "8"])
    }

    func testADifferentReasonOrBoundaryHasItsOwnCount() {
        flag("abcde", guesses: ["abcdefgh"])
        _ = finish(nonsenseWord(0))
        _ = finish(nonsenseWord(1), .returnKey)
        _ = finish("abcde")
        XCTAssertEqual(declines.count, 3)
        XCTAssertEqual(Set(declines.compactMap { $0["count"] }), ["1"])
    }

    func testAThousandDeclinesStayUnderAHandfulOfLines() {
        for index in 0..<1000 { _ = finish(nonsenseWord(index)) }
        XCTAssertLessThanOrEqual(recorded.count, 11)
    }

    func testNoAttributeCarriesTheWordOrAnyFreeText() {
        let typed = ["qzxwv", "abcde", "recieve", "tej", "kubectl", "teh"]
        flag("qzxwv", guesses: [])
        flag("abcde", guesses: ["abcdefgh"])
        flag("recieve", guesses: ["receive", "relieve"])
        flag("tej", guesses: ["ten"])
        languages = ["en-US"]
        for word in typed { _ = finish(word); _ = finish(word, .returnKey); _ = finish(word, .punctuation(".")) }
        var traits = TypingTraits()
        traits.suggestionsDisabled = true
        engine.apply(traits: traits)
        XCTAssertFalse(recorded.isEmpty)
        let allowedKeys: Set = ["decline_reason", "boundary", "word_len", "completions_empty", "field_variant",
                                "suggestions_off", "secure", "count"]
        for (name, attrs) in recorded {
            XCTAssertEqual(name, "autocorrect.declined")
            XCTAssertTrue(Set(attrs.keys).isSubset(of: allowedKeys), "\(attrs.keys)")
            for (key, value) in attrs {
                XCTAssertNotNil(value.range(of: #"^[a-z0-9_]{1,24}$"#, options: .regularExpression), "\(key)=\(value)")
                for word in typed + ["the", "receive", "relieve", "ten", "abcdefgh"] {
                    XCTAssertFalse(value.contains(word), "\(key)=\(value) leaks \(word)")
                }
            }
        }
    }

    func testEveryReasonIsInTheDiagnosticsVocabularyAndDocs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vocabulary = try String(contentsOf: root.appendingPathComponent("Shared/DiagnosticsShipping/DiagnosticsVocabulary.swift"), encoding: .utf8)
        let docs = try String(contentsOf: root.appendingPathComponent("docs/diagnostics-shipping.md"), encoding: .utf8)
        for reason in TypingDeclineReason.allCases {
            XCTAssertTrue(vocabulary.contains("\"\(reason.rawValue)\""), "\(reason) missing from the vocabulary")
            XCTAssertTrue(docs.contains(reason.rawValue), "\(reason) missing from the docs")
        }
    }
}
