import Foundation

/// Which keyboard the Muesli keyboard is. Chosen in Settings, read by the keyboard through the shared store.
enum KeyboardLayout: Sendable, Equatable, CaseIterable {
    /// The Type page (QWERTY, suggestion strip, autocorrect, Record and Fix) with the Dictate page one 3 s hold away.
    case full
    /// The old dictation panel only: the Dictate page is the keyboard.
    case minimal

    /// What a keyboard that cannot read the setting shows: Full Access off, nothing published, or a stored value
    /// this build does not know.
    static let fallback = KeyboardLayout.full

    /// Stable: an older or newer build may read what this one wrote.
    var storedValue: String {
        switch self {
        case .full: "full"
        case .minimal: "minimal"
        }
    }

    /// Nil for a value this build does not know (corrupted, or written by a newer build).
    init?(storedValue: String) {
        switch storedValue {
        case "full": self = .full
        case "minimal": self = .minimal
        default: return nil
        }
    }

    /// The Type page exists, so it can be shown, chosen and remembered.
    var offersTypePage: Bool { self == .full }
}
