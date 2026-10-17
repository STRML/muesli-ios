import Foundation

/// Why autocorrect left a word alone (or never looked at it). The raw values are the closed `decline_reason`
/// list in `DiagnosticsVocabulary`; add one in both places and in docs/diagnostics-shipping.md.
enum TypingDeclineReason: String, CaseIterable, Sendable {
    // The rule (`TypingAutocorrectRule.Decision`).
    /// The checker offered no guess at all.
    case noGuesses = "no_guesses"
    /// Every guess differs from the typed word by more than two letters in length.
    case lengthDiff = "length_diff"
    /// Every guess costs more than the typed word's length allows.
    case budget
    /// A three-letter word only takes a swap of two letters that makes a used word.
    case shortWord = "short_word"
    /// The best guess scores above the cap.
    case maxScore = "max_score"
    /// The best guess does not beat the runner-up by enough.
    case margin
    /// Before a "." or ":" only a single edit is accepted.
    case strictEdit = "strict_edit"
    // Around the rule.
    /// The rule declined on score or margin and the checker's completions came back empty, so no guess could
    /// be shown to be a used word.
    case usageUnavailable = "usage_unavailable"
    /// The user took this word back before.
    case rejectedWord = "rejected_word"
    /// The user keeps typing this word as it is.
    case learnedWord = "learned_word"
    /// No dictionary for the keyboard's language, or not English.
    case languageUnsupported = "language_unsupported"
    // The engine and the field.
    /// The proxy's text before the cursor did not end with the word the keyboard typed.
    case proxyMismatch = "proxy_mismatch"
    /// The field's traits turn autocorrect off (no suggestions, secure, URL or email or numeric keyboard).
    case traitsGate = "traits_gate"
}

/// One decision that did not correct. Lengths and flags only: never the word, a guess, or any text.
struct TypingAutocorrectDiagnostic: Equatable, Sendable {
    var reason: TypingDeclineReason
    var boundary: String?
    var wordLength: Int?
    var completionsEmpty: Bool?
    var traits: TypingTraits

    static func boundaryName(_ boundary: TypingBoundary) -> String {
        switch boundary {
        case .space: "space"
        case .punctuation: "punctuation"
        case .returnKey: "return"
        }
    }

    static func variantName(_ variant: TypingKeyboardVariant) -> String {
        switch variant {
        case .standard: "standard"
        case .email: "email"
        case .url: "url"
        case .numeric: "numeric"
        }
    }
}

/// Writes autocorrect declines to the keyboard diagnostics log without flooding it. The log keeps 600 lines, so
/// each distinct decline (reason, boundary, field variant, field flags) is written the 1st, 2nd, 4th, 8th...
/// time it happens, carrying its running count: typing all day costs a few lines per kind, and the count says
/// how often. The counts live as long as the keyboard process; `keyboard.appeared` lines in the log mark where
/// a keyboard session began.
@MainActor
final class TypingAutocorrectDiagnostics {
    static let eventName = "autocorrect.declined"

    private let record: @MainActor (String, [String: String]) -> Void
    private var counts: [String: Int] = [:]

    init(record: @escaping @MainActor (String, [String: String]) -> Void) {
        self.record = record
    }

    func note(_ diagnostic: TypingAutocorrectDiagnostic) {
        var attrs = ["decline_reason": diagnostic.reason.rawValue]
        attrs["boundary"] = diagnostic.boundary
        attrs["completions_empty"] = diagnostic.completionsEmpty.map { $0 ? "true" : "false" }
        attrs["field_variant"] = TypingAutocorrectDiagnostic.variantName(diagnostic.traits.variant)
        attrs["suggestions_off"] = diagnostic.traits.suggestionsDisabled ? "true" : "false"
        attrs["secure"] = diagnostic.traits.isSecure ? "true" : "false"
        // The word's length varies word to word; it is reported but does not split the count.
        let key = attrs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        attrs["word_len"] = diagnostic.wordLength.map(String.init)
        let count = counts[key, default: 0] + 1
        counts[key] = count
        guard count & (count - 1) == 0 else { return }
        attrs["count"] = String(count)
        record(Self.eventName, attrs)
    }
}
