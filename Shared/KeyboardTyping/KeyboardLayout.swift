import Foundation

/// Which keyboard the Muesli keyboard is. Chosen in Settings, read by the keyboard through the shared store.
/// The raw values are the stored format: an older or newer build may read what this one wrote, so cases keep
/// their names.
enum KeyboardLayout: String, Sendable, Equatable, CaseIterable {
    /// The Type page (QWERTY, suggestion strip, autocorrect, Record and Fix) with the Dictate page one 3 s hold away.
    case full
    /// The Dictate page only: it is the whole keyboard.
    case minimal

    /// What a keyboard that cannot read the setting shows: Full Access off, nothing published, or a stored value
    /// this build does not know.
    static let fallback = KeyboardLayout.full

    /// The Type page exists, so it can be shown, chosen and remembered.
    var offersTypePage: Bool { self == .full }
}
