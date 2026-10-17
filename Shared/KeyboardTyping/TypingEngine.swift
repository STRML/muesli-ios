import Foundation

/// The host text field, as the engine sees it. The keyboard wraps `UITextDocumentProxy`; tests use a fake.
@MainActor
protocol TypingDocument: AnyObject {
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    var documentIdentifier: UUID? { get }
    /// The selected text, if any. A typed space replaces a selection, so nothing is corrected then.
    var selectedText: String? { get }
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
    /// The user took a replacement back (backspace, or a tap on the original in the strip).
    func replacementWasRejected(_ undo: TypingReplacementUndo)
}

extension TypingWordCompletionHandling {
    func replacementWasRejected(_ undo: TypingReplacementUndo) {}
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
    /// The text after the cursor when the correction was made; the undo is only valid while it still matches.
    private var undoContextAfter = ""
    /// The letters typed through `type` since the last boundary. A finished word is only reported when it is
    /// exactly this, so text Muesli inserted (a dictation), text pasted, a word the cursor was merely placed
    /// after, and a keystroke the proxy has not shown yet are never corrected.
    private var typedWord = ""
    private var lastAutocapKey: AutocapKey?
    private var knownDocumentID: UUID?
    private var snapshot: SuggestionSnapshot?
    /// The word the user finished by typing a space, punctuation or return, until the next keystroke or edit
    /// changes the context. The strip offers alternatives for it while the cursor is still right after it.
    private var completedWord: CompletedWord?

    private struct AutocapKey: Equatable {
        let mode: TypingAutocapitalization
        let before: String
    }

    private struct CompletedWord: Equatable {
        let word: String
        /// What ended it: a space, one punctuation mark or a line break.
        let boundary: String
        var text: String { word + boundary }
    }

    private struct SuggestionSnapshot {
        enum Target {
            case partial(String)
            case completed(CompletedWord)
        }

        let target: Target
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
        syncWithHost()
        refresh()
    }

    /// The host's text or selection changed (the user moved the cursor, a dictation was inserted, a paste).
    func documentDidChange() {
        syncWithHost()
        refresh()
    }

    /// While a dictation owns the strip, no suggestion is computed or tappable.
    func setSuggestionsSuspended(_ suspended: Bool) {
        suggestionsSuspended = suspended
        if suspended { pendingUndo = nil }
        refresh()
    }

    /// Muesli itself put text in the field (a dictation, a rewrite, an Undo edit). Nothing typed before it is
    /// a pending correction, and nothing in it is ever corrected.
    func noteExternalInsertion() {
        pendingUndo = nil
        completedWord = nil
        typedWord = ""
        refresh()
    }

    // MARK: Key taps

    func type(_ text: String) {
        pendingUndo = nil
        completedWord = nil
        if let character = text.first, text.count == 1, TypingWordExtractor.endsWord(character) {
            rememberCompletedWord(boundary: text)
            completeWord(boundary: .punctuation(text))
            typedWord = ""
        } else {
            typedWord = text.count == 1 ? typedWord + text : ""
        }
        document.insert(text)
        machine.didInsertCharacter()
        refresh()
    }

    func tapSpace() {
        pendingUndo = nil
        rememberCompletedWord(boundary: " ")
        completeWord(boundary: .space)
        typedWord = ""
        document.insert(" ")
        machine.didInsertCharacter()
        refresh()
    }

    func tapReturn() {
        pendingUndo = nil
        rememberCompletedWord(boundary: "\n")
        completeWord(boundary: .returnKey)
        typedWord = ""
        document.insert("\n")
        machine.didInsertCharacter()
        refresh()
    }

    func tapBackspace() {
        let hasSelection = !(document.selectedText ?? "").isEmpty
        if let undo = pendingUndo, !hasSelection, isUndoLive(undo) {
            restore(undo)
            refresh()
            return
        }
        pendingUndo = nil
        completedWord = nil
        if hasSelection { typedWord = "" } else if !typedWord.isEmpty { typedWord.removeLast() }
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
        pendingUndo = nil
        state.page = page
        lastAutocapKey = nil
        refresh()
    }

