import Foundation

/// The host text field, as the engine sees it. The keyboard wraps `UITextDocumentProxy`; tests use a fake.
@MainActor
protocol TypingDocument: AnyObject {
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    var documentIdentifier: UUID? { get }
    func insert(_ text: String)
    func deleteBackward()
}

enum TypingBoundary: Sendable, Equatable {
    case space
    case punctuation(String)
    case returnKey
}

/// A word just ended. This is the phase 2 autocorrect hook: the word, what ended it, and the document it is in.
struct TypingWordCompletedEvent: Sendable, Equatable {
    let word: String
    let boundary: TypingBoundary
    let contextBefore: String?
    let documentIdentifier: UUID?
}

@MainActor
protocol TypingWordCompletionHandling: AnyObject {
    /// Return a plan to replace the word before the boundary is typed, or nil to leave it alone. A plan that
    /// carries `undo` is taken back by the next backspace.
    func wordCompleted(_ event: TypingWordCompletedEvent) -> TypingEditPlan?
}

struct TypingState: Sendable, Equatable {
    var page: TypingPage = .letters
    var shift: TypingShiftState = .off
    var traits = TypingTraits()
    var suggestions: [TypingSuggestion] = []
    /// Dimmed, never disabled: a host that hides its text from us must still be able to send.
    var isReturnEnabled = true

    /// What the letter keys show: shifted, caps-locked, or a field that wants every character capitalized.
    var isUppercase: Bool { shift != .off || traits.autocapitalization == .allCharacters }
}

/// Turns key taps into edits on the host document and keeps the shift state, page and suggestion strip current.
/// It reads the document only through `TypingDocument`, never reads a secure field, and reports each finished
/// word to `completionHandler` so autocorrect can be added without changing the key handling.
@MainActor
final class TypingEngine {
    private let document: TypingDocument
    private let suggestionSource: TypingSuggestionSource
    private let now: @MainActor () -> TimeInterval

    private(set) var state = TypingState()
    /// What `onChange` last heard. `state` is edited in place before a refresh, so change detection compares
    /// against this, not against `state`.
    private var published = TypingState()
    var onChange: (@MainActor (TypingState) -> Void)?
    var completionHandler: TypingWordCompletionHandling?

    private var machine = TypingShiftMachine()
    private var hasAppliedTraits = false
    private var suggestionsSuspended = false
    private var pendingUndo: TypingReplacementUndo?
    private var lastAutocapKey: AutocapKey?
    private var knownDocumentID: UUID?
    private var snapshot: SuggestionSnapshot?

    private struct AutocapKey: Equatable {
        let mode: TypingAutocapitalization
        let before: String
    }

    private struct SuggestionSnapshot {
        let partial: String
        let documentIdentifier: UUID?
    }

    init(
        document: TypingDocument,
        suggestionSource: TypingSuggestionSource,
        now: @escaping @MainActor () -> TimeInterval
    ) {
        self.document = document
        self.suggestionSource = suggestionSource
        self.now = now
    }

    // MARK: Inputs from the host

    /// Traits are re-read whenever the host's text changes, and can arrive late; this is safe to call at any time.
    func apply(traits: TypingTraits) {
        let changed = !hasAppliedTraits || state.traits != traits
        let variantChanged = !hasAppliedTraits || state.traits.variant != traits.variant
        hasAppliedTraits = true
        state.traits = traits
        if variantChanged { state.page = traits.initialPage }
        // The host echoes the same traits after every keystroke; only a real change re-evaluates auto-capitalize.
        if changed { lastAutocapKey = nil }
        refresh()
    }

    /// The host's text or selection changed (the user moved the cursor, a dictation was inserted, a paste).
    func documentDidChange() {
        refresh()
    }

    /// While a dictation owns the strip, no suggestion is computed or tappable.
    func setSuggestionsSuspended(_ suspended: Bool) {
        suggestionsSuspended = suspended
        refresh()
    }

    // MARK: Key taps

    func type(_ text: String) {
        pendingUndo = nil
        if let character = text.first, text.count == 1, TypingWordExtractor.endsWord(character) {
            completeWord(boundary: .punctuation(text))
        }
        document.insert(text)
        machine.didInsertCharacter()
        refresh()
    }

    func tapSpace() {
        pendingUndo = nil
        completeWord(boundary: .space)
        document.insert(" ")
        machine.didInsertCharacter()
        refresh()
    }

    func tapReturn() {
        pendingUndo = nil
        completeWord(boundary: .returnKey)
        document.insert("\n")
        machine.didInsertCharacter()
        refresh()
    }

