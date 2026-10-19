import Foundation

/// Decides whether the word the user just finished should be replaced, and with what. Apple gives custom
/// keyboards no autocorrect, so this is our own on `UITextChecker`, built to be conservative: a wrong
/// correction is worse than a missed one, so any doubt leaves the word alone.
///
/// In order, a finished word is left alone unless: autocorrect is on and the field allows it; the boundary is a
/// space, return or sentence punctuation; the word is the whole token (not part of a hashtag, handle, URL, email
/// or identifier); the user's own text replacement or contact list does not claim it; the language is English;
/// and then either the contraction table has it, or the checker flags it and has one clear, near guess.
@MainActor
final class TypingAutocorrector: TypingWordCompletionHandling {
    private let checker: () -> TypingSpellChecking
    private let languageCandidates: () -> [String]
    private let traits: () -> TypingTraits
    private let isEnabled: () -> Bool
    private let ignoreWord: (String) -> Void
    private let tuning: TypingAutocorrectTuning
    private let poolOptions: TypingCandidatePool.Options

    /// The user's contact names and shortcut inputs, lowercased. Kept apart from the strip's capped list so a
    /// contact past its cap is still never corrected.
    private var knownWords = Set<String>()
    private var replacements: [String: String] = [:]
    /// Words the user took back and words they keep typing as they are, kept across launches. The checker's own
    /// ignore list is per instance, so these are replayed into it.
    private var learned: TypingLearnedWords
    private let store: TypingLearnedWordsStoring?
    private let learnWord: (String) -> Void
    private let diagnostics: TypingAutocorrectDiagnostics?

    /// Only English has been measured, so only English is corrected.
    private static let correctedLanguage = "en"

    init(
        checker: @escaping () -> TypingSpellChecking,
        languageCandidates: @escaping () -> [String],
        traits: @escaping () -> TypingTraits,
        isEnabled: @escaping () -> Bool,
        ignoreWord: @escaping (String) -> Void = { _ in },
        tuning: TypingAutocorrectTuning = .standard,
        poolOptions: TypingCandidatePool.Options = .init(),
        learnedWords: TypingLearnedWordsStoring? = nil,
        learnWord: @escaping (String) -> Void = { _ in },
        diagnostics: TypingAutocorrectDiagnostics? = nil
    ) {
        self.diagnostics = diagnostics
        self.checker = checker
        self.languageCandidates = languageCandidates
        self.traits = traits
        self.isEnabled = isEnabled
        self.ignoreWord = ignoreWord
        self.tuning = tuning
        var options = poolOptions
        options.weights = tuning.weights
        options.usageDepth = tuning.usageDepth
        self.poolOptions = options
        store = learnedWords
        self.learnWord = learnWord
        learned = learnedWords?.load() ?? TypingLearnedWords()
        (learned.rejected + learned.learned).forEach(ignoreWord)
    }

    /// Contacts and text replacements from `UILexicon`. No cap here.
    func setLexicon(_ entries: [TypingLexiconEntry]) {
        var known = Set<String>()
        var shortcuts: [String: String] = [:]
        for entry in entries where !entry.userInput.isEmpty && !entry.documentText.isEmpty {
            let input = entry.userInput.lowercased()
            known.insert(input)
            guard entry.documentText.lowercased() != input else { continue }
            if shortcuts[input] == nil { shortcuts[input] = entry.documentText }
            entry.documentText.lowercased().split(whereSeparator: { !$0.isLetter }).forEach { known.insert(String($0)) }
        }
        knownWords = known
        replacements = shortcuts
    }

    /// Autocorrect would look at a finished word in this field right now.
    var isCorrecting: Bool { isEnabled() && isCorrectableField() }

    func replacementWasRejected(_ undo: TypingReplacementUndo) {
        learned.reject(undo.originalWord)
        store?.save(learned)
        ignoreWord(undo.originalWord)
    }

    func wordCompleted(_ event: TypingWordCompletedEvent) -> TypingEditPlan? {
        guard isEnabled(), isCorrectableField(), let boundary = Boundary(event.boundary) else { return nil }
        let word = event.word
        guard TypingTokenContext.isStandaloneWord(word, contextBefore: event.contextBefore) else { return nil }
        guard !learned.isRejected(word) else { return declined(.rejectedWord, word, boundary) }
        guard !learned.isLearned(word) else { return declined(.learnedWord, word, boundary) }
        if boundary.expandsShortcuts, let expansion = replacements[word.lowercased()] {
            return plan(replacing: word, with: expansion, boundary: boundary)
        }
        guard !knownWords.contains(word.lowercased()) else { return nil }
        guard let language = resolvedLanguage(), TypingLanguageResolver.baseCode(of: language) == Self.correctedLanguage
        else { return declined(.languageUnsupported, word, boundary) }
        if let fixed = TypingContractions.correction(for: word, strict: boundary.isStrict) {
            return plan(replacing: word, with: fixed, boundary: boundary)
        }
        guard let fixed = spellCorrection(for: word, language: language, event: event, boundary: boundary) else { return nil }
        return plan(replacing: word, with: fixed, boundary: boundary)
    }

