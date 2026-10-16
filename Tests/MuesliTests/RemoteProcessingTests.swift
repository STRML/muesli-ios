import XCTest
@testable import Muesli

/// The app side of remote processing: the stored opt-in, what the keyboard is told, and the Full Access banner.
/// The decision logic itself is covered on the host by `swift test` (Tests/RemoteTranscriptionKitTests).
@MainActor
final class RemoteProcessingTests: XCTestCase {
    private var defaultsSnapshot: [String: Any?] = [:]
    private let keys = [MuesliPreferences.remoteProcessingEnabledKey, MuesliPreferences.customLLMBaseURLKey]

    override func setUp() async throws {
        try await super.setUp()
        defaultsSnapshot = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    }

    override func tearDown() async throws {
        for (key, value) in defaultsSnapshot {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    func testRemoteProcessingIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: MuesliPreferences.remoteProcessingEnabledKey)
        XCTAssertFalse(MuesliPreferences.remoteProcessingEnabled)
    }

    func testRow02AStaleSettingIsIgnoredOnceTheEndpointIsRemoved() {
        UserDefaults.standard.set(true, forKey: MuesliPreferences.remoteProcessingEnabledKey)
        UserDefaults.standard.set("https://studio.example.ts.net/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        XCTAssertTrue(MuesliPreferences.isRemoteProcessingActive)
        UserDefaults.standard.set("", forKey: MuesliPreferences.customLLMBaseURLKey)
        XCTAssertTrue(MuesliPreferences.remoteProcessingEnabled)
        XCTAssertFalse(MuesliPreferences.isRemoteProcessingActive)
    }

    func testRuntimeStatusFromAnOlderAppDecodesWithRemoteProcessingOff() throws {
        let status = KeyboardRuntimeStatus(isActive: true, remoteProcessingEnabled: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let encoded = try JSONEncoder().encode(status)
        XCTAssertTrue(try JSONDecoder().decode(KeyboardRuntimeStatus.self, from: encoded).remoteProcessingEnabled)

        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "remoteProcessingEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(KeyboardRuntimeStatus.self, from: legacy).remoteProcessingEnabled)
    }

    func testTurningRemoteProcessingOnRepublishesTheRuntimeStatus() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = KeyboardRuntimeStatusPublishPolicy()
        let off = KeyboardRuntimeStatus(isActive: true, supportsBackgroundStart: true, updatedAt: t0)
        policy.notePublished(off, now: t0)
        let on = KeyboardRuntimeStatus(isActive: true, supportsBackgroundStart: true, remoteProcessingEnabled: true, updatedAt: t0)
        XCTAssertTrue(policy.shouldPublish(on, now: t0))
    }

    func testRow10KeyboardWithoutFullAccessShowsTheBannerOnlyWhileRemoteProcessingIsOn() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remote-banner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bus = StubEventBus()
        let store = SharedStore(containerURL: directory, eventPoster: bus)
        let controller = KeyboardController(store: store, eventBus: bus)

        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(isActive: true, supportsBackgroundStart: true, remoteProcessingEnabled: true))
        controller.markKeyboardVisible(hasOpenAccess: false)
        controller.prepareInitialPresentationState()
        XCTAssertEqual(controller.remoteProcessingBanner, "Full Access needed for remote processing")

        controller.markKeyboardVisible(hasOpenAccess: true)
        XCTAssertNil(controller.remoteProcessingBanner)

        try store.saveKeyboardRuntimeStatus(KeyboardRuntimeStatus(isActive: true, supportsBackgroundStart: true, remoteProcessingEnabled: false))
        controller.markKeyboardVisible(hasOpenAccess: false)
        controller.prepareInitialPresentationState()
        XCTAssertNil(controller.remoteProcessingBanner)
    }

    func testARemoteTranscriptIsLabelledByItsEngine() {
        XCTAssertEqual(TranscriptionDisplayName.engineName(for: RemoteTranscriptionService.engineIdentifier), "Remote (Custom LLM)")
    }
}
