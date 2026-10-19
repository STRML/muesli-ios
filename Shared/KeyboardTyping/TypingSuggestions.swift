import Foundation

struct TypingSuggestion: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Equatable {
        /// What was typed, offered when the checker thinks it is misspelled.
        case verbatim
        case correction
        case completion
        /// A contact name or a text replacement from `UILexicon`.
        case lexicon
        /// The word as typed, offered right after autocorrect changed it. A tap puts it back.
        case original
    }

    let text: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(text)" }
}

struct TypingLexiconEntry: Sendable, Equatable {
    let userInput: String
    let documentText: String
}

/// The slice of `UITextChecker` the strip uses, so tests can fake it.
@MainActor
protocol TypingSpellChecking: AnyObject {
    var availableLanguages: [String] { get }
    func isMisspelled(_ word: String, language: String) -> Bool
    func completions(forPartial partial: String, language: String) -> [String]
    func guesses(forWord word: String, language: String) -> [String]
    /// Stop flagging this word for the life of this checker.
    func ignore(_ word: String)
}

enum TypingLanguageResolver {
    /// "en" for "en_US" and "en-GB".
    static func baseCode(of language: String) -> String {
        language.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map { String($0).lowercased() } ?? ""
    }

    /// The first candidate the checker has a dictionary for, spelled the way the checker spells it
    /// ("en-US" becomes "en_US"). A language with no dictionary at all resolves to nil, so the strip shows
    /// nothing instead of guesses from the wrong language.
    static func resolve(candidates: [String], available: [String]) -> String? {
        for candidate in candidates {
            let normalized = candidate.replacingOccurrences(of: "-", with: "_")
            if let exact = available.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                return exact
            }
            let base = normalized.split(separator: "_").first.map(String.init) ?? normalized
            if let sameLanguage = available.first(where: { $0.split(separator: "_").first.map(String.init) == base }) {
                return sameLanguage
            }
        }
        return nil
    }
}

@MainActor
protocol TypingSuggestionSource: AnyObject {
    func suggestions(forPartial partial: String) -> [TypingSuggestion]
    /// Alternatives for a word the user just finished (the cursor is past its space or punctuation): guesses when
    /// the word is misspelled, nothing when it is fine.
    func corrections(forCompletedWord word: String) -> [TypingSuggestion]
    /// The host moved to another document: drop the checker so a new one is made for it.
    func documentDidChange()
}

/// Suggestions for the partial word: the user's own shortcuts and contacts first, then what the spell checker
/// offers. The checker is created on first use and dropped when the document changes, so a keyboard that never
/// shows a word never pays for one.
@MainActor
final class TypingSuggestionBuilder: TypingSuggestionSource {
    static let maximumLexiconEntries = 2000
    private static let maximumLexiconSuggestions = 2

    private let makeChecker: () -> TypingSpellChecking
    private let languageCandidates: () -> [String]
    private let limit: Int
    private var checker: TypingSpellChecking?
    private var lexicon: [TypingLexiconEntry] = []
    private var ignoredWords = Set<String>()

    init(
        makeChecker: @escaping () -> TypingSpellChecking,
        languageCandidates: @escaping () -> [String],
        limit: Int = 3
    ) {
        self.makeChecker = makeChecker
        self.languageCandidates = languageCandidates
        self.limit = limit
    }

    var hasCreatedChecker: Bool { checker != nil }
    var lexiconCount: Int { lexicon.count }

    /// Contacts and text replacements from `UILexicon`. Capped, and entries with an empty side are dropped.
    func setLexicon(_ entries: [TypingLexiconEntry]) {
        lexicon = Array(
            entries.lazy.filter { !$0.userInput.isEmpty && !$0.documentText.isEmpty }
                .prefix(Self.maximumLexiconEntries)
        )
    }

    func documentDidChange() {
        checker = nil
    }

    /// Words the user rejected, kept for the session and replayed into every new checker, so the strip stops
    /// flagging a word the user insisted on. `UITextChecker.ignoreWord` only lasts as long as one instance.
    func ignore(_ word: String) {
        ignoredWords.insert(word)
        checker?.ignore(word)
    }

    /// The checker for this document, made on first use. The autocorrector shares it with the strip.
    func currentChecker() -> TypingSpellChecking { resolvedChecker() }

