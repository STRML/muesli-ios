import UIKit
import XCTest

/// Regenerates `Tests/KeyboardTypingKitTests/Corpus/CommonWords.swift`'s word list from the system's own
/// completion ranking. Skipped unless `MUESLI_COMMON_WORDS_OUT` names the file to write, so a normal run never
/// touches it:
///
///     TEST_RUNNER_MUESLI_COMMON_WORDS_OUT=/path/words.txt xcodebuild test ... -only-testing:MuesliTests/CommonWordsHarvestTests
///
/// `UITextChecker.completions` returns the 20 most used words with a prefix, most used first. Walking every
/// one- and two-letter prefix gives a list ordered by how soon a word shows up: a word in the top 20 for "t"
/// is more common than one that first appears under "tha". See the README beside the data for why this list
/// exists instead of a published frequency list.
@MainActor
final class CommonWordsHarvestTests: XCTestCase {
    func testHarvestCommonWords() throws {
        guard let out = ProcessInfo.processInfo.environment["MUESLI_COMMON_WORDS_OUT"] else {
            throw XCTSkip("Set MUESLI_COMMON_WORDS_OUT (as TEST_RUNNER_MUESLI_COMMON_WORDS_OUT) to regenerate the word list.")
        }
        let checker = UITextChecker()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var firstSeen: [String: (depth: Int, position: Int, order: Int)] = [:]
        var order = 0
        func collect(_ prefix: String, depth: Int) -> Int {
            let found = checker.completions(
                forPartialWordRange: NSRange(location: 0, length: prefix.count), in: prefix, language: "en_US"
            ) ?? []
            for (position, word) in found.enumerated() where firstSeen[word] == nil {
                firstSeen[word] = (depth, position, order)
                order += 1
            }
            return found.count
        }
        for first in letters {
            let count = collect(String(first), depth: 1)
            guard count >= 20 else { continue }
            for second in letters { _ = collect(String(first) + String(second), depth: 2) }
        }
        let ranked = firstSeen.sorted { lhs, rhs in
            (lhs.value.depth, lhs.value.position, lhs.value.order) < (rhs.value.depth, rhs.value.position, rhs.value.order)
        }.map(\.key)
        try ranked.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("HARVEST \(ranked.count) words -> \(out)")
    }

    /// The long tail: words that only show up under a three-letter prefix, so they are less used than anything in
    /// the common list. Used to keep the usage prior honest: a corpus made only of listed words teaches the rule
    /// that an unlisted word is never the target. Skipped unless `MUESLI_TAIL_WORDS_OUT` is set.
    func testHarvestTailWords() throws {
        guard let out = ProcessInfo.processInfo.environment["MUESLI_TAIL_WORDS_OUT"] else {
            throw XCTSkip("Set MUESLI_TAIL_WORDS_OUT (as TEST_RUNNER_MUESLI_TAIL_WORDS_OUT) to regenerate the tail list.")
        }
        let checker = UITextChecker()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        func completions(_ prefix: String) -> [String] {
            checker.completions(forPartialWordRange: NSRange(location: 0, length: prefix.count), in: prefix, language: "en_US") ?? []
        }
        var common = Set<String>()
        var tail = Set<String>()
        for first in letters {
            let one = completions(String(first))
            common.formUnion(one)
            guard one.count >= 20 else { continue }
            for second in letters {
                let two = completions(String(first) + String(second))
                common.formUnion(two)
                guard two.count >= 20 else { continue }
                for third in letters { tail.formUnion(completions(String(first) + String(second) + String(third))) }
            }
        }
        let words = tail.subtracting(common).filter { $0.count >= 4 && $0.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter } }.sorted()
        try words.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("HARVEST tail \(words.count) words -> \(out)")
    }
}
