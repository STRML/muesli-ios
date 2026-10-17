import XCTest
@testable import Muesli

/// The controller's decisions about cards it does not hold, through a fake of the ActivityKit calls. Starting a
/// card (`Activity.request`) and renewing the held one cannot run here; the policy behind them is covered by
/// `KeyboardMicCardPolicyTests`.
@MainActor
final class KeyboardMicActivityControllerTests: XCTestCase {
    // Shared/ is compiled into both modules; the controller speaks the app module's copy of the type.
    private typealias Card = Muesli.KeyboardMicCardPolicy.Card

    @MainActor private final class FakeSystem: KeyboardMicActivitySystem {
        var activitiesEnabled = true
        var live: [Card] = []
        private(set) var ended: [String] = []
        func cards() -> [Card] { live.filter { !ended.contains($0.id) } }
        func end(cardID: String) async { ended.append(cardID) }
    }

    private let live = UUID()
    private let other = UUID()

    private func make(
        _ system: FakeSystem, dictation: Bool = true, keyboard: Bool = true
    ) -> KeyboardMicActivityController {
        KeyboardMicActivityController(system: system, dictationSwitch: { dictation }, keyboardMicSwitch: { keyboard })
    }

    private func card(_ id: String, _ session: UUID, stale: Bool = false) -> Card {
        .init(id: id, sessionID: session.uuidString, isStale: stale)
    }

    func testKeyboardMicSwitchIsOffOnAFreshInstallAndAnUpgrade() {
        let key = MuesliPreferences.liveActivitiesForKeyboardMicKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(MuesliPreferences.liveActivitiesForKeyboardMicEnabled)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(MuesliPreferences.liveActivitiesForKeyboardMicEnabled)
    }

    func testCardsAreAllowedOnlyWhenEverySwitchAllows() {
        let system = FakeSystem()
        XCTAssertTrue(make(system).cardsAllowed)
        XCTAssertFalse(make(system, keyboard: false).cardsAllowed)
        XCTAssertFalse(make(system, dictation: false).cardsAllowed)
        system.activitiesEnabled = false
        XCTAssertFalse(make(system).cardsAllowed)
    }

    func testSwitchOffRelaunchEndsEveryLeftoverCard() async {
        let system = FakeSystem()
        system.live = [card("a", live), card("b", other, stale: true)]
        await make(system, keyboard: false).removeOrphanedActivities(liveSessionID: nil)
        XCTAssertEqual(system.ended, ["a", "b"])
    }

    func testSwitchOffEndsEvenTheLiveSessionsCardOnForeground() async {
        let system = FakeSystem()
        system.live = [card("a", live)]
        await make(system, keyboard: false).removeOrphanedActivities(liveSessionID: live)
        XCTAssertEqual(system.ended, ["a"])
    }

    func testRelaunchWithALeftoverCardEndsItWhenSwitchOnBecauseNothingIsOwned() async {
        let system = FakeSystem()
        system.live = [card("left", live, stale: true)]
        await make(system).removeOrphanedActivities(liveSessionID: nil)
        XCTAssertEqual(system.ended, ["left"])
    }

    func testStaleAndPreviousSessionCardsAndDuplicatesEndOnForeground() async {
        let system = FakeSystem()
        system.live = [card("stale", live, stale: true), card("prev", other), card("dup", live)]
        await make(system).removeOrphanedActivities(liveSessionID: live)
        XCTAssertEqual(system.ended, ["stale", "prev", "dup"])
    }

    func testEndAllEndsEverySessionsCards() async {
        let system = FakeSystem()
        system.live = [card("a", live), card("b", other)]
        await make(system).endAll()
        XCTAssertEqual(system.ended, ["a", "b"])
    }

    func testEndSessionEndsOnlyThatSessionsCards() async {
        let system = FakeSystem()
        system.live = [card("a", live), card("b", other)]
        await make(system).end(sessionID: live)
        XCTAssertEqual(system.ended, ["a"])
    }

    func testNoCardsIsANoOp() async {
        let system = FakeSystem()
        await make(system).removeOrphanedActivities(liveSessionID: live)
        await make(system).endAll()
        XCTAssertTrue(system.ended.isEmpty)
    }
}
