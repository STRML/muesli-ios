import XCTest
@testable import Muesli

/// The Full / Minimal keyboard layout setting: how it reaches the keyboard through the shared store, and which
/// page each layout shows. Row ids (A1..) match the PR's failure matrix.
@MainActor
final class KeyboardLayoutSettingTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var bus: StubEventBus!
    private var store: SharedStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kb-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "kb-layout-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        bus = StubEventBus()
        store = SharedStore(containerURL: directory, eventPoster: bus)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeController(store: SharedStore? = nil) -> KeyboardController {
        KeyboardController(store: store ?? self.store, eventBus: bus, surfaceDefaults: defaults)
    }

    private func publish(_ layout: KeyboardLayout, autocorrect: Bool = true, liveTyping: Bool = true) throws {
        try store.saveKeyboardTypingSettings(
            KeyboardTypingSettings(autocorrect: autocorrect, liveTyping: liveTyping, layout: layout))
    }

    private var rememberedPage: String? { defaults.string(forKey: KeyboardController.selectedSurfaceDefaultsKey) }

    // A1: nothing published yet.
    func testWithNothingPublishedTheKeyboardIsFull() {
        let controller = makeController()
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.layout, .full)
        XCTAssertEqual(controller.surface, .type)
    }

    // A2: Minimal published: the Dictate page is the keyboard.
    func testMinimalOpensOnTheDictatePage() throws {
        try publish(.minimal)
        let controller = makeController()
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.layout, .minimal)
        XCTAssertEqual(controller.surface, .dictate)
    }

    // A3: Full Access off. The App Group is unreachable, the read throws, and the keyboard is Full. A store whose
    // container is a plain file fails the way a denied container does.
    func testAnUnreadableStoreFallsBackToFull() throws {
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocked)
        let unreachable = SharedStore(containerURL: blocked, eventPoster: bus)
        XCTAssertThrowsError(try unreachable.keyboardTypingSettings(), "the fixture must fail like a denied container")
        let controller = makeController(store: unreachable)
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.layout, .full)
        XCTAssertEqual(controller.surface, .type)
    }

    // A3b: a keyboard that had Minimal and then loses Full Access goes back to Full, not stays Minimal.
    func testLosingFullAccessAfterMinimalReturnsToFull() throws {
        try publish(.minimal)
        let controller = makeController()
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.layout, .minimal)
        let blocked = directory.appendingPathComponent("gone")
        try Data("x".utf8).write(to: blocked)
        let unreachable = SharedStore(containerURL: blocked, eventPoster: bus)
        let again = KeyboardController(store: unreachable, eventBus: bus, surfaceDefaults: defaults)
        again.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(again.layout, .full)
    }

    // A4: missing, unknown and corrupted values all read as Full and keep the other two switches.
    func testAMissingUnknownOrCorruptedLayoutIsFullAndKeepsTheOtherSwitches() throws {
        for json in [
            #"{"autocorrect":false,"liveTyping":false}"#,
            #"{"autocorrect":false,"liveTyping":false,"layout":"compact"}"#,
            #"{"autocorrect":false,"liveTyping":false,"layout":3}"#,
            #"{"autocorrect":false,"liveTyping":false,"layout":null}"#,
        ] {
            let decoded = try JSONDecoder().decode(KeyboardTypingSettings.self, from: Data(json.utf8))
            try store.saveKeyboardTypingSettings(decoded)
            let controller = makeController()
            controller.loadTypingSettings(appliesLayout: true)
            XCTAssertEqual(controller.layout, .full, json)
            XCTAssertFalse(controller.typing.autocorrectEnabled, json)
            XCTAssertFalse(controller.liveTyper.isEnabled, json)
        }
    }

    // A5: a setting that changes while the keyboard is up waits for the next appearance. Autocorrect and live typing
    // still change at once.
    func testALayoutChangeWhileTheKeyboardIsUpWaitsForTheNextAppearance() throws {
        try publish(.full)
        let controller = makeController()
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.surface, .type)

        try publish(.minimal, autocorrect: false)
        controller.loadTypingSettings()  // what the typingSettingsChanged event runs
        XCTAssertEqual(controller.layout, .full, "re-laid out under the user's thumbs")
        XCTAssertEqual(controller.surface, .type)
        XCTAssertFalse(controller.typing.autocorrectEnabled, "autocorrect must still follow at once")

        controller.loadTypingSettings(appliesLayout: true)  // the next appearance
        XCTAssertEqual(controller.layout, .minimal)
        XCTAssertEqual(controller.surface, .dictate)
    }

    // A6: setup verification forces Dictate in both layouts.
    func testSetupVerificationShowsTheDictatePageInBothLayouts() throws {
        for layout in KeyboardLayout.allCases {
            try publish(layout)
            let controller = makeController()
            controller.loadTypingSettings(appliesLayout: true)
            controller.selectedSurface = .type
            let now = Date()
            controller.setupVerificationChallenge = KeyboardSetupVerificationChallenge(
                id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(60))
            XCTAssertEqual(controller.surface, .dictate, "\(layout)")
        }
    }

    // A7: Full follows the remembered page; Minimal ignores it and never writes it.
    func testFullFollowsTheRememberedPageAndMinimalNeverTouchesIt() throws {
        try publish(.full)
        let full = makeController()
        full.loadTypingSettings(appliesLayout: true)
        full.selectedSurface = .dictate
        XCTAssertEqual(rememberedPage, "dictate")
        XCTAssertEqual(makeController().surface, .dictate)

        try publish(.minimal)
        let minimal = makeController()
        minimal.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(minimal.surface, .dictate)
        minimal.selectedSurface = .type  // nothing offers this, but even so nothing is remembered
        XCTAssertEqual(minimal.surface, .dictate)
        XCTAssertEqual(rememberedPage, "dictate", "Minimal overwrote Full's remembered page")
    }

    // A8: the layout changed between launches, both ways: Full's page is still there after a spell in Minimal.
    func testSwitchingToMinimalAndBackKeepsFullsRememberedPage() throws {
        try publish(.full)
        let first = makeController()
        first.loadTypingSettings(appliesLayout: true)
        first.selectedSurface = .type
        XCTAssertEqual(rememberedPage, "type")

        try publish(.minimal)
        let second = makeController()
        second.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(second.surface, .dictate)

        try publish(.full)
        let third = makeController()
        third.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(third.surface, .type)
    }

    // A8b: the same, inside one long-lived keyboard process that sees the layout change between appearances.
    func testOneKeyboardProcessSeesTheLayoutChangeAtItsNextAppearance() throws {
        try publish(.full)
        let controller = makeController()
        controller.loadTypingSettings(appliesLayout: true)
        controller.selectedSurface = .type
        try publish(.minimal)
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.surface, .dictate)
        try publish(.full)
        controller.loadTypingSettings(appliesLayout: true)
        XCTAssertEqual(controller.surface, .type)
    }

    // A9: the 3 s hold sets the Dictate page. In Full that is the Dictate page; in Minimal nothing is offered and
    // nothing is remembered.
    func testTheHoldOpensDictateInFullAndDoesNothingInMinimal() throws {
        try publish(.full)
        let full = makeController()
        full.loadTypingSettings(appliesLayout: true)
        full.selectedSurface = .dictate  // what TypingRecordKeyControl.holdElapsed does
        XCTAssertEqual(full.surface, .dictate)
        XCTAssertEqual(rememberedPage, "dictate")

        defaults.removeObject(forKey: KeyboardController.selectedSurfaceDefaultsKey)
        try publish(.minimal)
        let minimal = makeController()
        minimal.loadTypingSettings(appliesLayout: true)
        minimal.selectedSurface = .dictate
        XCTAssertEqual(minimal.surface, .dictate)
        XCTAssertNil(rememberedPage, "Minimal remembered a page")
    }

    // A10: the shared store carries the layout and posts the settings event.
    func testTheLayoutTravelsThroughTheSharedStoreAndPostsTheEvent() throws {
        try publish(.minimal)
        XCTAssertEqual(try store.keyboardTypingSettings()?.layout, .minimal)
        XCTAssertTrue(bus.postedEvents.contains(.typingSettingsChanged))
    }

    // A11: the app's own preference. Missing, unknown and corrupted all read as Full.
    func testThePreferenceReadsFullUnlessMinimalIsStored() {
        let suite = "layout-pref-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MuesliPreferences.keyboardLayout(in: prefs), .full)
        prefs.set("minimal", forKey: MuesliPreferences.keyboardLayoutKey)
        XCTAssertEqual(MuesliPreferences.keyboardLayout(in: prefs), .minimal)
        for junk in ["Minimal", "", "compact"] as [Any] {
            prefs.set(junk, forKey: MuesliPreferences.keyboardLayoutKey)
            XCTAssertEqual(MuesliPreferences.keyboardLayout(in: prefs), .full, "\(junk)")
        }
        prefs.set(7, forKey: MuesliPreferences.keyboardLayoutKey)
        XCTAssertEqual(MuesliPreferences.keyboardLayout(in: prefs), .full)
    }
}