    /// Replace the partial word with a tapped suggestion, only if the document is still exactly what the
    /// suggestion was computed for.
    @discardableResult
    func accept(_ suggestion: TypingSuggestion) -> Bool {
        if suggestion.kind == .original { return acceptOriginal(suggestion) }
        guard !suggestionsSuspended, state.traits.allowsSuggestions,
              let snapshot, state.suggestions.contains(suggestion),
              snapshot.documentIdentifier == document.documentIdentifier
        else { return false }
        switch snapshot.target {
        case .partial(let partial): return acceptCompletion(suggestion, partial: partial)
        case .completed(let completed): return acceptCorrection(suggestion, for: completed)
        }
    }

    private func acceptCompletion(_ suggestion: TypingSuggestion, partial: String) -> Bool {
        let before = document.contextBefore
        let after = document.contextAfter
        guard case .partial(let current) = TypingWordExtractor.word(before: before, after: after),
              current == partial
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
        completedWord = nil
        typedWord = ""
        apply(plan)
        refresh()
        return true
    }

    /// An alternative for the word just finished: swap it in, keep the space or punctuation after it, and make it
    /// the same one-backspace undo an autocorrect is.
    private func acceptCorrection(_ suggestion: TypingSuggestion, for completed: CompletedWord) -> Bool {
        let before = document.contextBefore
        let replacement = suggestion.text + completed.boundary
        let plan = TypingEditPlan(
            deleteCount: completed.text.count,
            insertText: replacement,
            expectedSuffix: completed.text,
            undo: TypingReplacementUndo(
                replacedText: completed.text, insertedText: replacement, originalWord: completed.word
            )
        )
        guard (document.selectedText ?? "").isEmpty, plan.isApplicable(toContextBefore: before) else {
            refresh()
            return false
        }
        undoContextAfter = document.contextAfter ?? ""
        completedWord = nil
        typedWord = ""
        apply(plan)
        pendingUndo = plan.undo
        refresh()
        return true
    }

    /// The quoted original in the strip, right after a correction: puts back what the user typed, the same as a
    /// backspace would, only if the document still ends with the correction.
    private func acceptOriginal(_ suggestion: TypingSuggestion) -> Bool {
        guard !suggestionsSuspended, state.traits.allowsSuggestions,
              let undo = pendingUndo, undo.originalWord == suggestion.text, isUndoLive(undo)
        else {
            refresh()
            return false
        }
        restore(undo)
        refresh()
        return true
    }

    // MARK: Internals

    private func restore(_ undo: TypingReplacementUndo) {
        pendingUndo = nil
        // The user insisted on the word as typed; the strip does not argue.
        completedWord = nil
        typedWord = ""
        for _ in 0..<undo.insertedText.count { document.deleteBackward() }
        document.insert(undo.replacedText)
        completionHandler?.replacementWasRejected(undo)
    }

    /// The correction is still the last thing in the document, with the same text after the cursor. Anything
    /// else (the cursor moved, the host changed the text, the proxy has not caught up) retires the undo, which
    /// errs on the side of a plain backspace.
    private func isUndoLive(_ undo: TypingReplacementUndo) -> Bool {
        guard document.contextBefore?.hasSuffix(undo.insertedText) == true else { return false }
        return (document.contextAfter ?? "") == undoContextAfter
    }

    /// Called when the host reports a change. The shadow of what was typed has to agree with the proxy, and a
    /// pending undo has to still be where it was.
    private func syncWithHost() {
        guard !state.traits.isSecure else {
            // A secure field is never read.
            typedWord = ""
            completedWord = nil
            pendingUndo = nil
            return
        }
        if case .partial(let word) = TypingWordExtractor.word(before: document.contextBefore, after: document.contextAfter),
           word == TypingWordExtractor.withoutLeadingJoiners(typedWord) {
            // Still agrees with what was typed.
        } else {
            typedWord = ""
        }
        if let undo = pendingUndo, !isUndoLive(undo) { pendingUndo = nil }
    }

