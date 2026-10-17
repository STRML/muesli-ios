#if canImport(KeyboardTypingKit)
@testable import KeyboardTypingKit
#else
@testable import Muesli
#endif

/// A fake `UITextChecker` for the host layer: the word list is the dictionary, its order is the usage ranking,
/// and guesses are the nearest words by edit distance. It is far smaller and plainer than the real engine, so it
/// only tests the logic around the checker; the numbers that matter come from the simulator run.
@MainActor
final class DictionaryChecker: TypingSpellChecking {
    let availableLanguages = ["en_US"]
    private let ordered: [String]
    private let words: Set<String>
    private let rank: [String: Int]
    private var byPrefix: [String: [String]] = [:]
    private(set) var ignored = Set<String>()

    init(words: [String]) {
        ordered = words.map { $0.lowercased() }
        self.words = Set(ordered)
        rank = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for word in ordered {
            for length in 1...word.count {
                let prefix = String(word.prefix(length))
                if byPrefix[prefix, default: []].count < 20 { byPrefix[prefix, default: []].append(word) }
            }
        }
    }

    func isMisspelled(_ word: String, language: String) -> Bool {
        let lowered = word.lowercased()
        return !words.contains(lowered) && !ignored.contains(lowered)
    }

    func completions(forPartial partial: String, language: String) -> [String] {
        byPrefix[partial.lowercased()] ?? []
    }

    /// The words one slip away, most used first. The real checker also reaches two edits; this is enough to
    /// exercise the logic around it.
    func guesses(forWord word: String, language: String) -> [String] {
        let lowered = word.lowercased()
        let near = Set(Self.oneEditVariants(of: lowered).filter { words.contains($0) })
        return near.sorted { (rank[$0] ?? 0, $0) < (rank[$1] ?? 0, $1) }.prefix(12).map { $0 }
    }

    /// Every string one edit away: a letter left out, swapped, replaced or inserted.
    private static func oneEditVariants(of word: String) -> [String] {
        let letters = Array(word), alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var variants: [String] = []
        for index in letters.indices {
            var changed = letters
            changed.remove(at: index)
            variants.append(String(changed))
            if index + 1 < letters.count {
                changed = letters
                changed.swapAt(index, index + 1)
                variants.append(String(changed))
            }
            for letter in alphabet {
                changed = letters
                changed[index] = letter
                variants.append(String(changed))
            }
        }
        for index in 0...letters.count {
            for letter in alphabet {
                var changed = letters
                changed.insert(letter, at: index)
                variants.append(String(changed))
            }
        }
        return variants
    }

    func ignore(_ word: String) { ignored.insert(word.lowercased()) }
}
