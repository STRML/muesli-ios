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
    private var enabled = true
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
            isEnabled: { [unowned self] in self.enabled },
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

    private func cost(_ typed: String, _ candidate: String) -> Double {
        TypingEditCost.between(typed, candidate, weights: TypingEditWeights())
    }

    /// "abcdef" to "abpdef": c to p is a substitution between keys that are not neighbours, 1.7 (not first
    /// letter, so no +0.4). A six-letter word's budget is 1.0, so 1.7 > 1.0 and nothing is scored.
    func testEveryGuessOverTheEditBudget() {
        XCTAssertEqual(cost("abcdef", "abpdef"), 1.7, accuracy: 0.0001)
        flag("abcdef", guesses: ["abpdef"])
        XCTAssertNil(finish("abcdef"))
        assertOneDecline("budget")
    }

    func testAThreeLetterWordThatIsNotASwap() {
        flag("tej", guesses: ["ten"])
        XCTAssertNil(finish("tej"))
        assertOneDecline("short_word")
    }

    /// "garsn" to "garden": d to s is a neighbour substitution (0.4) and the missing "e" an insertion (0.6), cost
    /// 1.0, within the five-letter budget of 1.0. The checker lists "garden" under neither "g" nor "ga" (its
    /// "g" completions are just ["go"]), so the usage miss adds 1.4: 1.0 + 1.4 = 2.4 > maximumScore 2.2.
    func testABestGuessThatScoresTooHigh() {
        XCTAssertEqual(cost("garsn", "garden"), 1.0, accuracy: 0.0001)
        flag("garsn", guesses: ["garden"], listed: false)
        checker.completionTable["g"] = ["go"]
        XCTAssertNil(finish("garsn"))
        assertOneDecline("max_score")
        XCTAssertEqual(declines.first?["completions_empty"], "false")
    }

    /// "wich" to "which" and to "witch" each insert one letter, 0.6. The checker lists both (which first, then
    /// witch), so the scores are 0.6 and 0.605 (0.005 per place down the list). The gap 0.005 < margin 0.6.

    func testTwoGuessesTooCloseToCall() {
        flag("wich", guesses: ["which", "witch"])
        XCTAssertNil(finish("wich"))
        assertOneDecline("margin")
    }

    /// The same "garsn" fixture with no completions at all: 1.0 + usage miss 1.4 = 2.4 > 2.2 would be max_score,
    /// but the checker returned nothing for "g", so the decline is read as usage_unavailable.
    func testEmptyCompletionsReadAsUsageUnavailable() {
        flag("garsn", guesses: ["garden"], listed: false)
        XCTAssertNil(finish("garsn"))
        assertOneDecline("usage_unavailable")
        XCTAssertEqual(declines.first?["completions_empty"], "true")
    }

    /// "tgrir" to "their": g to h and r to e are both neighbour substitutions, 0.4 + 0.4 = 0.8 <= budget 1.0, and
    /// the checker lists "their" first, so the score is 0.8 and it would be corrected. Before a "." it needs a
    /// single edit and this is two, so the strict check declines.
    func testAStrictBoundaryThatNeedsMoreThanOneEdit() {
        XCTAssertEqual(cost("tgrir", "their"), 0.8, accuracy: 0.0001)
        flag("tgrir", guesses: ["their"])
        XCTAssertNil(finish("tgrir", .punctuation(".")))
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

    /// "w" has no completions but "wh" and "wi" list the guesses, so usage is available. "which" and "witch" cost
    /// 0.6 each plus 0.1 for being listed under the second letter: 0.7 and 0.7, a gap of 0 < margin 0.6.
    func testUsageListedUnderTheSecondLetterIsNotUnavailable() {
        flag("wich", guesses: ["which", "witch"], listed: false)
        checker.completionTable["wh"] = ["which"]
        checker.completionTable["wi"] = ["witch"]
        XCTAssertNil(finish("wich"))
        assertOneDecline("margin")
        XCTAssertEqual(declines.first?["completions_empty"], "false")
    }

    func testAProxyMismatchIsNotLoggedWhileAutocorrectIsOff() {
        enabled = false
        "teh".forEach { engine.type(String($0)) }
        document.staleBefore = "something else"
        engine.tapSpace()
        XCTAssertEqual(recorded.count, 0, "\(recorded)")
    }

    func testAProxyMismatchIsNotLoggedInAFieldThatGatesCorrection() {
        var traits = TypingTraits()
        traits.variant = .url
        engine.apply(traits: traits)
        recorded = []
        "teh".forEach { engine.type(String($0)) }
        document.staleBefore = "something else"
        engine.tapSpace()
        XCTAssertEqual(recorded.count, 0, "\(recorded)")
    }

    func testMovingBetweenTwoGatedFieldsWithTheSameTraitsLogsEachField() {
        var traits = TypingTraits()
        traits.suggestionsDisabled = true
        engine.apply(traits: traits)
        document.documentIdentifier = UUID()
        engine.apply(traits: traits)
        XCTAssertEqual(declines.map { $0["decline_reason"] }, ["traits_gate", "traits_gate"])
        XCTAssertEqual(declines.map { $0["count"] }, ["1", "2"])
        // The same field echoing its traits again is not a new field.
        engine.apply(traits: traits)
        XCTAssertEqual(declines.count, 2)
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
