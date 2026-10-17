import Foundation
import Observation
import UIKit

/// The host field as the typing engine reads and edits it. Reads come from the text document proxy; edits go
/// through the controller so typing keeps retiring an Undo edit and the inserted-count bookkeeping.
@MainActor
final class KeyboardTypingDocument: TypingDocument {
    var beforeReader: @MainActor () -> String? = { nil }
    var afterReader: @MainActor () -> String? = { nil }
    var identifierReader: @MainActor () -> UUID? = { nil }
    var selectionReader: @MainActor () -> String? = { nil }
    var inserter: @MainActor (String) -> Void = { _ in }
    var backspacer: @MainActor () -> Void = {}

    var contextBefore: String? { beforeReader() }
    var contextAfter: String? { afterReader() }
    var documentIdentifier: UUID? { identifierReader() }
    var selectedText: String? { selectionReader() }
    func insert(_ text: String) { inserter(text) }
    func deleteBackward() { backspacer() }
}

@MainActor
private final class TypingLanguageSource {
    var documentLanguage: String?

    var candidates: [String] {
        (documentLanguage.map { [$0] } ?? []) + Locale.preferredLanguages
    }
}

@MainActor
private final class AutocorrectSwitch {
    var isOn = true
}

/// What the Type page shows and does. A thin Observable shell over `TypingEngine`, which holds the logic.
@MainActor
@Observable
final class KeyboardTypingModel {
    private(set) var state = TypingState()
    /// Apple asks keyboards to show a globe only when `needsInputModeSwitchKey` says the system draws none; Sam
    /// asked for the key always, so this stays true. One place to change that.
    var showsGlobe = true
    /// The Autocorrect switch in Settings, as the shared store last said. On until told otherwise.
    var autocorrectEnabled: Bool {
        get { autocorrectSwitch.isOn }
        set { autocorrectSwitch.isOn = newValue }
    }

    @ObservationIgnored let document = KeyboardTypingDocument()
    @ObservationIgnored private let builder: TypingSuggestionBuilder
    @ObservationIgnored private let autocorrector: TypingAutocorrector
    @ObservationIgnored private(set) var engine: TypingEngine!
    @ObservationIgnored private var hasRequestedLexicon = false
    @ObservationIgnored private let languageSource = TypingLanguageSource()
    @ObservationIgnored private let autocorrectSwitch = AutocorrectSwitch()

    init() {
        let languages = languageSource
        let autocorrectSwitch = autocorrectSwitch
        builder = TypingSuggestionBuilder(
            makeChecker: { UITextCheckerAdapter() },
            languageCandidates: { languages.candidates }
        )
        let builder = builder
        let engine = TypingEngine(
            document: document,
            suggestionSource: builder,
            now: { ProcessInfo.processInfo.systemUptime }
        )
        autocorrector = TypingAutocorrector(
            checker: { builder.currentChecker() },
            languageCandidates: { languages.candidates },
            traits: { [weak engine] in engine?.state.traits ?? TypingTraits() },
            isEnabled: { autocorrectSwitch.isOn },
            ignoreWord: { builder.ignore($0) }
        )
        engine.completionHandler = autocorrector
        engine.onChange = { [weak self] in self?.state = $0 }
        self.engine = engine
        state = engine.state
    }

    /// The document's input mode when the host exposes one (the keyboard's own language, in practice), then the
    /// user's preferred languages. A language the checker has no dictionary for gives an empty strip.
    func setDocumentLanguage(_ language: String?) {
        languageSource.documentLanguage = language
    }

    /// Re-read the host's traits and refresh the engine. Called when the keyboard appears and whenever the host's
    /// text or selection changes, because traits can arrive late or change when focus moves to another field.
    func hostDidChange(traits: UITextInputTraits) {
        engine.apply(traits: TypingTraits(traits))
    }

    /// Contacts and the user's text replacements. Apple documents this as available to every custom keyboard,
    /// Full Access or not; if it returns nothing the strip simply has no lexicon entries.
    func loadLexicon(from controller: UIInputViewController) {
        guard !hasRequestedLexicon else { return }
        hasRequestedLexicon = true
        // UIKit does not say which queue calls this back. `@Sendable` keeps the closure from inheriting this
        // type's main-actor isolation, which Swift 6 would enforce at runtime with a trap on any other queue.
        controller.requestSupplementaryLexicon { @Sendable [weak self] lexicon in
            let entries = lexicon.entries.map {
                TypingLexiconEntry(userInput: $0.userInput, documentText: $0.documentText)
            }
            Task { @MainActor in
                self?.setLexicon(entries)
            }
        }
    }

    /// The strip gets a capped copy; the autocorrector keeps every entry so no contact is ever "corrected".
    func setLexicon(_ entries: [TypingLexiconEntry]) {
        builder.setLexicon(entries)
        autocorrector.setLexicon(entries)
        engine.documentDidChange()
    }

    /// Drop the checker and lexicon when the keyboard goes away or memory is tight.
    func releaseMemory() {
        builder.documentDidChange()
        builder.setLexicon([])
        autocorrector.setLexicon([])
        hasRequestedLexicon = false
    }

    // MARK: Taps from the key views

    func perform(_ action: TypingKeyAction) {
        switch action {
        case .character(let text): engine.type(text)
        case .space: engine.tapSpace()
        case .returnKey: engine.tapReturn()
        case .backspace: engine.tapBackspace()
        case .shift: engine.tapShift()
        case .switchPage(let page): engine.switchPage(page)
        case .globe, .record, .spacer: break
        }
    }

    func accept(_ suggestion: TypingSuggestion) {
        engine.accept(suggestion)
    }

    func setSuggestionsSuspended(_ suspended: Bool) {
        engine.setSuggestionsSuspended(suspended)
    }
}
