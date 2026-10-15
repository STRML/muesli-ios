import Foundation

/// When the keyboard mic turns itself off. A hot mic between dictations costs battery, so it goes off after a
/// configurable idle time and always when the screen locks. A dictation that is already under way is
/// allowed to finish first.
enum KeyboardMicAutoOff {
    enum ScreenOffAction: Equatable {
        case turnOffNow
        case turnOffWhenIdle
        case ignore
    }

    /// Minutes; 0 means never. The default is the long end of "a few dictations in a row".
    static let choices = [0, 2, 5, 10, 30, 60]
    static let defaultMinutes = 10

    static func resolved(minutes: Int) -> Int {
        choices.contains(minutes) ? minutes : defaultMinutes
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 60: "1 hour"
        default: "\(minutes) minutes"
        }
    }

    /// Seconds until an idle session should be turned off, or nil when no timer applies. Only a ready
    /// session is idle: any other phase is either busy or already not holding the mic.
    static func idleDelay(for state: KeyboardSessionState, minutes: Int) -> TimeInterval? {
        guard minutes > 0, state.phase == .ready, state.sessionAvailable else { return nil }
        return TimeInterval(minutes * 60)
    }

    static func screenOffAction(for state: KeyboardSessionState) -> ScreenOffAction {
        guard state.micSession.id != nil else { return .ignore }
        switch state.phase {
        case .handoff, .recording, .transcribing:
            return .turnOffWhenIdle
        case .off, .arming, .ready, .retrying, .failed:
            return .turnOffNow
        }
    }
}
