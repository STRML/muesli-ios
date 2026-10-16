import Foundation

/// Edit distance counting an adjacent swap as one edit (optimal string alignment), compared without regard to
/// case. "teh" to "the" is one edit, which is what lets a three-letter word be fixed at all.
enum TypingEditDistance {
    static func between(_ a: String, _ b: String) -> Int {
        let s = Array(a.lowercased())
        let t = Array(b.lowercased())
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var twoBack = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0...t.count)
        for i in 1...s.count {
            var row = [Int](repeating: i, count: t.count + 1)
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    row[j] = min(row[j], twoBack[j - 2] + 1)
                }
            }
            twoBack = previous
            previous = row
        }
        return previous[t.count]
    }
}

/// Whether a spell-checker guess is safe to type over what the user wrote. Conservative on purpose: a wrong
/// correction is worse than a missed one, so every doubt returns nil.
enum TypingAutocorrectRule {
    /// How many of the checker's guesses are compared. The checker's order is trusted for the first one only
    /// when no near guess beats it.
    static let lookahead = 3

    /// Two letters or fewer are never corrected, three take one edit, everything longer two.
    static func maximumDistance(forWordLength length: Int) -> Int {
        switch length {
        case ..<3: 0
        case 3: 1
        default: 2
        }
    }

    /// The guess to type instead of `typed`, or nil. `strict` is for a word that may be the start of a host name
    /// or a URL scheme ("github" before a "."), where only a single edit is accepted.
    static func correction(for typed: String, guesses: [String], strict: Bool = false) -> String? {
        let limit = min(maximumDistance(forWordLength: typed.count), strict ? 1 : 2)
        guard limit > 0 else { return nil }
        let usable = guesses.lazy.filter { isUsable($0, for: typed) }.prefix(lookahead)
        let candidates = Array(usable)
        guard let top = candidates.first else { return nil }
        let distance = TypingEditDistance.between(typed, top)
        guard distance <= limit else { return nil }
        let isClear = candidates.dropFirst().allSatisfy { TypingEditDistance.between(typed, $0) >= distance }
        return isClear ? top : nil
    }

    /// A single word that keeps the first letter, is not just the typed word in another case, and does not
    /// turn lowercase typing into a proper noun or an acronym (the checker offers "Jason" for "json").
    private static func isUsable(_ guess: String, for typed: String) -> Bool {
        guard !guess.isEmpty, !guess.contains(where: { $0.isWhitespace }) else { return false }
        guard guess.lowercased() != typed.lowercased() else { return false }
        guard guess.first?.lowercased() == typed.first?.lowercased() else { return false }
        let typedHasCapital = typed.contains(where: { $0.isUppercase })
        return typedHasCapital || !guess.contains(where: { $0.isUppercase })
    }
}
