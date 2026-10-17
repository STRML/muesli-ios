import Foundation

/// Last-resort, engine-independent removal of a known hallucinated phrase from the end of a transcript, when the audio
/// under it is silent.
///
/// It drops a phrase only when every one of these holds, and otherwise returns the text untouched:
/// - the detected language is English or unknown (the list is English; another language is never touched),
/// - the phrase is the last sentence of the text and is on `phrases` (a phrase anywhere else is left alone),
/// - the audio under that sentence has no speech in it, judged with the same detector the trimmer uses and with a
///   200 ms tolerance either side for rounded timestamps (a phrase the speaker really said has speech under it),
/// - when the phrase is the whole text, the whole clip is silent.
///
/// With segment timestamps the audio under the phrase is its own time span. Without them (a remote endpoint, Parakeet)
/// it is the last 600 ms of the clip and at most one phrase is dropped, so a real "thank you" before a hallucinated
/// one survives. An empty profile proves nothing and drops nothing.
enum HallucinatedTailFilter {
    struct Segment: Sendable, Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    enum DropReason: String, Sendable {
        case silentSegment = "silent_segment"
        case silentTail = "silent_tail"
        case silentClip = "silent_clip"
    }

    struct Dropped: Sendable, Equatable {
        var reason: DropReason
        /// Characters of the removed text, never the text itself.
        var phraseLength: Int
    }

    struct Result: Sendable, Equatable {
        var text: String
        var dropped: [Dropped]
    }

    struct Phrase: Sendable, Equatable {
        /// Normalised: lower case words separated by single spaces (see `normalised`).
        var text: String
        /// Where it was observed; an entry without a source does not belong here.
        var source: String
    }

    /// Seconds either side of a phrase's time span that still count as "under" it.
    static let timestampTolerance: TimeInterval = 0.2
    /// Without timestamps: the part of the clip that has to be silent for a trailing phrase to be dropped.
    static let tailWindow: TimeInterval = 0.6

    /// Only entries with evidence belong here: seen in this repo's harness fixtures (Tests/TailHarness, WhisperKit
    /// large-v3-v20240930_626MB on `say` speech followed by silence), or in a published report cited by URL. Phrases
    /// that are plausible speech and unobserved ("so", "okay", "oh") are deliberately absent.
    static let phrases: [Phrase] = [
        Phrase(
            text: "thank you",
            source: "Observed in the harness (appended after 2-4 s of silence and alone over digital silence); "
                + "24.76% of Whisper's non-speech output, Table III of https://arxiv.org/abs/2501.11378"
        ),
        Phrase(
            text: "you",
            source: "Observed in the harness (appended to a 10 s paragraph followed by silence); "
                + "2.24% in Table III of https://arxiv.org/abs/2501.11378"
        ),
        Phrase(
            text: "bye",
            source: "0.56% in Table III of https://arxiv.org/abs/2501.11378; named in the task report, not seen in the harness"
        ),
        Phrase(
            text: "thanks for watching",
            source: "10.32% in Table III of https://arxiv.org/abs/2501.11378"
        ),
        Phrase(
            text: "thank you for watching",
            source: "2.58% in Table III of https://arxiv.org/abs/2501.11378; "
                + "\"Thank you for watching\" after music in https://github.com/openai/whisper/discussions/928"
        ),
        Phrase(
            text: "subtitles by the amara org community",
            source: "0.46% in Table III of https://arxiv.org/abs/2501.11378; "
                + "https://github.com/openai/whisper/discussions/928"
        ),
    ]

    /// Lower case words (letters, digits, apostrophes) separated by single spaces; punctuation and `<|...|>` special
    /// tokens are ignored.
    static func normalised(_ text: String) -> String {
        tokens(of: text).map(\.word).joined(separator: " ")
    }

    static func apply(
        text: String,
        segments: [Segment],
        language: String?,
        profile: ClipEnergyProfile
    ) -> Result {
        let unchanged = Result(text: text, dropped: [])
        guard profile.frameCount > 0, isEnglishOrUnknown(language) else { return unchanged }
        let spans: [Range<Int>]
        switch SilenceTrimmer.analyse(profile) {
        case .indeterminate: return unchanged   // cannot prove the audio is silent, so nothing is dropped
        case .silent: spans = []
        case .speech(let found): spans = found
        }
        let timing = WordTiming(segments: segments, text: text)

        var current = text
        var dropped = [Dropped]()
        while let tail = trailingPhrase(in: current) {
            let onlyPhrase = tail.wordIndex == 0
            let window = timing?.window(forWordAt: tail.wordIndex, profileDuration: profile.duration)
            let reason: DropReason
            if onlyPhrase {
                guard spans.isEmpty else { break }
                reason = .silentClip
            } else if let window {
                guard !hasSpeech(spans, in: window) else { break }
                reason = .silentSegment
            } else {
                let end = profile.duration
                guard !hasSpeech(spans, in: (end - tailWindow)...end, tolerance: 0) else { break }
                reason = .silentTail
            }
            dropped.append(Dropped(reason: reason, phraseLength: tail.removedLength))
            current = tail.remaining
            // Without per-phrase timestamps the evidence covers one phrase only.
            if window == nil || onlyPhrase { break }
        }
        return dropped.isEmpty ? unchanged : Result(text: current, dropped: dropped)
    }

