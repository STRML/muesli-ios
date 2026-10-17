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
/// correction is worse than a missed one, so every doubt returns nil. Each rule below exists because the corpus
/// run (AutocorrectCorpusTests) showed the real checker proposing "Jason" for "json" or "oath" for "oauth".
enum TypingAutocorrectRule {
    /// How many of the checker's guesses are compared.
    static let lookahead = 3

    /// Two letters or fewer are never corrected, up to seven take one edit, eight and more two: at most a
    /// quarter of the word may change.
    static func maximumDistance(forWordLength length: Int) -> Int {
        switch length {
        case ..<3: 0
        case 3..<8: 1
        default: 2
        }
    }

    /// The guess to type instead of `typed`, or nil. `strict` is for a word that may be the start of a host name
    /// or a URL scheme ("github" before a "."), where only a single edit is accepted.
    static func correction(for typed: String, guesses: [String], strict: Bool = false) -> String? {
        let limit = min(maximumDistance(forWordLength: typed.count), strict ? 1 : 2)
        guard limit > 0 else { return nil }
        let candidates = Array(guesses.lazy.filter { isUsable($0, for: typed) }.prefix(lookahead))
        guard let top = candidates.first else { return nil }
        let distance = TypingEditDistance.between(typed, top)
        guard distance <= limit, isSlip(from: typed, to: top) else { return nil }
        let isSwap = isAdjacentSwap(typed, top)
        // With three letters only a swap is trusted ("teh"); "npm" and "faq" are words.
        if typed.count == 3, !isSwap { return nil }
        let rivals = candidates.dropFirst().map { TypingEditDistance.between(typed, $0) }
        guard rivals.allSatisfy({ $0 >= distance }) else { return nil }
        // A tie is ambiguous ("wich": "which" or "wish"), unless the top guess just swaps two letters typed.
        if rivals.contains(distance), !isSwap { return nil }
        return top
    }

    /// A single word of letters that keeps the first letter, is not just the typed word in another case, and
    /// does not turn lowercase typing into a proper noun or an acronym (the checker offers "Jason" for "json").
    private static func isUsable(_ guess: String, for typed: String) -> Bool {
        guard !guess.isEmpty, guess.allSatisfy(\.isLetter) else { return false }
        guard guess.lowercased() != typed.lowercased() else { return false }
        guard guess.first?.lowercased() == typed.first?.lowercased() else { return false }
        let typedHasCapital = typed.contains(where: { $0.isUppercase })
        return typedHasCapital || !guess.contains(where: { $0.isUppercase })
    }

    static func isAdjacentSwap(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x.count == y.count && x != y && x.sorted() == y.sorted() && TypingEditDistance.between(x, y) == 1
    }

    /// An edit that looks like a slip of the fingers or of the spelling: any insertion, deletion or swap, and a
    /// single replaced letter only when it is a vowel for a vowel or the key next to it.
    private static func isSlip(from typed: String, to guess: String) -> Bool {
        let a = Array(typed.lowercased()), b = Array(guess.lowercased())
        guard a.count == b.count, TypingEditDistance.between(typed, guess) == 1, !isAdjacentSwap(typed, guess)
        else { return true }
        return zip(a, b).allSatisfy { $0 == $1 || isSlip(replacing: $0, with: $1) }
    }

    private static func isSlip(replacing typed: Character, with guess: Character) -> Bool {
        if vowels.contains(typed), vowels.contains(guess) { return true }
        guard let from = keyPositions[typed], let to = keyPositions[guess] else { return false }
        let dy = abs(from.row - to.row), dx = abs(from.x - to.x)
        return (dy == 0 && dx <= 1.0) || (dy == 1 && dx < 1.0)
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Where each letter sits on a QWERTY keyboard, rows staggered the way the keys are.
    private static let keyPositions: [Character: (row: Int, x: Double)] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let offsets = [0.0, 0.25, 0.75]
        var positions: [Character: (row: Int, x: Double)] = [:]
        for (row, letters) in rows.enumerated() {
            for (column, letter) in letters.enumerated() { positions[letter] = (row, Double(column) + offsets[row]) }
        }
        return positions
    }()
}
