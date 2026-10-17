import XCTest
@testable import KeyboardTypingKit

/// The generated corpus through the real engine and autocorrector on the host, with a fake dictionary made from
/// the word list. It tests the logic around the checker (the pool, the rule, the engine, undo and capitalization),
/// not how good the real checker's guesses are: that is `AutocorrectCorpusTests` in the simulator. A tenth of the
/// words, so a plain `swift test` stays quick.
@MainActor
final class HostCorpusTests: XCTestCase {
    private func makeRunner() -> CorpusRunner {
        let dictionary = DictionaryChecker(words: CommonWords.all)
        return CorpusRunner { dictionary }
    }

    private var sampledWords: [String] {
        CommonWords.all.filter { TypoGenerator.stableHash($0) % 12 == 3 }
    }

    // Q4: with a dictionary whose guesses are plain nearest-word lookups, most single slips in longer words are fixed.
    func testGeneratedTyposAreMostlyFixedWithAFakeDictionary() {
        let runner = makeRunner()
        let run = runner.run(generated: TypoGenerator.generate(from: sampledWords))
        let longSingle = run.trials.filter { CorpusReport.singleSlipClasses.contains($0.kind) && $0.length >= 4 }
        let rate = CorpusRate(longSingle)
        print("HOST CORPUS single-slip 4+: \(rate.text); excluded as words: \(run.excludedAsWords)")
        XCTAssertGreaterThan(run.trials.count, 1000)
        XCTAssertGreaterThanOrEqual(rate.correctedRate, 0.6, rate.text)
        XCTAssertLessThanOrEqual(rate.wrongRate, 0.06, rate.text)
    }

    // Q5: the tokens that look like something other than a word stay as typed whatever the dictionary says. A
    // fake dictionary of 4,000 words knows no slang or brand, so those categories are only reported here; the
    // simulator run holds them to the 1% limit.
    func testTokensThatAreNotWordsAreLeftAloneWithAFakeDictionary() {
        let runner = makeRunner()
        let trials = runner.runNeverChange(groups: AutocorrectCorpus.neverChangeGroups)
        print("HOST NEVER-CHANGE " + CorpusReport.neverChange(trials).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(AutocorrectCorpus.neverChange.count, 300)
        let structural: Set<String> = [
            "hashtags and handles", "urls, hosts and emails", "numbers with units", "code-like tokens", "accents",
            "apostrophes and hyphens",
        ]
        // "node" is a word to the real checker but not to this 4,000-word dictionary, so "node.js" is left out.
        let changed = trials.filter { structural.contains($0.category) && $0.wasChanged && $0.token != "node.js" }
        XCTAssertTrue(changed.isEmpty, changed.map(\.token).joined(separator: ", "))
    }

    // Q6: the hand-made typos, with the same fake dictionary.
    func testTheHandMadeTyposAreMostlyFixedWithAFakeDictionary() {
        let trials = makeRunner().run(pairs: AutocorrectCorpus.typos, kind: "hand-made")
        let rate = CorpusRate(trials)
        print("HOST HAND-MADE \(rate.text)")
        XCTAssertGreaterThanOrEqual(rate.correctedRate, 0.5, rate.text)
    }

    // Q7: the report reads the same numbers it was given.
    func testTheReportCountsWhatItIsGiven() {
        let trials = [
            CorpusTrial(typed: "teh", intended: "the", kind: "transposition", length: 3, isTuning: true, result: "the ", guessPosition: 0),
            CorpusTrial(typed: "wich", intended: "which", kind: "drop", length: 5, isTuning: true, result: "wish ", guessPosition: 2),
            CorpusTrial(typed: "hte", intended: "the", kind: "transposition", length: 3, isTuning: false, result: "hte ", guessPosition: nil),
        ]
        let rate = CorpusRate(trials)
        XCTAssertEqual([rate.corrected, rate.wrong, rate.unchanged], [1, 1, 1])
        XCTAssertEqual(trials.map(\.missStage), [nil, .rankedLower, .notInGuesses])
        XCTAssertTrue(CorpusReport.missStages(trials).joined().contains("1"))
    }
}
