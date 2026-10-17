import XCTest
@testable import KeyboardTypingKit

/// Matrix rows T1-T10: the generated corpus is the same on every run and only contains slips of the kind it names.
final class TypoGeneratorTests: XCTestCase {
    private let typable = TypoGenerator.typableWords(from: CommonWords.all)

    // T1: seeded, not random.
    func testTheSameWordGivesTheSameTyposOnEveryRun() {
        XCTAssertEqual(TypoGenerator.typos(for: "because"), TypoGenerator.typos(for: "because"))
        XCTAssertEqual(TypoGenerator.generate(from: CommonWords.all), TypoGenerator.generate(from: CommonWords.all))
    }

    func testAWordsTyposDoNotDependOnTheListAroundIt() {
        let alone = TypoGenerator.typos(for: "tomorrow")
        let inContext = TypoGenerator.generate(from: ["hello", "tomorrow", "world"]).filter { $0.intended == "tomorrow" }
        XCTAssertEqual(alone, inContext)
    }

    // T2: pinned, so a change to the generator is a deliberate act and re-measures the corpus.
    func testTheCorpusIsPinned() {
        let all = TypoGenerator.generate(from: CommonWords.all)
        let hash = TypoGenerator.stableHash(all.map { "\($0.kind.rawValue):\($0.typed)>\($0.intended)" }.joined(separator: "|"))
        XCTAssertEqual(all.count, 20_469)
        XCTAssertEqual(String(hash), TypoGeneratorTests.pinnedHash)
    }

    static let pinnedHash = "16108988655588921000"

    // T3: every class is there, in volume.
    func testEveryClassIsGenerated() {
        let all = TypoGenerator.generate(from: CommonWords.all)
        for kind in TypoClass.allCases {
            XCTAssertGreaterThan(all.filter { $0.kind == kind }.count, kind == .apostrophe ? 50 : 1000, kind.rawValue)
        }
    }

    // T4
    func testANeighbourTypoReplacesOneLetterWithAKeyNextToIt() {
        for typo in TypoGenerator.generate(from: typable).filter({ $0.kind == .neighbour }).prefix(2000) {
            let pairs = zip(typo.typed, typo.intended).filter { $0 != $1 }
            XCTAssertEqual(typo.typed.count, typo.intended.count)
            XCTAssertEqual(pairs.count, 1, typo.typed)
            XCTAssertTrue(TypingKeyAdjacency.areNeighbours(pairs[0].0, pairs[0].1), "\(typo.typed) for \(typo.intended)")
        }
    }

    // T5
    func testADropTypoLacksOneLetter() {
        for typo in TypoGenerator.generate(from: typable).filter({ $0.kind == .drop }).prefix(2000) {
            XCTAssertEqual(typo.typed.count, typo.intended.count - 1)
            XCTAssertEqual(TypingEditDistance.between(typo.typed, typo.intended), 1)
        }
    }

    // T6
    func testADoubleTypoRepeatsOneLetter() {
        for typo in TypoGenerator.generate(from: typable).filter({ $0.kind == .double }).prefix(2000) {
            XCTAssertEqual(typo.typed.count, typo.intended.count + 1)
            XCTAssertTrue(zip(typo.typed, typo.typed.dropFirst()).contains { $0 == $1 }, typo.typed)
        }
    }

    // T7
    func testATranspositionSwapsTwoNeighbouringDifferentLetters() {
        for typo in TypoGenerator.generate(from: typable).filter({ $0.kind == .transposition }).prefix(2000) {
            XCTAssertEqual(typo.typed.sorted(), typo.intended.sorted())
            XCTAssertEqual(TypingEditDistance.between(typo.typed, typo.intended), 1)
            XCTAssertNotEqual(typo.typed, typo.intended)
        }
    }

    // T8
    func testAnApostropheTypoIsTheContractionWithoutItsApostrophe() {
        let typo = TypoGenerator.apostropheTypo(for: "don't")
        XCTAssertEqual(typo, GeneratedTypo(typed: "dont", intended: "don't", kind: .apostrophe))
        XCTAssertEqual(TypoGenerator.apostropheTypo(for: "I'm")?.typed, "im")
        XCTAssertTrue(TypoGenerator.contractions(from: CommonWords.all).contains("don't"))
    }

    // T9
    func testOnlyPlainLowercaseWordsOfThreeLettersOrMoreAreTyped() {
        XCTAssertTrue(typable.allSatisfy { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLowercase } })
        XCTAssertFalse(typable.contains("don't"))
        XCTAssertFalse(typable.contains("I"))
    }

    // T10: tuning and held-out halves are both big, and a word is on one side for good.
    func testTheTwoHalvesAreBalancedAndStable() {
        let tuning = typable.filter(TypoGenerator.isTuningWord)
        XCTAssertGreaterThan(tuning.count, typable.count * 4 / 10)
        XCTAssertLessThan(tuning.count, typable.count * 6 / 10)
        XCTAssertEqual(TypoGenerator.isTuningWord("because"), TypoGenerator.isTuningWord("because"))
    }

    func testTheWordListIsBigEnoughAndSmallEnough() {
        XCTAssertGreaterThan(CommonWords.all.count, 4000)
        XCTAssertEqual(Set(CommonWords.all).count, CommonWords.all.count, "no duplicates")
        XCTAssertLessThan(CommonWords.all.joined(separator: "\n").utf8.count, 100_000)
    }
}