    func suggestions(forPartial partial: String) -> [TypingSuggestion] {
        guard !partial.isEmpty else { return [] }
        var result = lexiconSuggestions(for: partial)
        result += checkerSuggestions(for: partial)
        return Array(deduplicated(result, partial: partial).prefix(limit))
    }

    /// Guesses for a word the user just finished, only when the checker thinks it is misspelled, with the
    /// contraction first for a word missing its apostrophe ("dont"). A word with an apostrophe, a contact or
    /// shortcut of the user's, and a language without a dictionary get nothing.
    func corrections(forCompletedWord word: String) -> [TypingSuggestion] {
        let lowered = word.lowercased()
        guard !word.isEmpty, !word.contains("'"), !word.contains("\u{2019}"),
              !lexicon.contains(where: { $0.userInput.lowercased() == lowered })
        else { return [] }
        guard let language = resolvedLanguage() else { return [] }
        var candidates: [String] = []
        if TypingLanguageResolver.baseCode(of: language) == "en", let contraction = TypingContractions.correction(for: word) {
            candidates.append(contraction)
        }
        let checker = resolvedChecker()
        if checker.isMisspelled(word, language: language) {
            candidates += checker.guesses(forWord: word, language: language).map { matchCase($0, to: word) }
        }
        var seen = Set<String>([lowered])
        let corrections = candidates.filter { seen.insert($0.lowercased()).inserted }
        return corrections.prefix(limit).map { TypingSuggestion(text: $0, kind: .correction) }
    }

    private func lexiconSuggestions(for partial: String) -> [TypingSuggestion] {
        let needle = partial.lowercased()
        let exact = lexicon.filter { $0.userInput.lowercased() == needle }
        let prefixed = lexicon.filter {
            let input = $0.userInput.lowercased()
            return input != needle && input.hasPrefix(needle)
        }
        return (exact + prefixed).prefix(Self.maximumLexiconSuggestions).map {
            TypingSuggestion(text: $0.documentText, kind: .lexicon)
        }
    }

    private func checkerSuggestions(for partial: String) -> [TypingSuggestion] {
        guard let language = resolvedLanguage() else { return [] }
        let checker = resolvedChecker()
        let completions = checker.completions(forPartial: partial, language: language)
            .map { TypingSuggestion(text: matchCase($0, to: partial), kind: .completion) }
        guard checker.isMisspelled(partial, language: language) else { return completions }
        let guesses = checker.guesses(forWord: partial, language: language)
            .map { TypingSuggestion(text: $0, kind: .correction) }
        // Best guess and best completion first: "offi" should offer "office", not only five near-misses.
        return [TypingSuggestion(text: partial, kind: .verbatim)]
            + guesses.prefix(1) + completions.prefix(1) + guesses.dropFirst() + completions.dropFirst()
    }

    /// The checker's dictionary for the first language the keyboard can use, or nil when it has none. Asks an
    /// existing checker first, so a keyboard that never shows a word never makes one.
    private func resolvedLanguage() -> String? {
        let available = checker?.availableLanguages ?? resolvedChecker().availableLanguages
        return TypingLanguageResolver.resolve(candidates: languageCandidates(), available: available)
    }

    private func resolvedChecker() -> TypingSpellChecking {
        if let checker { return checker }
        let made = makeChecker()
        ignoredWords.forEach { made.ignore($0) }
        checker = made
        return made
    }

    /// Completions come back lowercase; follow the case the user is typing in.
    private func matchCase(_ candidate: String, to partial: String) -> String {
        guard let first = partial.first, first.isUppercase else { return candidate }
        if partial.count > 1, partial.allSatisfy({ !$0.isLowercase }) { return candidate.uppercased() }
        guard let candidateFirst = candidate.first, candidateFirst.isLowercase else { return candidate }
        return candidateFirst.uppercased() + candidate.dropFirst()
    }

    /// One entry per word, ignoring case, and never a completion that is just the typed word again.
    private func deduplicated(_ suggestions: [TypingSuggestion], partial: String) -> [TypingSuggestion] {
        var seen = Set<String>()
        return suggestions.filter { suggestion in
            if suggestion.kind != .verbatim, suggestion.text == partial { return false }
            return seen.insert(suggestion.text.lowercased()).inserted
        }
    }
}
