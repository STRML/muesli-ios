import Foundation

extension TypingSurface {
    /// The page chosen when the keyboard opens: the remembered one (Type when there is none or it is unreadable),
    /// then the same rule as every later render, so setup verification still forces Dictate.
    static func atLaunch(
        layout: KeyboardLayout,
        stored: String?,
        hasPendingSetupVerification: Bool,
        phase: TypingPillPhase
    ) -> TypingSurface {
        resolve(
            layout: layout,
            selected: stored.flatMap(TypingSurface.init(rawValue:)) ?? .type,
            hasPendingSetupVerification: hasPendingSetupVerification,
            phase: phase,
            holdsTypePage: false
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
