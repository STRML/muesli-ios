import UIKit
import XCTest
@testable import Muesli

/// Moving between the Muesli keyboard and the others: the globe's wiring, and the page the keyboard reopens on.
/// The system keyboard list itself (a long press in a real host) cannot be raised from the simulator's test host;
/// these call the same entry points the touch actions call and check what they hand to UIKit.
@MainActor
final class KeyboardSwitchingTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kb-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "kb-switch-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeController() -> KeyboardController {
        let bus = StubEventBus()
        return KeyboardController(
            store: SharedStore(containerURL: directory, eventPoster: bus),
            eventBus: bus,
            surfaceDefaults: defaults
        )
    }

    // MARK: Remembered page

    func testFirstLaunchOpensOnType() {
        let controller = makeController()
        XCTAssertEqual(controller.selectedSurface, .type)
        XCTAssertEqual(controller.surface, .type)
    }

    func testTheChosenPageIsRememberedByTheNextKeyboard() {
        makeController().selectedSurface = .dictate
        XCTAssertEqual(makeController().surface, .dictate)
        let again = makeController()
        again.selectedSurface = .type
        XCTAssertEqual(makeController().surface, .type)
    }

    func testTheRememberedPageIsWrittenToTheKeyboardsOwnDefaults() {
        makeController().selectedSurface = .dictate
        XCTAssertEqual(defaults.string(forKey: KeyboardController.selectedSurfaceDefaultsKey), "dictate")
    }

    func testPendingSetupVerificationStillForcesDictateAndDoesNotOverwriteTheMemory() {
        let controller = makeController()
        controller.selectedSurface = .dictate
        controller.selectedSurface = .type
        let now = Date()
        controller.setupVerificationChallenge = KeyboardSetupVerificationChallenge(
            id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertEqual(controller.surface, .dictate)
        XCTAssertEqual(defaults.string(forKey: KeyboardController.selectedSurfaceDefaultsKey), "type")
    }

    func testACorruptedOrUnknownStoredValueOpensOnType() {
        for junk in [42, "", "Dictate", "dictate-v2", ["dictate"]] as [Any] {
            defaults.set(junk, forKey: KeyboardController.selectedSurfaceDefaultsKey)
            XCTAssertEqual(makeController().surface, .type, "\(junk)")
        }
    }

    func testAReadFailureLeavesTheStoredValueAlone() {
        defaults.set("dictate-v2", forKey: KeyboardController.selectedSurfaceDefaultsKey)
        _ = makeController()
        XCTAssertEqual(defaults.string(forKey: KeyboardController.selectedSurfaceDefaultsKey), "dictate-v2")
    }

    // MARK: Globe

    func testTheGlobeIsHiddenUntilTheSystemHasAnswered() {
        XCTAssertFalse(makeController().typing.showsGlobe)
    }

    func testTheGlobeFollowsNeedsInputModeSwitchKeyOnBothPagesAsItChanges() {
        let typing = makeController().typing
        typing.setNeedsInputModeSwitchKey(true)
        XCTAssertTrue(typing.showsGlobe)
        typing.setNeedsInputModeSwitchKey(false)
        XCTAssertFalse(typing.showsGlobe, "a hardware keyboard or a new device state takes it away again")
        typing.setNeedsInputModeSwitchKey(true)
        typing.setNeedsInputModeSwitchKey(nil)
        XCTAssertFalse(typing.showsGlobe)
    }

    func testTheTypePageBottomRowDropsTheGlobeAndKeepsItsWidth() {
        let typing = makeController().typing
        func bottom() -> [TypingKey] {
            TypingLayout.rows(
                page: .letters, uppercase: false, traits: TypingTraits(), showsGlobe: typing.showsGlobe)[3]
        }
        XCTAssertFalse(bottom().contains { $0.action == .globe })
        typing.setNeedsInputModeSwitchKey(true)
        XCTAssertTrue(bottom().contains { $0.action == .globe })
        XCTAssertEqual(bottom().map(\.weight).reduce(0, +), TypingLayout.rowWeight, accuracy: 0.001)
    }

    func testEveryTouchOnAShownGlobeGoesToTheSystemKeyboardList() {
        let controller = makeController()
        var advanced = 0
        var listViews: [UIView] = []
        controller.inputModeSwitcher = { advanced += 1 }
        controller.inputModeListPresenter = { view, _ in listViews.append(view) }

        let control = KeyboardGlobeTouchControl(controller: controller)
        control.sendActions(for: .touchDown)
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(listViews.count, 2, "every touch event is handed to handleInputModeList, as Apple's sample does")
        XCTAssertTrue(listViews.allSatisfy { $0 === control })
        XCTAssertEqual(advanced, 0, "the system switches on the tap itself; advancing here too would skip a keyboard")
    }

    func testVoiceOverActivationAdvances() {
        let controller = makeController()
        var advanced = 0
        var listCalls = 0
        controller.inputModeSwitcher = { advanced += 1 }
        controller.inputModeListPresenter = { _, _ in listCalls += 1 }
        let control = KeyboardGlobeTouchControl(controller: controller)
        XCTAssertTrue(control.accessibilityActivate())
        XCTAssertEqual(advanced, 1)
        XCTAssertEqual(listCalls, 0)
    }
}
