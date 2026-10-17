import Foundation

/// What each kind of slip costs when comparing a typed word with a candidate. A plain edit distance treats
/// "teh" to "the" and "wich" to "wish" alike; a thumb does not: it hits the key next to the one it wanted, drops
/// a letter, doubles one, or swaps two, and those are far likelier than a letter from across the keyboard.
struct TypingEditWeights: Sendable, Equatable {
    var transposition = 0.45
    var neighbourSubstitution = 0.4
    var vowelSubstitution = 0.8
    var substitution = 1.7
    /// The candidate has a letter the user did not type (a dropped letter).
    var insertion = 0.6
    /// ... and it is a second copy of a neighbouring letter ("tomorow" for "tomorrow").
    var doubledInsertion = 0.8
    /// The user typed a letter the candidate lacks.
    var deletion = 1.4
    /// ... and it repeats the letter beside it ("thhe").
    var doubledDeletion = 0.8
    /// Added to any edit that touches the first letter: people rarely misspell how a word starts.
    var firstLetter = 0.4
}

enum TypingEditCost {
    /// The cheapest weighted edit script from `typed` to `candidate` (optimal string alignment: an adjacent
    /// swap is one step), compared without regard to case.
    static func between(_ typed: String, _ candidate: String, weights: TypingEditWeights = TypingEditWeights()) -> Double {
        let s = Array(typed.lowercased()), t = Array(candidate.lowercased())
        if s.isEmpty || t.isEmpty { return Double(s.count + t.count) }
        let aligner = Aligner(s: s, t: t, weights: weights)
        var twoBack = [Double](repeating: 0, count: t.count + 1)
        var previous = [0.0]
        for j in 1...t.count { previous.append(previous[j - 1] + aligner.insertionCost(j)) }
        var leading = 0.0
        for i in 1...s.count {
            leading += aligner.deletionCost(i)
            var row = [Double](repeating: leading, count: t.count + 1)
            for j in 1...t.count {
                row[j] = aligner.cell(i, j, previous: previous, row: row, twoBack: twoBack)
            }
            twoBack = previous
            previous = row
        }
        return previous[t.count]
    }

    private struct Aligner {
        let s: [Character]
        let t: [Character]
        let weights: TypingEditWeights

        func cell(_ i: Int, _ j: Int, previous: [Double], row: [Double], twoBack: [Double]) -> Double {
            var best = min(
                previous[j] + deletionCost(i), row[j - 1] + insertionCost(j),
                previous[j - 1] + substitutionCost(i, j)
            )
            if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1], s[i - 1] != s[i - 2] {
                best = min(best, twoBack[j - 2] + weights.transposition + (i == 2 ? weights.firstLetter : 0))
            }
            return best
        }

        /// The typed letter `s[i - 1]` has no counterpart.
        func deletionCost(_ i: Int) -> Double {
            let letter = s[i - 1]
            let repeats = (i > 1 && s[i - 2] == letter) || (i < s.count && s[i] == letter)
            return (repeats ? weights.doubledDeletion : weights.deletion) + (i == 1 ? weights.firstLetter : 0)
        }

        /// The candidate letter `t[j - 1]` was never typed.
        func insertionCost(_ j: Int) -> Double {
            let letter = t[j - 1]
            let repeats = (j > 1 && t[j - 2] == letter) || (j < t.count && t[j] == letter)
            return (repeats ? weights.doubledInsertion : weights.insertion) + (j == 1 ? weights.firstLetter : 0)
        }

        func substitutionCost(_ i: Int, _ j: Int) -> Double {
            let typed = s[i - 1], wanted = t[j - 1]
            if typed == wanted { return 0 }
            let base: Double
            if TypingKeyAdjacency.areNeighbours(typed, wanted) {
                base = weights.neighbourSubstitution
            } else if isVowel(typed), isVowel(wanted) {
                base = weights.vowelSubstitution
            } else {
                base = weights.substitution
            }
            return base + (i == 1 ? weights.firstLetter : 0)
        }

        private func isVowel(_ letter: Character) -> Bool { "aeiou".contains(letter) }
    }
}
