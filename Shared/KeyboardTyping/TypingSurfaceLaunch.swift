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

/// How the globe key reacts to a touch. Apple's sample hands every touch to `handleInputModeList(from:with:)`,
/// which switches on a tap and shows the keyboard list on a long press. That is only for a keyboard the system
/// draws no globe for; otherwise the system's own globe has the list, and ours advances on a plain tap.
enum TypingGlobeKey {
    enum Route: Sendable, Equatable {
        case systemTracking
        case advanceOnTap
    }

    static func route(needsInputModeSwitchKey: Bool?) -> Route {
        needsInputModeSwitchKey == true ? .systemTracking : .advanceOnTap
    }
}