    private func apply(_ plan: TypingEditPlan) {
        for _ in 0..<plan.deleteCount { document.deleteBackward() }
        if !plan.insertText.isEmpty { document.insert(plan.insertText) }
    }

    /// Reports the word that ends at the cursor, and applies the handler's replacement if it is still valid.
    private func completeWord(boundary: TypingBoundary) {
        guard let completionHandler, state.traits.allowsSuggestions, !suggestionsSuspended,
              (document.selectedText ?? "").isEmpty
        else { return }
        let before = document.contextBefore
        let after = document.contextAfter
        // Only a word typed here, and seen by the proxy exactly as typed.
        guard case .partial(let word) = TypingWordExtractor.word(before: before, after: after), word == TypingWordExtractor.withoutLeadingJoiners(typedWord) else { return }
        let event = TypingWordCompletedEvent(
            word: word, boundary: boundary, contextBefore: before, documentIdentifier: document.documentIdentifier
        )
        guard let plan = completionHandler.wordCompleted(event),
              plan.isApplicable(toContextBefore: document.contextBefore)
        else { return }
        undoContextAfter = after ?? ""
        apply(plan)
        pendingUndo = plan.undo
    }

    /// Notes the word typed here that a boundary is about to end, for the strip. Whether the document really
    /// ends with it is checked when the strip is built, so a proxy that lags only delays the alternatives.
    private func rememberCompletedWord(boundary: String) {
        completedWord = nil
        let word = TypingWordExtractor.withoutLeadingJoiners(typedWord)
        guard TypingTokenContext.isSuggestibleShape(word) else { return }
        completedWord = CompletedWord(word: word, boundary: boundary)
    }

    /// The finished word the cursor is still right after, if the strip may judge it: typed here, the whole token,
    /// and not a name in the middle of a sentence.
    private func completedWordBeforeCursor(before: String?) -> CompletedWord? {
        guard let completed = completedWord, (document.selectedText ?? "").isEmpty,
              let before, before.hasSuffix(completed.text)
        else { return nil }
        let wordEnd = String(before.dropLast(completed.boundary.count))
        guard TypingTokenContext.isStandaloneWord(completed.word, contextBefore: wordEnd) else { return nil }
        if completed.word.first?.isUppercase == true,
           !TypingTokenContext.startsSentence(word: completed.word, contextBefore: wordEnd) { return nil }
        return completed
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
        if traits.allowsSuggestions, !suggestionsSuspended, let undo = pendingUndo {
            // Right after a correction there is no partial word; the strip offers the original, in quotes.
            suggestions = [TypingSuggestion(text: undo.originalWord, kind: .original)]
        } else if traits.allowsSuggestions, !suggestionsSuspended {
            let word = TypingWordExtractor.word(before: before, after: document.contextAfter)
            if case .partial(let partial) = word {
                suggestions = suggestionSource.suggestions(forPartial: partial)
                snapshot = SuggestionSnapshot(target: .partial(partial), documentIdentifier: document.documentIdentifier)
            } else if let completed = completedWordBeforeCursor(before: before) {
                suggestions = suggestionSource.corrections(forCompletedWord: completed.word)
                if !suggestions.isEmpty {
                    snapshot = SuggestionSnapshot(target: .completed(completed), documentIdentifier: document.documentIdentifier)
                }
            }
        }
        publish(suggestions: suggestions, isReturnEnabled: returnIsEnabled(before: before))
    }

    private func noteDocumentIdentity() {
        let identifier = document.documentIdentifier
        if let known = knownDocumentID, known != identifier {
            suggestionSource.documentDidChange()
            pendingUndo = nil
            completedWord = nil
            typedWord = ""
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
