import Foundation

enum KeyboardDeliveryRoute: String, CaseIterable, Sendable {
    /// The keyboard is on screen and listening, so it inserts the text itself.
    case insertDirect
    /// The app put the text on the clipboard.
    case copied
    /// The app could not copy (it was not in the foreground) and asked the user to open it.
    case copyRequired
}

/// Why a result was or was not handed straight to the keyboard.
enum KeyboardDeliveryReason: String, CaseIterable, Sendable {
    case ok
    case noExtensionStatus
    case noOpenAccess
    case notVisible
    /// The keyboard's heartbeat was older than ``KeyboardDeliveryPolicy/heartbeatWindow``.
    case heartbeatStale
}

struct KeyboardExtensionPresence: Equatable, Sendable {
    var hasOpenAccess: Bool
    var isVisible: Bool
    /// Seconds since the keyboard last reported in.
    var lastSeenAge: TimeInterval
}

enum KeyboardDeliveryPolicy {
    static let heartbeatWindow: TimeInterval = 3.5

    static func decide(_ presence: KeyboardExtensionPresence?) -> (canInsertDirectly: Bool, reason: KeyboardDeliveryReason) {
        guard let presence else { return (false, .noExtensionStatus) }
        guard presence.hasOpenAccess else { return (false, .noOpenAccess) }
        guard presence.isVisible else { return (false, .notVisible) }
        // Strictly less than: this is the app's original `< 3.5` check. A heartbeat stamped in the future (a clock
        // step) gives a negative age and counts as fresh, as it always did.
        guard presence.lastSeenAge < heartbeatWindow else { return (false, .heartbeatStale) }
        return (true, .ok)
    }
}