    // MARK: Language

    private static func isEnglishOrUnknown(_ language: String?) -> Bool {
        guard let language = language?.lowercased(), !language.isEmpty else { return true }
        return language == "en" || language.hasPrefix("en-") || language.hasPrefix("en_")
    }

    // MARK: Audio

    private static func hasSpeech(_ spans: [Range<Int>], in window: ClosedRange<TimeInterval>, tolerance: TimeInterval = timestampTolerance) -> Bool {
        let lower = ClipEnergyProfile.frame(atSeconds: window.lowerBound - tolerance)
        let upper = ClipEnergyProfile.frame(atSeconds: window.upperBound + tolerance)
        return spans.contains { $0.lowerBound < upper && $0.upperBound > lower }
    }

    // MARK: Text

    private struct Token {
        var word: String
        var range: Range<String.Index>
    }

    /// Words with their ranges in `text`. `<|...|>` special tokens are skipped.
    private static func tokens(of text: String) -> [Token] {
        var result = [Token]()
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("<|"), let close = text[index...].range(of: "|>") {
                index = close.upperBound
                continue
            }
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, isWordCharacter(text[index]) {
                index = text.index(after: index)
            }
            let word = text[start..<index].lowercased().replacingOccurrences(of: "’", with: "'")
            result.append(Token(word: word.trimmingCharacters(in: CharacterSet(charactersIn: "'")), range: start..<index))
        }
        return result.filter { !$0.word.isEmpty }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    private struct TrailingPhrase {
        var wordIndex: Int
        var remaining: String
        var removedLength: Int
    }

    /// The last sentence of `text`, when it is exactly a listed phrase.
    private static func trailingPhrase(in text: String) -> TrailingPhrase? {
        let words = tokens(of: text)
        for phrase in phrases.sorted(by: { $0.text.count > $1.text.count }) {
            let parts = phrase.text.split(separator: " ").map(String.init)
            guard words.count >= parts.count,
                  words.suffix(parts.count).map(\.word) == parts
            else { continue }
            let firstIndex = words.count - parts.count
            let start = words[firstIndex].range.lowerBound
            guard startsSentence(text, at: start) else { continue }
            let removed = stripSpecialTokens(String(text[start...])).trimmingCharacters(in: .whitespacesAndNewlines)
            return TrailingPhrase(
                wordIndex: firstIndex,
                remaining: stripTrailingSpecialTokens(String(text[..<start])).trimmingCharacters(in: .whitespacesAndNewlines),
                removedLength: removed.count
            )
        }
        return nil
    }

    /// True when only whitespace, quotes or special tokens sit between the start of the text, or a sentence-ending
    /// mark, and `index`.
    private static func startsSentence(_ text: String, at index: String.Index) -> Bool {
        let before = stripSpecialTokens(String(text[..<index]))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”‘'([")))
        guard let last = before.last else { return true }
        return ".!?…".contains(last)
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
    }

    private static func stripTrailingSpecialTokens(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("|>"), let open = result.range(of: "<|", options: .backwards) {
            result = String(result[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: Word timing

    /// Maps each word of the full text to a time, by spreading each segment's words evenly over its span. Only built
    /// when the segments' words are exactly the text's words; otherwise the timestamps are not trusted.
    private struct WordTiming {
        private var starts: [TimeInterval] = []
        private var ends: [TimeInterval] = []

        init?(segments: [Segment], text: String) {
            guard !segments.isEmpty else { return nil }
            var words = [String]()
            for segment in segments {
                let segmentWords = HallucinatedTailFilter.tokens(of: segment.text).map(\.word)
                guard !segmentWords.isEmpty else { continue }
                let span = max(0, segment.end - segment.start)
                for (index, word) in segmentWords.enumerated() {
                    words.append(word)
                    starts.append(segment.start + span * Double(index) / Double(segmentWords.count))
                    ends.append(segment.end)
                }
            }
            guard words == HallucinatedTailFilter.tokens(of: text).map(\.word) else { return nil }
        }

        /// From the phrase's first word to the end of the text. Words that were dropped before are not in `text` any
        /// more, so the index is into the current text, which is always a prefix of the original.
        func window(forWordAt index: Int, profileDuration: TimeInterval) -> ClosedRange<TimeInterval>? {
            guard index < starts.count, let lastEnd = ends.last else { return nil }
            return starts[index]...max(starts[index], lastEnd)
        }
    }
}
