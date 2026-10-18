import UIKit

/// iOS's own dictation (the mic the system draws under every keyboard). It shows up as an input mode whose
/// primary language is "dictation": present in the active modes while Enable Dictation is on, and the current
/// mode while the system is listening.
enum SystemDictation {
    static let inputModeLanguage = "dictation"

    static func isDictationMode(_ mode: UITextInputMode?) -> Bool {
        mode?.primaryLanguage == inputModeLanguage
    }

    /// Whether Settings > General > Keyboard > Enable Dictation is on.
    static var isEnabled: Bool {
        UITextInputMode.activeInputModes.contains(where: isDictationMode)
    }
}