    func tapBackspace() {
        if let undo = pendingUndo, document.contextBefore?.hasSuffix(undo.insertedText) == true {
            pendingUndo = nil
            for _ in 0..<undo.insertedText.count { document.deleteBackward() }
            document.insert(undo.replacedText)
            refresh()
            return
        }
        pendingUndo = nil
        // Always forwarded, even when the context looks empty: some hosts never show their text to a keyboard.
        document.deleteBackward()
        refresh()
    }

    func tapShift() {
        guard state.traits.autocapitalization != .allCharacters else { return }
        machine.tapShift(at: now())
        refresh()
    }

    func switchPage(_ page: TypingPage) {
        state.page = page
        lastAutocapKey = nil
        refresh()
    }

    /// Replace the partial word with a tapped suggestion, only if the document is still exactly what the
    /// suggestion was computed for.
    @discardableResult
    func accept(_ suggestion: TypingSuggestion) -> Bool {
        guard !suggestionsSuspended, state.traits.allowsSuggestions,
              let snapshot, state.suggestions.contains(suggestion),
              snapshot.documentIdentifier == document.documentIdentifier
        else { return false }
        let before = document.contextBefore
        let after = document.contextAfter
        guard case .partial(let current) = TypingWordExtractor.word(before: before, after: after),
              current == snapshot.partial
        else {
            refresh()
            return false
        }
        let plan = TypingEditPlan.replaceWord(partial: current, with: suggestion.text, contextAfter: after)
        guard plan.isApplicable(toContextBefore: before) else {
            refresh()
            return false
        }
        pendingUndo = nil
        apply(plan)
        refresh()
        return true
    }

    // MARK: Internals

    private func apply(_ plan: TypingEditPlan) {
        for _ in 0..<plan.deleteCount { document.deleteBackward() }
        if !plan.insertText.isEmpty { document.insert(plan.insertText) }
    }

    /// Reports the word that ends at the cursor, and applies the handler's replacement if it is still valid.
    private func completeWord(boundary: TypingBoundary) {
        guard let completionHandler, state.traits.allowsSuggestions else { return }
        let before = document.contextBefore
        guard case .partial(let word) = TypingWordExtractor.word(before: before, after: document.contextAfter) else { return }
        let event = TypingWordCompletedEvent(
            word: word, boundary: boundary, contextBefore: before, documentIdentifier: document.documentIdentifier
        )
        guard let plan = completionHandler.wordCompleted(event),
              plan.isApplicable(toContextBefore: document.contextBefore)
        else { return }
        apply(plan)
        pendingUndo = plan.undo
    }

    private func refresh() {
        let traits = state.traits
        noteDocumentIdentity()
        guard !traits.isSecure else {
            // A secure field is never read. iOS shows the system keyboard there; this only guards late traits.
            snapshot = nil
            publish(suggestions: [], isReturnEnabled: true)
            return
        }

        let before = document.contextBefore
        updateAutocapitalization(before: before)

        var suggestions: [TypingSuggestion] = []
        snapshot = nil
        if traits.allowsSuggestions, !suggestionsSuspended {
            let word = TypingWordExtractor.word(before: before, after: document.contextAfter)
            if case .partial(let partial) = word {
                suggestions = suggestionSource.suggestions(forPartial: partial)
                snapshot = SuggestionSnapshot(partial: partial, documentIdentifier: document.documentIdentifier)
            }
        }
        publish(suggestions: suggestions, isReturnEnabled: returnIsEnabled(before: before))
    }

    private func noteDocumentIdentity() {
        let identifier = document.documentIdentifier
        if let known = knownDocumentID, known != identifier {
            suggestionSource.documentDidChange()
            pendingUndo = nil
            lastAutocapKey = nil
        }
        knownDocumentID = identifier
    }

    /// Only when the text before the cursor (or the field's mode) changed, so a shift the user cancelled is not
    /// re-armed by the host echoing the same text back.
    private func updateAutocapitalization(before: String?) {
        let mode = state.traits.autocapitalization
        let key = AutocapKey(mode: mode, before: before ?? "")
        guard key != lastAutocapKey else { return }
        lastAutocapKey = key
        guard mode != .allCharacters else { return }
        machine.autoCapitalize(TypingAutocapitalizationPolicy.capitalizesNext(mode: mode, before: before))
    }

    private func returnIsEnabled(before: String?) -> Bool {
        guard state.traits.enablesReturnKeyAutomatically else { return true }
        if let before, !before.isEmpty { return true }
        return !(document.contextAfter ?? "").isEmpty
    }

    private func publish(suggestions: [TypingSuggestion], isReturnEnabled: Bool) {
        var next = state
        next.shift = machine.state
        next.suggestions = suggestions
        next.isReturnEnabled = isReturnEnabled
        state = next
        guard next != published else { return }
        published = next
        onChange?(next)
    }
}
