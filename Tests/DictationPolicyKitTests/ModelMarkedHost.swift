import Foundation
@testable import DictationPolicyKit

/// A host text field as the live-typing session sees it, with the ways real hosts differ.
///
/// The document is `before` + `after` around a cursor; marked text, when the host supports it, is the last
/// `markedLength` characters of `before`. `shown` is what the keyboard's proxy reports: it follows the document
/// at once, or only after `flush()` when `lags` is set (the proxy is an out-of-process snapshot).
final class ModelMarkedHost {
    enum Behavior {
        /// Marks text, shows it in the context, replaces the marked range on every set.
        case full
        /// `setMarkedText` and `unmarkText` do nothing.
        case ignoresMarked
        /// `setMarkedText` inserts plain text and never marks, so every set appends.
        case appendsAsPlain
        /// Marks and displays text, but the context the proxy reports leaves the marked range out.
        case hidesMarkedFromContext
        /// Puts the marked text after the cursor and leaves the cursor where it was.
        case landsAfterCursor
    }

    var behavior: Behavior
    var lags = false
    /// A host that capitalizes the first letter of the marked text.
    var capitalizesFirstLetter = false
    /// A host that swaps straight quotes for curly ones in the marked text.
    var smartQuotes = false

    private(set) var before: String
    private(set) var after: String
    private(set) var markedLength = 0
    private(set) var selection = ""
    private var shownSnapshot: LiveTypingSnapshot?
    var documentID: UUID? = UUID()
    private(set) var log: [String] = []

    init(before: String = "", after: String = "", behavior: Behavior = .full) {
        self.before = before
        self.after = after
        self.behavior = behavior
        flush()
    }

    var document: String { before + after }

    func snapshot() -> LiveTypingSnapshot {
        if lags, let shownSnapshot { return shownSnapshot }
        return current()
    }

    /// The proxy catches up with the document (the host's `textDidChange` reached the keyboard).
    func flush() { shownSnapshot = current() }

    private func current() -> LiveTypingSnapshot {
        var shownBefore = before
        if behavior == .hidesMarkedFromContext { shownBefore = String(before.dropLast(markedLength)) }
        return LiveTypingSnapshot(before: shownBefore, after: after, selection: selection, documentID: documentID)
    }

    // MARK: What the keyboard does

    func perform(_ commands: [LiveTypingCommand]) {
        for command in commands {
            switch command {
            case .setMarked(let text): setMarked(text)
            case .unmark: unmark()
            case .clearMarked: setMarked(""); unmark()
            case .deleteBackward(let count): for _ in 0..<count { deleteBackward() }
            case .insert(let text): insert(text)
            case .log(let event, let reason): log.append("\(event) \(reason)")
            }
        }
        if !lags { flush() }
    }

    func setMarked(_ raw: String) {
        log.append("setMarked(\(raw))")
        var text = raw
        if capitalizesFirstLetter, let first = text.first { text = first.uppercased() + text.dropFirst() }
        if smartQuotes { text = text.replacingOccurrences(of: "'", with: "\u{2019}") }
        switch behavior {
        case .ignoresMarked:
            return
        case .appendsAsPlain:
            before += text
        case .landsAfterCursor:
            after = String(after.dropFirst(markedLength))
            after = text + after
            markedLength = text.count
        case .full, .hidesMarkedFromContext:
            before = String(before.dropLast(markedLength)) + text
            markedLength = text.count
        }
        selection = ""
    }

    func unmark() {
        log.append("unmark")
        if behavior != .ignoresMarked { markedLength = 0 }
    }

    /// `insertText` on a host: it replaces a selection, and commits any marked range first.
    func insert(_ text: String) {
        log.append("insert(\(text))")
        markedLength = 0
        if !selection.isEmpty { selection = "" }
        before += text
    }

    func deleteBackward() {
        log.append("deleteBackward")
        markedLength = 0
        guard !before.isEmpty else { return }
        before.removeLast()
    }

    // MARK: What the user does

    /// Taps elsewhere in the field: the cursor jumps, and the host commits any marked text.
    func userMovesCursor(toOffsetFromEnd offset: Int) {
        markedLength = 0
        let doc = Array(document)
        let index = max(0, doc.count - offset)
        before = String(doc[..<index])
        after = String(doc[index...])
        if !lags { flush() }
    }

    /// Selects `count` characters before the cursor.
    func userSelects(_ count: Int) {
        selection = String(before.suffix(count))
        if !lags { flush() }
    }

    func userSwitchesField() {
        documentID = UUID()
        before = ""
        after = ""
        markedLength = 0
        if !lags { flush() }
    }
}
