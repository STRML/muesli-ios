import Foundation

/// A word that might be what the user meant, with what the system's own engine says about it.
struct TypingCandidate: Sendable, Equatable {
    let word: String
    /// Where `UITextChecker.guesses` put it, or nil when only our own generation found it.
    let guessPosition: Int?
    /// How used the word is, read from the checker's completions: entry `k - 1` is the word's place in the
    /// checker's list of the most used words starting with its first `k` letters, or -1 when it is not there.
    /// A word that already shows up under one letter is among the most used words with that letter.
    let usage: [Int]
}

/// Finds the candidates for a word the checker flagged: the checker's own guesses, each checked to be a word, with
/// how used it is. Our own generation of candidates (every word one cheap slip away that the checker accepts, found
/// with `rangeOfMisspelledWord` as the oracle) was built and measured against the real checker on 29,000 typos: it
/// raised the corrected rate by 0.1 point and cost about ten milliseconds a word, so it was taken out.
@MainActor
struct TypingCandidatePool {
    struct Options: Sendable, Equatable {
        /// How many letters of each word's prefix are looked up in the checker's completions, at most.
        var usageDepth = 4
        /// Only this many of the cheapest candidates are looked up in the completions.
        var usageLimit = 8
        var weights = TypingEditWeights()
    }

    let checker: TypingSpellChecking
    let language: String
    var options = Options()

    func candidates(for typed: String, guesses: [String]? = nil, excluding excluded: Set<String> = []) -> [TypingCandidate] {
        let word = typed.lowercased()
        var guessPositions: [String: Int] = [:]
        var seen = Set<String>()
        var order: [String] = []
        func note(_ candidate: String, guessPosition: Int?) {
            guard seen.insert(candidate).inserted else { return }
            guessPositions[candidate] = guessPosition
            order.append(candidate)
        }
        let given = guesses ?? checker.guesses(forWord: word, language: language)
        // The checker offers "Jason" for "json" and "GitHub" for "githb": lowercase typing is not turned into a name.
        let typedHasCapital = typed.contains(where: \.isUppercase)
        for (position, guess) in given.enumerated() {
            let lowered = guess.lowercased()
            guard Self.isPlainWord(guess), typedHasCapital || guess == lowered, lowered != word,
                  !excluded.contains(lowered), isWord(lowered) else { continue }
            note(lowered, guessPosition: position)
        }
        let ranked = order.sorted {
            TypingEditCost.between(word, $0, weights: options.weights) < TypingEditCost.between(word, $1, weights: options.weights)
        }
        let probed = Set(ranked.prefix(options.usageLimit))
        // Candidates for one typo mostly share their first letters, so they share most of these lookups.
        var completions: [String: [String]] = [:]
        return order.map { candidate in
            TypingCandidate(
                word: candidate, guessPosition: guessPositions[candidate],
                usage: probed.contains(candidate) ? usage(of: candidate, completions: &completions) : []
            )
        }
    }

    private func isWord(_ word: String) -> Bool { !checker.isMisspelled(word, language: language) }

    /// Letters only: a guess with an apostrophe, a hyphen or a space is a different kind of fix.
    private static func isPlainWord(_ guess: String) -> Bool {
        !guess.isEmpty && guess.allSatisfy(\.isLetter)
    }

    private func usage(of word: String, completions cache: inout [String: [String]]) -> [Int] {
        let letters = Array(word)
        return (1...max(1, min(letters.count, options.usageDepth))).map { length in
            let prefix = String(letters.prefix(length))
            if cache[prefix] == nil { cache[prefix] = checker.completions(forPartial: prefix, language: language).map { $0.lowercased() } }
            return cache[prefix]?.firstIndex(of: word) ?? -1
        }
    }
}
