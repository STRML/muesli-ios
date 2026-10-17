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

    /// A key row's slot: the key and the gap under it. Each row's tap area fills its whole slot.
    static var rowSlotHeight: Double { keyHeight + rowSpacing }
    /// The slots above the bottom row: the three letter (or number, or symbol) rows. The recording panel fills
    /// exactly these, so the bottom row stays where it is.
    static var panelSlotHeight: Double { Double(rowCount - 1) * rowSlotHeight }

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

    /// Minimal always shows the Dictate page. Setup verification needs the Dictate page's Verify row, whichever page was last chosen. A running
    /// dictation shows on both pages, so it never forces one.
    static func resolve(
        layout: KeyboardLayout,
        selected: TypingSurface,
        hasPendingSetupVerification: Bool,
        isDictationActive: Bool
    ) -> TypingSurface {
        // Minimal has one page. Full follows the chosen one, except that setup verification needs Dictate.
        guard layout.offersTypePage else { return .dictate }
        return hasPendingSetupVerification && !isDictationActive ? .dictate : selected
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

/// The way back to the old keyboard page while the Type page is being built out: holding the Record key for
/// three seconds. This is the tracker for one press. The view feeds it touch events and a timer; it decides
/// whether the hold counts, and whether the release afterwards is a tap.
struct TypingRecordHold: Sendable, Equatable {
    /// How long the key must be held.
    static let duration: TimeInterval = 3.0
    /// How far the finger may drift, in points, before the press stops being a hold.
    static let allowedTravel: Double = 12
    /// A timer that was asked to wake after `duration` may read a clock a hair short of it.
    static let clockSlack: TimeInterval = 0.05

    enum Release: Sendable, Equatable {
        /// Let go before the hold counted: the key's normal tap applies.
        case tap
        /// The hold counted and already acted; this release is not a tap.
        case held
        /// The finger moved away: the hold is off.
        case movedAway
    }

    private var originX = 0.0
    private var originY = 0.0
    private var pressedAt: TimeInterval?
    private(set) var hasMovedAway = false
    private(set) var hasFired = false

    var isPressed: Bool { pressedAt != nil }

    mutating func begin(at time: TimeInterval, x: Double, y: Double) {
        self = TypingRecordHold()
        originX = x
        originY = y
        pressedAt = time
    }

    mutating func move(x: Double, y: Double) {
        guard pressedAt != nil else { return }
        let travel = ((x - originX) * (x - originX) + (y - originY) * (y - originY)).squareRoot()
        if travel > Self.allowedTravel { hasMovedAway = true }
    }

    /// The timer woke. True exactly once: still pressed, the finger has stayed put, and the time is up.
    mutating func timerFired(at time: TimeInterval) -> Bool {
        guard let pressedAt, !hasMovedAway, !hasFired, time - pressedAt >= Self.duration - Self.clockSlack else {
            return false
        }
        hasFired = true
        return true
    }

    mutating func end() -> Release {
        defer { self = TypingRecordHold() }
        if hasFired { return .held }
        return hasMovedAway ? .movedAway : .tap
    }
}

/// What the dictation is doing, as far as the strip's pill cares. The controller maps its own phases onto this.
enum TypingPillPhase: Sendable, Equatable {
    case idle
    case requested
    case recording
    case transcribing
    case inserting
    case copyRequired
    case failed
    case cancelled
}

/// The wide pill in the strip while a dictation runs: tapping it stops and saves, like the Record key. It is
/// tappable only while recording, and not once a stop or a cancel is already on its way.
enum TypingStripPill {
    /// 44 pt is Apple's minimum touch target; the pill's tap area keeps it across its full width.
    static let minimumHitHeight: Double = 44

    static func isTappable(phase: TypingPillPhase, stopRequested: Bool, cancelRequested: Bool) -> Bool {
        phase == .recording && !stopRequested && !cancelRequested
    }
}

/// The large panel that takes the place of the three letter rows while a dictation records, so the whole key area
/// above the bottom row is one stop target. Only the Full layout's Type page has it: the Dictate page already
/// has its big pill. It appears when recording begins (not while the start is still requested, so a start that
/// fails never shows it) and stays through transcribing; then the keys come back.
enum TypingRecordingPanel: Sendable, Equatable {
    case hidden
    /// Recording; the whole panel stops and saves.
    case recording
    /// A stop is on its way.
    case stopping
    /// A cancel is on its way.
    case cancelling
    /// The final pass is running.
    case transcribing

    static func resolve(
        layout: KeyboardLayout,
        surface: TypingSurface,
        phase: TypingPillPhase,
        stopRequested: Bool,
        cancelRequested: Bool
    ) -> TypingRecordingPanel {
        guard layout.offersTypePage, surface == .type else { return .hidden }
        guard phase == .recording || phase == .transcribing else { return .hidden }
        if cancelRequested { return .cancelling }
        if TypingStripPill.isTappable(phase: phase, stopRequested: stopRequested, cancelRequested: cancelRequested) {
            return .recording
        }
        return phase == .recording ? .stopping : .transcribing
    }

    /// The same guard as the strip pill and the Record key, so the three can never disagree.
    var isTappable: Bool { self == .recording }

    /// The line at the foot of the panel. `isEdit` is a Quill voice edit rather than a dictation.
    func caption(isEdit: Bool) -> String {
        switch self {
        case .hidden: ""
        case .recording: isEdit ? "Speak your change, then tap anywhere" : "Tap anywhere to stop and save"
        case .stopping: "Stopping"
        case .cancelling: "Cancelling"
        case .transcribing: isEdit ? "Applying your edit" : "Writing your text"
        }
    }

    func accessibilityLabel(isEdit: Bool) -> String {
        switch self {
        case .hidden: ""
        case .recording: isEdit ? "Finish voice edit" : "Stop and save dictation"
        case .stopping: "Stopping dictation"
        case .cancelling: "Cancelling dictation"
        case .transcribing: isEdit ? "Applying your edit" : "Writing your text"
        }
    }

    /// Only the tappable state is a button, so only it has a hint.
    func accessibilityHint(isEdit: Bool) -> String? {
        guard self == .recording else { return nil }
        return isEdit ? "Stops recording and applies your edit" : "Stops recording and inserts the text"
    }

    /// The newest words of a long preview, starting on a whole word and led by an ellipsis, so the panel's text
    /// never grows with the dictation.
    static func previewTail(_ text: String, limit: Int = 140) -> String {
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        var tail = text[start...]
        let cutsAWord = !text[text.index(before: start)].isWhitespace && tail.first?.isWhitespace == false
        if cutsAWord, let gap = tail.firstIndex(where: \.isWhitespace) { tail = tail[gap...] }
        return "\u{2026}" + tail.drop(while: \.isWhitespace)
    }
}
