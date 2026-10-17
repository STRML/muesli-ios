import Foundation

enum TypingShiftState: Sendable, Equatable {
    case off
    case once
    case locked
}

/// Shift, caps lock and auto-capitalize as one state machine. Time is passed in so tests control the double tap.
struct TypingShiftMachine: Sendable, Equatable {
    static let doubleTapWindow: TimeInterval = 0.35

    private(set) var state: TypingShiftState = .off
    /// `.once` was set by autocapitalization, not by the user.
    private(set) var isAutomatic = false
    private var lastTapAt: TimeInterval?

    var isUppercase: Bool { state != .off }

    mutating func tapShift(at time: TimeInterval) {
        defer { isAutomatic = false }
        if state == .locked {
            state = .off
            lastTapAt = nil
            return
        }
        if let last = lastTapAt, time - last < Self.doubleTapWindow {
            state = .locked
            lastTapAt = nil
            return
        }
        lastTapAt = time
        state = state == .off ? .once : .off
    }

    /// A character was typed: a one-shot shift is spent, caps lock stays.
    mutating func didInsertCharacter() {
        guard state == .once else { return }
        state = .off
        isAutomatic = false
    }

    /// The context says whether the next letter starts a sentence. It arms an automatic shift and withdraws one
    /// it armed itself; it never touches caps lock or a shift the user pressed.
    mutating func autoCapitalize(_ capitalize: Bool) {
        switch (capitalize, state) {
        case (true, .off):
            state = .once
            isAutomatic = true
        case (false, .once) where isAutomatic:
            state = .off
            isAutomatic = false
        default:
            break
        }
    }
}
