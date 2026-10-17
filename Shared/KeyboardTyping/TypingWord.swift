import Foundation

enum TypingCursorWord: Sendable, Equatable {
    /// No word ends at the cursor (empty field, after a space or punctuation, after a digit or emoji).
    case none
    /// The cursor is in the middle of a word: letters on both sides.
    case insideWord
    /// The letters of the word that ends at the cursor.
    case partial(String)
}

enum TypingWordExtractor {
    /// Longer than any real word; also keeps the checker away from CJK runs and pasted tokens.
    static let maximumWordLength = 48

    private static let joiners: Set<Character> = ["'", "\u{2019}", "\u{2018}", "-", "\u{2010}", "\u{2011}"]

    /// The word that ends at the cursor. Letters make a word; an apostrophe or hyphen joins letters inside one.
    /// Anything with a digit is not a word to correct, and an emoji or punctuation ends one.
    static func word(before: String?, after: String?) -> TypingCursorWord {
        guard let before, !before.isEmpty else { return .none }
        let run = String(before.reversed().prefix(while: isWordCharacter).reversed())
        let trimmed = String(run.drop(while: { joiners.contains($0) }))
        guard let last = trimmed.last, last.isLetter, !isEmojiLike(last) else { return .none }
        guard !trimmed.contains(where: { $0.isNumber }), trimmed.count <= maximumWordLength else { return .none }
        if let next = after?.first, next.isLetter || next.isNumber, !isEmojiLike(next) { return .insideWord }
        return .partial(trimmed)
    }

    /// Whether a typed character ends the word before it. Apostrophes and hyphens are part of words ("don't",
    /// "well-known"); letters and digits are too.
    static func endsWord(_ character: Character) -> Bool {
        !isWordCharacter(character)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        if isEmojiLike(character) { return false }
        return character.isLetter || character.isNumber || joiners.contains(character)
    }

    private static func isEmojiLike(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3
        }
    }
}
