import Foundation

/// What a voice rewrite acts on. Captured by the keyboard when the user taps Quill, and carried
/// back with the result so the keyboard can check the field still holds this text.
struct RewriteContext: Codable, Sendable, Equatable {
    enum Target: String, Codable, Sendable {
        case selection
        case textBeforeCursor
    }

    let target: Target
    let original: String
}

/// The part of the host text field a keyboard can see.
struct KeyboardTextContext: Equatable, Sendable {
    var selectedText: String?
    var textBeforeCursor: String?

    init(selectedText: String? = nil, textBeforeCursor: String? = nil) {
        self.selectedText = selectedText
        self.textBeforeCursor = textBeforeCursor
    }
}

enum RewriteLimits {
    /// Same ceiling the Mac applies to a remote model.
    static let maximumSelectionCharacters = 20_000
    /// Without a selection only the last paragraph is rewritten, so a correction stays about what was just said.
    static let maximumBeforeCursorCharacters = 1_500
}

enum RewriteCaptureError: Error, Equatable {
    case nothingToFix
    case selectionTooLong(Int)
}

enum RewriteCapture {
    /// A selection wins. With none, the last paragraph before the cursor is the target.
    static func context(from text: KeyboardTextContext) -> Result<RewriteContext, RewriteCaptureError> {
        if let selected = text.selectedText, !isBlank(selected) {
            guard selected.count <= RewriteLimits.maximumSelectionCharacters else {
                return .failure(.selectionTooLong(RewriteLimits.maximumSelectionCharacters))
            }
            return .success(RewriteContext(target: .selection, original: selected))
        }
        guard let before = text.textBeforeCursor else { return .failure(.nothingToFix) }
        let paragraph = lastParagraph(of: before)
        guard !isBlank(paragraph) else { return .failure(.nothingToFix) }
        return .success(RewriteContext(target: .textBeforeCursor, original: capped(paragraph)))
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    /// Everything after the last line break, trailing spaces included so it still matches the field.
    private static func lastParagraph(of text: String) -> String {
        guard let newline = text.lastIndex(where: \.isNewline) else { return text }
        return String(text[text.index(after: newline)...])
    }

    /// Keeps the end of the paragraph, starting on a word boundary.
    private static func capped(_ paragraph: String) -> String {
        let limit = RewriteLimits.maximumBeforeCursorCharacters
        guard paragraph.count > limit else { return paragraph }
        let start = paragraph.index(paragraph.endIndex, offsetBy: -limit)
        let tail = paragraph[start...]
        if paragraph[paragraph.index(before: start)].isWhitespace { return String(tail) }
        guard let space = tail.firstIndex(where: \.isWhitespace) else { return String(tail) }
        return String(tail[tail.index(after: space)...])
    }
}

/// How to apply a rewrite to the field, decided from what the field holds right now.
enum RewriteEdit: Equatable {
    /// Typing over a selection replaces it.
    case replaceSelection(String)
    case replaceBeforeCursor(deleteCount: Int, text: String)
    /// The field changed since the request: leave it alone.
    case stale
}

enum RewritePlanner {
    static func plan(context: RewriteContext, current: KeyboardTextContext, rewritten: String) -> RewriteEdit {
        switch context.target {
        case .selection:
            guard current.selectedText == context.original else { return .stale }
            return .replaceSelection(rewritten)
        case .textBeforeCursor:
            if let selected = current.selectedText, !selected.isEmpty { return .stale }
            guard let before = current.textBeforeCursor, before.hasSuffix(context.original) else { return .stale }
            return .replaceBeforeCursor(deleteCount: context.original.count, text: rewritten)
        }
    }
}
