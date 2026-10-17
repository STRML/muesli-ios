import Foundation

/// Whether the keyboard mic's Lock Screen card may exist, and which cards on screen have to go.
///
/// The card is a Live Activity the app has to keep renewing. When iOS suspends or kills the app mid-session the
/// renewals stop, the card turns stale and reads "Mic off" until the app next runs. It is therefore off by default
/// and has its own switch, separate from the voice note Dynamic Island switch. This policy is pure: ActivityKit is
/// reached only through the caller, which passes in what it found.
enum KeyboardMicCardPolicy {
    /// Off for everyone, including people who had the card before the switch existed.
    static let keyboardMicSwitchDefault = false

    static func allowsCard(systemActivitiesEnabled: Bool, dictationSwitch: Bool, keyboardMicSwitch: Bool) -> Bool {
        systemActivitiesEnabled && dictationSwitch && keyboardMicSwitch
    }

    /// One keyboard mic Live Activity as the system reports it.
    struct Card: Equatable, Sendable {
        let id: String
        let sessionID: String
        let isStale: Bool
    }

    struct Plan: Equatable, Sendable {
        /// Card ids to end now.
        var end: [String]
        /// Card ids the app owns and must renew, because the session they describe is still live.
        var renew: [String]
    }

    /// Decide which cards to end. Only the card this app instance created (`ownedCardID`) for the live session may
    /// stay, and only while cards are allowed. A stale card of that kind is renewed, not ended, because the session
    /// is still running and the card is the one telling the truth once it is refreshed.
    static func reconcile(cards: [Card], ownedCardID: String?, liveSessionID: String?, cardsAllowed: Bool) -> Plan {
        var plan = Plan(end: [], renew: [])
        for card in cards {
            let isLive = cardsAllowed && card.id == ownedCardID && card.sessionID == liveSessionID
            if !isLive { plan.end.append(card.id) } else if card.isStale { plan.renew.append(card.id) }
        }
        return plan
    }
}
