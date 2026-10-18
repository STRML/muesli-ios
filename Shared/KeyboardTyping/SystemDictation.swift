#if canImport(UIKit)
import UIKit

/// iOS's own dictation (the mic the system draws under every keyboard). It shows up as an input mode whose
/// primary language is "dictation": present in the active modes while Enable Dictation is on, and the current
/// mode while the system is listening.
///
/// `isEnabled` reads `activeInputModes`, a required-reason API. Only the keyboard extension calls it (it declares
/// the reason in its privacy manifest); the app reads the result from the shared keyboard status.
@MainActor
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
#endif
