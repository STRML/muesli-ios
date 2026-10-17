import XCTest
@testable import DictationPolicyKit

/// When the keyboard mic's Lock Screen card may exist, and which leftover cards get ended. Each test is a row
/// of the failure matrix in the pull request.
final class KeyboardMicCardPolicyTests: XCTestCase {
    private typealias Policy = KeyboardMicCardPolicy
    private typealias Card = KeyboardMicCardPolicy.Card

    private func card(_ id: String, session: String, stale: Bool = false) -> Card {
        Card(id: id, sessionID: session, isStale: stale)
    }

    // MARK: allows

    func testTheKeyboardMicSwitchDefaultsOffForEveryone() {
        XCTAssertFalse(Policy.keyboardMicSwitchDefault)
    }

    func testBothSwitchesAndSystemActivitiesMustAllowTheCard() {
        for system in [false, true] {
            for dictation in [false, true] {
                for keyboard in [false, true] {
                    XCTAssertEqual(
                        Policy.allowsCard(systemActivitiesEnabled: system, dictationSwitch: dictation, keyboardMicSwitch: keyboard),
                        system && dictation && keyboard,
                        "system \(system) dictation \(dictation) keyboard \(keyboard)"
                    )
                }
            }
        }
    }

    func testKeyboardSwitchOnWithDictationSwitchOffShowsNoCard() {
        XCTAssertFalse(Policy.allowsCard(systemActivitiesEnabled: true, dictationSwitch: false, keyboardMicSwitch: true))
    }

    func testBothOnShowsTheCard() {
        XCTAssertTrue(Policy.allowsCard(systemActivitiesEnabled: true, dictationSwitch: true, keyboardMicSwitch: true))
    }

    func testSystemLiveActivitiesDisabledShowsNoCard() {
        XCTAssertFalse(Policy.allowsCard(systemActivitiesEnabled: false, dictationSwitch: true, keyboardMicSwitch: true))
    }

    // MARK: reconcile

    func testALiveFreshCardOfTheLiveSessionStays() {
        let plan = Policy.reconcile(cards: [card("a", session: "S1")], ownedCardID: "a", liveSessionID: "S1", cardsAllowed: true)
        XCTAssertEqual(plan, .init(end: [], renew: []))
    }

    func testSwitchedOffEndsEveryCardEvenOfTheLiveSession() {
        let plan = Policy.reconcile(
            cards: [card("a", session: "S1"), card("b", session: "S0", stale: true)],
            ownedCardID: "a", liveSessionID: "S1", cardsAllowed: false
        )
        XCTAssertEqual(plan, .init(end: ["a", "b"], renew: []))
    }

    func testAStaleLeftoverCardIsEnded() {
        let plan = Policy.reconcile(cards: [card("old", session: "S0", stale: true)], ownedCardID: nil, liveSessionID: nil, cardsAllowed: true)
        XCTAssertEqual(plan, .init(end: ["old"], renew: []))
    }

    func testACardFromAPreviousSessionIsEndedEvenWhenFresh() {
        let plan = Policy.reconcile(
            cards: [card("old", session: "S0"), card("a", session: "S1")],
            ownedCardID: "a", liveSessionID: "S1", cardsAllowed: true
        )
        XCTAssertEqual(plan, .init(end: ["old"], renew: []))
    }

    func testOurOwnStaleCardOfTheLiveSessionIsRenewedNotEnded() {
        let plan = Policy.reconcile(cards: [card("a", session: "S1", stale: true)], ownedCardID: "a", liveSessionID: "S1", cardsAllowed: true)
        XCTAssertEqual(plan, .init(end: [], renew: ["a"]))
    }

    func testTwoCardsForTheLiveSessionKeepOnlyTheOneWeOwn() {
        let plan = Policy.reconcile(
            cards: [card("dup", session: "S1"), card("a", session: "S1")],
            ownedCardID: "a", liveSessionID: "S1", cardsAllowed: true
        )
        XCTAssertEqual(plan, .init(end: ["dup"], renew: []))
    }

    func testAppRelaunchedWithALeftoverCardOfTheSameSessionEndsItBecauseWeOwnNone() {
        let plan = Policy.reconcile(cards: [card("left", session: "S1")], ownedCardID: nil, liveSessionID: "S1", cardsAllowed: true)
        XCTAssertEqual(plan, .init(end: ["left"], renew: []))
    }

    func testNoLiveSessionEndsEveryCard() {
        let plan = Policy.reconcile(
            cards: [card("a", session: "S1"), card("b", session: "S2")],
            ownedCardID: "a", liveSessionID: nil, cardsAllowed: true
        )
        XCTAssertEqual(plan, .init(end: ["a", "b"], renew: []))
    }

    func testNoCardsNoPlan() {
        XCTAssertEqual(Policy.reconcile(cards: [], ownedCardID: nil, liveSessionID: "S1", cardsAllowed: true), .init(end: [], renew: []))
    }
}
