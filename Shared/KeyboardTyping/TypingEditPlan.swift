import Foundation

/// A replacement that the next backspace takes back (phase 2: autocorrect). Right after the replacement the
/// document ends with `insertedText` (the new word and the boundary that followed it); undoing deletes that and
/// types `replacedText` again, which is exactly what the user had typed: the original word and the same space,
/// punctuation or line break after it.
struct TypingReplacementUndo: Sendable, Equatable {
    let replacedText: String
    let insertedText: String
    /// The word as typed, without the boundary: what the strip offers back, in quotes.
    let originalWord: String

    init(replacedText: String, insertedText: String, originalWord: String? = nil) {
        self.replacedText = replacedText
        self.insertedText = insertedText
        self.originalWord = originalWord ?? replacedText
    }
}

/// One edit to the host document: delete characters before the cursor, then insert text. Counts are in
/// `Character`s (grapheme clusters), which is what `deleteBackward()` removes, never UTF-16 units.
struct TypingEditPlan: Sendable, Equatable {
    let deleteCount: Int
    let insertText: String
    /// The text that must still end the document before the cursor, or the edit is stale and must not run.
    let expectedSuffix: String
    let undo: TypingReplacementUndo?

    func isApplicable(toContextBefore before: String?) -> Bool {
        guard let before, !before.isEmpty else { return expectedSuffix.isEmpty }
        return before.hasSuffix(expectedSuffix)
    }

    /// Swap the partial word for `replacement` and add the space after it, unless the text after the cursor
    /// already starts with a space or punctuation. A replacement equal to the partial only adds the space.
    static func replaceWord(partial: String, with replacement: String, contextAfter: String?) -> TypingEditPlan {
        let space = needsTrailingSpace(contextAfter: contextAfter) ? " " : ""
        if replacement == partial {
            return TypingEditPlan(deleteCount: 0, insertText: space, expectedSuffix: partial, undo: nil)
        }
        return TypingEditPlan(
            deleteCount: partial.count,
            insertText: replacement + space,
            expectedSuffix: partial,
            undo: nil
        )
    }

    private static func needsTrailingSpace(contextAfter: String?) -> Bool {
        guard let next = contextAfter?.first else { return true }
        return !(next.isWhitespace || next.isPunctuation || next.isSymbol)
    }
}
