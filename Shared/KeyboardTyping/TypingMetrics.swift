import Foundation

/// The keyboard's one height. The Type page and the Dictate page share it, so switching never jumps, and the
/// extension's height constraint, the launch snapshot and the tests all read it from here.
enum TypingMetrics {
    /// The suggestion strip, and the dictation status line in the same slot while a dictation runs.
    static let stripHeight: Double = 40
    /// 44 pt is Apple's minimum touch target; the keys keep it.
    static let keyHeight: Double = 44
    /// The gap between rows. Each key's tap area reaches the middle of the gap, so no tap falls between keys.
    static let rowSpacing: Double = 10
    static let topInset: Double = 4
    static let stripGap: Double = 6
    static let bottomInset: Double = 6
    static let rowCount = 4

    /// 4 + 40 + 6 + 4 x 44 + 3 x 10 + 6 = 262.
    static var preferredHeight: Double {
        let rows = Double(rowCount)
        return topInset + stripHeight + stripGap + rows * keyHeight + (rows - 1) * rowSpacing + bottomInset
    }
}

/// The two pages the keyboard switches between. The choice itself lives on the controller so a keyboard that is
/// reopened, and its launch snapshot, come up on the page it was left on.
enum TypingSurface: Sendable, Equatable {
    case type
    case dictate

    /// Setup verification needs the Dictate page's Verify row, whichever page was last chosen. A running
    /// dictation shows on both pages, so it never forces one.
    static func resolve(selected: TypingSurface, hasPendingSetupVerification: Bool, isDictationActive: Bool) -> TypingSurface {
        hasPendingSetupVerification && !isDictationActive ? .dictate : selected
    }
}

/// What fills the strip on the Type page. Priority: a running dictation (its live status, same slot as the Dictate
/// page's status line), then the Undo edit button after a Quill rewrite, then suggestions.
enum TypingStripContent: Sendable, Equatable {
    case dictationStatus
    case undoEdit
    case suggestions([TypingSuggestion])
    case empty

    static func resolve(
        isDictationActive: Bool,
        canUndoRewrite: Bool,
        suggestions: [TypingSuggestion]
    ) -> TypingStripContent {
        if isDictationActive { return .dictationStatus }
        if canUndoRewrite { return .undoEdit }
        return suggestions.isEmpty ? .empty : .suggestions(suggestions)
    }
}

enum TypingRecordKey {
    enum Mode: Sendable, Equatable {
        /// The mic session is not running: tapping opens Muesli through its URL while also arming the request,
        /// exactly like the Start pill.
        case openMuesli
        case action
    }

    static func mode(opensMuesli: Bool, hasLaunchURL: Bool) -> Mode {
        opensMuesli && hasLaunchURL ? .openMuesli : .action
    }
}
