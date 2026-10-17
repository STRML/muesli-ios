import UIKit

/// `UITextChecker` behind the package's protocol. One instance per document (the suggestion builder drops it when
/// the document changes) and none until a word is on screen.
@MainActor
final class UITextCheckerAdapter: TypingSpellChecking {
    private let checker = UITextChecker()

    var availableLanguages: [String] { UITextChecker.availableLanguages }

    func isMisspelled(_ word: String, language: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let found = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
        return found.location != NSNotFound
    }

    func completions(forPartial partial: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (partial as NSString).length)
        return checker.completions(forPartialWordRange: range, in: partial, language: language) ?? []
    }

    func ignore(_ word: String) {
        checker.ignoreWord(word)
    }

    func guesses(forWord word: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(forWordRange: range, in: word, language: language) ?? []
    }
}

/// The two `UITextChecker` selectors the warm-up sends. UIKit marks the class main-actor although it holds no UI
/// state, and the warm-up must not run on the main actor, so it messages the same selectors through this protocol.
@objc private protocol BackgroundTextChecking {
    @objc(completionsForPartialWordRange:inString:language:)
    func completions(forPartialWordRange range: NSRange, in string: String, language: String?) -> [String]?
    @objc(guessesForWordRange:inString:language:)
    func guesses(forWordRange range: NSRange, in string: String, language: String?) -> [String]?
}

/// A checker for the background warm-up. Its own `UITextChecker`, made and used only on the warm-up queue, so no
/// lookup here can race the main-actor checker the keyboard types with. The language data it loads is shared by
/// the whole process.
nonisolated final class UITextCheckerWarmer: TypingCheckerWarming {
    private nonisolated(unsafe) let checker: BackgroundTextChecking =
        unsafeBitCast((UITextChecker.self as NSObject.Type).init(), to: BackgroundTextChecking.self)

    var availableLanguages: [String] { UITextChecker.availableLanguages }

    func completions(forPartial partial: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (partial as NSString).length)
        return checker.completions(forPartialWordRange: range, in: partial, language: language) ?? []
    }

    func guesses(forWord word: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(forWordRange: range, in: word, language: language) ?? []
    }
}
