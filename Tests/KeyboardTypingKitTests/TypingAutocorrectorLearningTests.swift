import XCTest
@testable import KeyboardTypingKit

@MainActor
private final class MemoryWordStore: TypingLearnedWordsStoring {
    var words = TypingLearnedWords()
    private(set) var saves = 0
    func load() -> TypingLearnedWords { words }
    func save(_ words: TypingLearnedWords) {
        self.words = words
        saves += 1
    }
}

/// Matrix rows L8-L16: undo persistence across launches, and learning a word typed three times.
@MainActor
final class TypingAutocorrectorLearningTests: XCTestCase {
    private var checker = FakeSpellChecker()
    private var store = MemoryWordStore()
    private var ignored: [String] = []
    private var learnedCalls: [String] = []

    override func setUp() async throws {
        checker = FakeSpellChecker()
        checker.misspelled = ["teh", "kubectl", "recieve", "tej"]
        checker.guessTable = ["teh": ["the"], "kubectl": [], "recieve": ["receive"], "tej": ["teh"]]
        checker.listGuessesAsUsed()
        store = MemoryWordStore()
        ignored = []
        learnedCalls = []
    }

    /// One keyboard launch over the shared store.
    private func launch() -> TypingAutocorrector {
        TypingAutocorrector(
            checker: { [unowned self] in self.checker },
            languageCandidates: { ["en-US"] },
            traits: { TypingTraits() },
            isEnabled: { true },
            ignoreWord: { [unowned self] in self.ignored.append($0) },
            learnedWords: store,
            learnWord: { [unowned self] in self.learnedCalls.append($0) }
        )
    }

    private func finish(_ word: String, with corrector: TypingAutocorrector) -> TypingEditPlan? {
        corrector.wordCompleted(TypingWordCompletedEvent(
            word: word, boundary: .space, contextBefore: "I think \(word)", documentIdentifier: nil
        ))
    }

    private func undo(of word: String, to fixed: String) -> TypingReplacementUndo {
        TypingReplacementUndo(replacedText: word + " ", insertedText: fixed + " ", originalWord: word)
    }

    // L8: undo persists across keyboard launches.
    func testATakenBackWordIsNotCorrectedAfterARelaunch() {
        let first = launch()
        XCTAssertNotNil(finish("teh", with: first))
        first.replacementWasRejected(undo(of: "teh", to: "the"))
        XCTAssertNil(finish("teh", with: first), "this launch")

        let second = launch()
        XCTAssertNil(finish("teh", with: second), "the next launch reads it back from the store")
        XCTAssertNotNil(finish("recieve", with: second), "other words are still corrected")
    }

    // L9: a relaunch replays the stored words into the checker's ignore list.
    func testTheStoredWordsAreReplayedIntoTheCheckerOnLaunch() {
        var words = TypingLearnedWords()
        words.reject("teh")
        _ = words.noteLeftAsTyped("kubectl")
        store.words = words
        _ = launch()
        XCTAssertEqual(ignored, ["teh"])
    }

    // L10: the third time, not before.
    func testAWordLeftAsTypedThreeTimesIsLearned() {
        let corrector = launch()
        _ = finish("kubectl", with: corrector)
        _ = finish("kubectl", with: corrector)
        XCTAssertTrue(learnedCalls.isEmpty)
        _ = finish("kubectl", with: corrector)
        XCTAssertEqual(learnedCalls, ["kubectl"])
        XCTAssertTrue(ignored.contains("kubectl"), "and the checker stops flagging it")
        XCTAssertTrue(store.words.isLearned("kubectl"))
    }

    // L11: once learned, never again, and not told twice.
    func testALearnedWordIsNeverCorrectedOrLearnedTwice() {
        let corrector = launch()
        for _ in 0..<3 { _ = finish("kubectl", with: corrector) }
        checker.guessTable["kubectl"] = ["kubectl2"]
        checker.misspelled.insert("kubectl2")
        XCTAssertNil(finish("kubectl", with: corrector))
        XCTAssertEqual(learnedCalls, ["kubectl"])
    }

    // L12: a word that was corrected and kept is not "typed the same way".
    func testWordsThatWereCorrectedAreNeverCounted() {
        let corrector = launch()
        for _ in 0..<5 { XCTAssertNotNil(finish("teh", with: corrector)) }
        XCTAssertTrue(learnedCalls.isEmpty)
        XCTAssertTrue(store.words.seen.isEmpty)
    }

    // L13: learning survives a relaunch, counts included.
    func testTheCountSurvivesARelaunch() {
        _ = finish("kubectl", with: launch())
        _ = finish("kubectl", with: launch())
        XCTAssertTrue(learnedCalls.isEmpty)
        _ = finish("kubectl", with: launch())
        XCTAssertEqual(learnedCalls, ["kubectl"])
    }

    // L14: the oracle trap. A rejected word is valid to the checker afterwards, so it must not become the target
    // of another typo.
    func testARejectedWordIsNeverTheTargetOfAnotherTypo() {
        let corrector = launch()
        corrector.replacementWasRejected(undo(of: "teh", to: "the"))
        checker.misspelled.remove("teh")
        XCTAssertNil(finish("tej", with: corrector), "tej would be corrected to the rejected teh")
    }

    // L15: no store at all (tests, or defaults unavailable) still corrects and never traps.
    func testWithoutAStoreTheSessionStillWorks() {
        let corrector = TypingAutocorrector(
            checker: { [unowned self] in self.checker }, languageCandidates: { ["en-US"] },
            traits: { TypingTraits() }, isEnabled: { true }
        )
        XCTAssertNotNil(finish("teh", with: corrector))
        corrector.replacementWasRejected(undo(of: "teh", to: "the"))
        XCTAssertNil(finish("teh", with: corrector))
    }

    // L16: the stored lists stay capped however many words are rejected.
    func testTheStoredListsStayCapped() {
        let corrector = launch()
        for index in 0..<(TypingLearnedWords.maximumRejected + 50) {
            corrector.replacementWasRejected(undo(of: "w\(index)", to: "x"))
        }
        XCTAssertEqual(store.words.rejected.count, TypingLearnedWords.maximumRejected)
    }
}
