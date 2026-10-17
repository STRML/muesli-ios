import Foundation

/// Looks at the whole token the word sits in. The word extractor stops at `#`, `@`, `.`, `/` and `_`, so
/// "hashtg" in "#hashtg" and "gmial" in "sam@gmial" arrive as plain words; the text before them says otherwise.
enum TypingTokenContext {
    static let maximumWordLength = 24
    private static let openingMarks: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{2018}", "(", "[", "{", "\u{00AB}", "\u{00BF}", "\u{00A1}",
    ]

    /// True when nothing but an opening quote or bracket is glued to the front of the word.
    static func isStandaloneWord(_ word: String, contextBefore: String?) -> Bool {
        guard let before = contextBefore else { return true }
        guard before.hasSuffix(word) else { return false }
        let glued = before.dropLast(word.count).reversed().prefix(while: { !$0.isWhitespace })
        return glued.allSatisfy { openingMarks.contains($0) }
    }

    /// Whether the word is the first of a sentence, where a capital is auto-capitalize and not a name.
    static func startsSentence(word: String, contextBefore: String?) -> Bool {
        let prefix = contextBefore.map { String($0.dropLast(word.count)) }
        return TypingAutocapitalizationPolicy.capitalizesNext(mode: .sentences, before: prefix)
    }

    /// Only plain words: letters, at most the first one a capital. Not ALL CAPS, camelCase or anything with a
    /// digit, apostrophe, hyphen or underscore, and not too short or too long for a dictionary to judge.
    static func hasCorrectableShape(_ word: String) -> Bool {
        guard (3...maximumWordLength).contains(word.count), word.allSatisfy(\.isLetter) else { return false }
        return !word.dropFirst().contains(where: { $0.isUppercase })
    }
}
