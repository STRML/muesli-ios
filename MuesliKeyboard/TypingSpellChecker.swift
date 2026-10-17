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

    func guesses(forWord word: String, language: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(forWordRange: range, in: word, language: language) ?? []
    }
}
