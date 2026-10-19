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
/// reopened, and its launch snapshot, come up on the page it was left on. The raw values are what the keyboard
/// writes to its own defaults, so cases keep their names: a later build may read what an older one wrote.
enum TypingSurface: String, Sendable, Equatable {
    case type
    case dictate

    /// Minimal always shows the Dictate page; Full shows it too while a dictation records or transcribes, unless
    /// the user took the Type page back for it (`holdsTypePage`). Setup verification needs the Dictate page's Verify row, whichever page was last chosen. A running
    /// dictation shows on both pages, so it never forces one.
    static func resolve(
        layout: KeyboardLayout,
        selected: TypingSurface,
        hasPendingSetupVerification: Bool,
        phase: TypingPillPhase,
        holdsTypePage: Bool
    ) -> TypingSurface {
        // Minimal has one page.
        guard layout.offersTypePage else { return .dictate }
        let isActive = [TypingPillPhase.requested, .recording, .transcribing].contains(phase)
        // Setup verification needs the Dictate page's Verify row at rest. A start still being requested shows the
        // page the user was on.
        if hasPendingSetupVerification && !isActive { return .dictate }
        // While the mic is live or the final pass runs, Full shows the familiar Dictate page. This is derived from
        // the phase, never stored, so the user's chosen page is untouched and comes back when the dictation ends.
        // Not on `requested`, so a start that fails never flashes it, and not once the user took the Type page
        // back (ABC) for this dictation.
        let showsDictation = phase == .recording || phase == .transcribing
        if selected == .type, showsDictation, !holdsTypePage { return .dictate }
        return selected
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

    /// With nothing to suggest the strip carries a settings gear at its left and a Start pill in the middle.
    var offersSettingsAndStart: Bool { self == .empty }
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

/// The way from the Type page to the Dictate page: holding the Record key for three seconds. This is the
/// tracker for one press. The view feeds it touch events and a timer; it decides whether the hold counts, and
/// whether the release afterwards is a tap.
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