    // MARK: Internals

    private func spellCorrection(
        for word: String, language: String, event: TypingWordCompletedEvent, boundary: Boundary
    ) -> String? {
        guard TypingTokenContext.hasCorrectableShape(word) else { return nil }
        let capitalized = word.first?.isUppercase == true
        // A capital in the middle of a sentence is a name; at the start of one it is auto-capitalize.
        if capitalized, !TypingTokenContext.startsSentence(word: word, contextBefore: event.contextBefore) { return nil }
        let checker = checker()
        guard checker.isMisspelled(word, language: language) else { return nil }
        let pool = TypingCandidatePool(checker: checker, language: language, options: poolOptions)
        let candidates = pool.candidates(for: word, excluding: Set(learned.rejected))
        let decision = TypingAutocorrectRule.decision(
            for: word, candidates: candidates, strict: boundary.isStrict, tuning: tuning
        )
        guard case .correct(let guess) = decision else {
            if case .declined(let reason) = decision {
                noteDeclined(reason, word, boundary, candidates: candidates, checker: checker, language: language)
            }
            noteLeftAsTyped(word)
            return nil
        }
        guard capitalized else { return guess }
        return guess.prefix(1).uppercased() + guess.dropFirst()
    }

    /// Tells diagnostics a word was left alone. For a decline on score or margin it also looks up the completions
    /// under the same prefixes the candidate pool reads usage from (each looked-up candidate's first one to
    /// `usageDepth` letters): all of them empty means no guess could be shown to be a used word.
    private func noteDeclined(
        _ reason: TypingDeclineReason, _ word: String, _ boundary: Boundary, candidates: [TypingCandidate],
        checker: TypingSpellChecking, language: String
    ) {
        guard let diagnostics else { return }
        var prefixes = Set<String>()
        for candidate in candidates where !candidate.usage.isEmpty {
            for length in 1...candidate.usage.count { prefixes.insert(String(candidate.word.prefix(length))) }
        }
        if prefixes.isEmpty { prefixes.insert(String(word.prefix(1)).lowercased()) }
        let empty = prefixes.allSatisfy { checker.completions(forPartial: $0, language: language).isEmpty }
        let scoreBound = reason == .maxScore || reason == .margin
        report(empty && scoreBound ? .usageUnavailable : reason, word, boundary, completionsEmpty: empty, to: diagnostics)
    }

    private func declined(_ reason: TypingDeclineReason, _ word: String, _ boundary: Boundary) -> TypingEditPlan? {
        if let diagnostics { report(reason, word, boundary, completionsEmpty: nil, to: diagnostics) }
        return nil
    }

    private func report(
        _ reason: TypingDeclineReason, _ word: String, _ boundary: Boundary, completionsEmpty: Bool?,
        to diagnostics: TypingAutocorrectDiagnostics
    ) {
        diagnostics.note(TypingAutocorrectDiagnostic(
            reason: reason, boundary: boundary.name, wordLength: word.count, completionsEmpty: completionsEmpty,
            traits: traits()
        ))
    }

    /// A word the checker flags was typed and left alone. The third time, the user clearly means it: the checker
    /// is told to stop flagging it, here and in the system's learned words, and it is never corrected again.
    private func noteLeftAsTyped(_ word: String) {
        let becameLearned = learned.noteLeftAsTyped(word)
        store?.save(learned)
        guard becameLearned else { return }
        ignoreWord(word)
        learnWord(word)
    }

    private func plan(replacing word: String, with fixed: String, boundary: Boundary) -> TypingEditPlan {
        TypingEditPlan(
            deleteCount: word.count,
            insertText: fixed,
            expectedSuffix: word,
            undo: TypingReplacementUndo(
                replacedText: word + boundary.text, insertedText: fixed + boundary.text, originalWord: word
            )
        )
    }

    private func isCorrectableField() -> Bool {
        let traits = traits()
        return traits.allowsSuggestions && traits.variant == .standard
    }

    private func resolvedLanguage() -> String? {
        TypingLanguageResolver.resolve(candidates: languageCandidates(), available: checker().availableLanguages)
    }

    /// What ended the word, reduced to what autocorrect cares about.
    private struct Boundary {
        let source: TypingBoundary
        let text: String
        let expandsShortcuts: Bool
        /// Before a "." or ":" the word may be the start of a host name or a URL scheme.
        let isStrict: Bool

        /// For diagnostics: "space", "punctuation" or "return".
        var name: String { source.name }

        private static let sentenceMarks: Set<String> = [".", ",", "!", "?", ";", ":"]

        init?(_ boundary: TypingBoundary) {
            source = boundary
            switch boundary {
            case .space:
                (text, expandsShortcuts, isStrict) = (" ", true, false)
            case .returnKey:
                (text, expandsShortcuts, isStrict) = ("\n", false, false)
            case .punctuation(let mark):
                guard Self.sentenceMarks.contains(mark) else { return nil }
                (text, expandsShortcuts, isStrict) = (mark, false, mark == "." || mark == ":")
            }
        }
    }
}
