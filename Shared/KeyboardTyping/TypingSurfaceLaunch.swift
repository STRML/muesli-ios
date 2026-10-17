import Foundation

extension TypingSurface {
    /// What the keyboard writes to its own defaults. Stable: a later build may read what an older one wrote.
    var storedValue: String {
        switch self {
        case .type: "type"
        case .dictate: "dictate"
        }
    }

    /// Nil for a value this build does not know (corrupted, or written by a newer build).
    init?(storedValue: String) {
        switch storedValue {
        case "type": self = .type
        case "dictate": self = .dictate
        default: return nil
        }
    }

    /// The page chosen when the keyboard opens: the remembered one (Type when there is none or it is unreadable),
    /// then the same rule as every later render, so setup verification still forces Dictate.
    static func atLaunch(
        stored: String?,
        hasPendingSetupVerification: Bool,
        isDictationActive: Bool
    ) -> TypingSurface {
        resolve(
            selected: stored.flatMap(TypingSurface.init(storedValue:)) ?? .type,
            hasPendingSetupVerification: hasPendingSetupVerification,
            isDictationActive: isDictationActive
        )
    }
}

/// Whether our own globe key is drawn. Apple's rule: a keyboard draws its next-keyboard key only when
/// `needsInputModeSwitchKey` is true (the system provides none). When it is false the system draws a globe under
/// the keyboard, which also has the keyboard list, and a second one of ours would be a duplicate. Unknown counts
/// as false: the key appears once the system has said it is needed.
enum TypingGlobeKey {
    static func isShown(needsInputModeSwitchKey: Bool?) -> Bool {
        needsInputModeSwitchKey == true
    }
}
