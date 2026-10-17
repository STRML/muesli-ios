import Foundation

enum TypingAutocapitalizationPolicy {
    private static let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]

    /// Whether the next typed letter should be a capital, given the text before the cursor.
    static func capitalizesNext(mode: TypingAutocapitalization, before: String?) -> Bool {
        switch mode {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = before?.last else { return true }
            return last.isWhitespace
        case .sentences:
            return startsSentence(before ?? "")
        }
    }

    private static func startsSentence(_ before: String) -> Bool {
        guard let last = before.last else { return true }
        let trimmed = before.reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
        // Nothing but spaces so far, or a line break: a new line starts a sentence.
        guard let lastSignificant = trimmed.first else { return true }
        if lastSignificant.isNewline { return true }
        // A terminator only counts once a space follows it ("3.14" and "e.g" are not sentence ends).
        guard last == " " || last == "\t" || last == "\u{00A0}" else { return false }
        let beforeCloser = trimmed.drop(while: { closers.contains($0) })
        guard let terminator = beforeCloser.first else { return false }
        return terminators.contains(terminator)
    }
}
