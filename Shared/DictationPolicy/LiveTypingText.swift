import Foundation

/// Text rules for typing the streaming words into the host field. Pure, so they run in `swift test`.
enum LiveTypingText {
    /// A marked range longer than this commits its finished sentences as plain text.
    ///
    /// A dictation under the 60 s long-voice-note default is at most about 200 words, 1,200 characters even for a
    /// fast speaker, so the normal path never chunks and its final pass can still revise every word. Above it, the
    /// host re-lays-out the whole marked range on every update, and a chunk that is committed can no longer be
    /// revised in place; 1,500 characters (about 90 s of speech) keeps both costs bounded.
    static let chunkThreshold = 1_500
    /// The most characters the final replace will delete to rewrite committed text. Each is a proxy call.
    static let maxRewriteDelete = 3_000

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
    private static let cjkSentenceEnds: Set<Character> = ["\u{3002}", "\u{FF01}", "\u{FF1F}"]

    /// A form of `text` that survives what hosts do to marked text: capitalization, smart punctuation, spaces.
    static func folded(_ text: String) -> String {
        var result = text.precomposedStringWithCanonicalMapping.lowercased()
        let replacements: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2026}", "..."),
            ("\u{00A0}", " "), ("\u{202F}", " "), ("\u{2009}", " "),
        ]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        return result
    }

    /// Whether the text before the cursor ends with the marked words, allowing for what hosts change.
    static func contextEnds(with marked: String, in context: String) -> Bool {
        guard !marked.isEmpty else { return true }
        // Only the end is compared, so a long document costs no more than a short one.
        let tail = String(context.suffix(marked.count + 8))
        return folded(tail).hasSuffix(folded(marked))
    }

    static func trimmedPartial(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Words, for editing a dictation as it streams

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// `text` without its last word and the space before it, or nil when there is no word to remove.
    static func droppingLastWord(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let space = trimmed.lastIndex(where: \.isWhitespace) else { return "" }
        return String(trimmed[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What follows the first `count` words of `text`, without the space in front of it.
    static func text(of text: String, afterWords count: Int) -> String {
        var index = text.startIndex
        var seen = 0
        while index < text.endIndex, seen < count {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            seen += 1
        }
        return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func joined(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        return tail.isEmpty ? head : head + " " + tail
    }

    /// The `selectedRange` for `setMarkedText`: it is relative to the marked text and counts UTF-16 units. The
    /// cursor goes at the end, where the next words will be.
    static func markedSelection(for text: String) -> NSRange {
        NSRange(location: text.utf16.count, length: 0)
    }

    /// Where to commit a long marked range: through the last finished sentence that leaves some words marked.
    static func sentenceSplit(_ text: String, threshold: Int = chunkThreshold) -> (commit: String, rest: String)? {
        guard text.count > threshold else { return nil }
        var lastBoundary: String.Index?
        var sawBoundary = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if let boundary = boundaryEnd(in: text, at: index, character: character, next: next) {
                sawBoundary = true
                if boundary < text.endIndex { lastBoundary = boundary }
            }
            index = next
        }
        if let lastBoundary { return (String(text[..<lastBoundary]), String(text[lastBoundary...])) }
        // A boundary only at the very end leaves nothing marked: wait for more words.
        guard !sawBoundary, text.count > threshold * 2 else { return nil }
        guard let space = text.lastIndex(of: " "), text.index(after: space) < text.endIndex else { return nil }
        let end = text.index(after: space)
        return (String(text[..<end]), String(text[end...]))
    }

    /// The index just past a sentence end at `index` and the white space after it, or nil if there is none.
    private static func boundaryEnd(in text: String, at index: String.Index, character: Character, next: String.Index) -> String.Index? {
        let isNewline = character == "\n"
        guard isNewline || sentenceEnds.contains(character) else { return nil }
        let followedBySpace = next < text.endIndex && text[next].isWhitespace
        let atEnd = next == text.endIndex
        guard isNewline || cjkSentenceEnds.contains(character) || followedBySpace || atEnd else { return nil }
        var end = next
        while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
        return end
    }
}
