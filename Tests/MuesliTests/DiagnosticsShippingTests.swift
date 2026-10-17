import XCTest
@testable import Muesli

/// The app side of diagnostics shipping: the stored opt-in, what the uploader is told about the endpoint, and the
/// state file. The queue, backoff, sanitizer and transport are covered on the host (Tests/DiagnosticsKitTests).
@MainActor
final class DiagnosticsShippingTests: XCTestCase {
    private var defaultsSnapshot: [String: Any?] = [:]
    private let keys = [
        MuesliPreferences.diagnosticsShippingEnabledKey,
        MuesliPreferences.diagnosticsAcknowledgedHostKey,
        MuesliPreferences.diagnosticsDeviceIDKey,
        MuesliPreferences.customLLMBaseURLKey,
        MuesliPreferences.diagnosticsEndpointURLKey,
    ]

    override func setUp() async throws {
        try await super.setUp()
        defaultsSnapshot = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        for (key, value) in defaultsSnapshot {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    func testDiagnosticsShippingIsOffByDefault() {
        XCTAssertFalse(MuesliPreferences.diagnosticsShippingEnabled)
        XCTAssertFalse(DiagnosticsShipper.currentSettings().enabled)
    }

    func testNoServerAddressMeansNoEndpoint() {
        XCTAssertNil(DiagnosticsShipper.currentSettings().endpoint)
        UserDefaults.standard.set("http://studio.tail13013.ts.net/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        XCTAssertNil(DiagnosticsShipper.currentSettings().endpoint, "plain http is never an endpoint")
    }

    func testThePrivateTailscaleEndpointPostsToTheDiagnosticsRoute() throws {
        UserDefaults.standard.set("https://Studio.tail13013.ts.net/v1/", forKey: MuesliPreferences.customLLMBaseURLKey)
        let endpoint = try XCTUnwrap(DiagnosticsShipper.currentSettings().endpoint)
        XCTAssertEqual(endpoint.url, "https://Studio.tail13013.ts.net/v1/diagnostics")
        XCTAssertEqual(endpoint.host, "studio.tail13013.ts.net")
        XCTAssertTrue(endpoint.looksPrivate)
    }

    func testAPublicLookingEndpointIsMarkedNotPrivateSoTheGateWantsAnAcknowledgement() throws {
        UserDefaults.standard.set("https://logs.example.com/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        let settings = DiagnosticsShipper.currentSettings()
        XCTAssertEqual(settings.endpoint?.looksPrivate, false)
        XCTAssertEqual(
            DiagnosticsGate.decide(
                enabled: true, endpointHost: settings.endpoint?.host,
                endpointLooksPrivate: settings.endpoint?.looksPrivate ?? false, acknowledgedHost: settings.acknowledgedHost
            ),
            .blocked(.publicEndpointNotAcknowledged)
        )
        UserDefaults.standard.set("logs.example.com", forKey: MuesliPreferences.diagnosticsAcknowledgedHostKey)
        XCTAssertEqual(DiagnosticsShipper.currentSettings().acknowledgedHost, "logs.example.com")
    }

    func testTheDiagnosticsServerFieldWinsOverAISummariesAndSettingsSeeTheSameURL() throws {
        UserDefaults.standard.set("https://summaries.tail13013.ts.net/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        UserDefaults.standard.set("https://logs.tail13013.ts.net/v1/", forKey: MuesliPreferences.diagnosticsEndpointURLKey)
        let endpoint = try XCTUnwrap(DiagnosticsShipper.currentSettings().endpoint)
        XCTAssertEqual(endpoint.url, "https://logs.tail13013.ts.net/v1/diagnostics")
        let shown = DiagnosticsServerResolver.resolve(
            override: MuesliPreferences.diagnosticsEndpointURL, aiSummariesBaseURL: MuesliPreferences.customLLMBaseURL
        ).server
        XCTAssertEqual(shown?.url.absoluteString, endpoint.url, "the screen and the uploader share one resolution")
    }

    func testABadDiagnosticsServerFieldMeansNoEndpointEvenWithAGoodAISummariesServer() {
        UserDefaults.standard.set("https://summaries.tail13013.ts.net/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        UserDefaults.standard.set("http://logs.tail13013.ts.net/v1", forKey: MuesliPreferences.diagnosticsEndpointURLKey)
        XCTAssertNil(DiagnosticsShipper.currentSettings().endpoint)
    }

    func testAPublicDiagnosticsServerNeedsAnAcknowledgementForItsHost() throws {
        UserDefaults.standard.set("https://summaries.tail13013.ts.net/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        UserDefaults.standard.set("https://logs.example.com", forKey: MuesliPreferences.diagnosticsEndpointURLKey)
        let settings = DiagnosticsShipper.currentSettings()
        let endpoint = try XCTUnwrap(settings.endpoint)
        XCTAssertFalse(endpoint.looksPrivate)
        XCTAssertEqual(
            DiagnosticsGate.decide(
                enabled: true, endpointHost: endpoint.host, endpointLooksPrivate: endpoint.looksPrivate,
                acknowledgedHost: settings.acknowledgedHost
            ),
            .blocked(.publicEndpointNotAcknowledged)
        )
    }

    func testTheDeviceIDIsARandomUUIDKeptUntilReset() {
        let first = MuesliPreferences.diagnosticsDeviceID
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(MuesliPreferences.diagnosticsDeviceID, first)
        let second = MuesliPreferences.resetDiagnosticsDeviceID()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(MuesliPreferences.diagnosticsDeviceID, second)
    }

    func testTheEnvelopeFieldsTheAppSuppliesPassTheSameRulesAsLogValues() {
        let info = DiagnosticsShipper.deviceInfo()
        XCTAssertTrue(DiagnosticsValueRule.uuid.accepts(info.deviceID))
        XCTAssertTrue(DiagnosticsValueRule.version.accepts(info.iosVersion), info.iosVersion)
        XCTAssertTrue(DiagnosticsValueRule.version.accepts(info.appVersion), info.appVersion)
        XCTAssertTrue(DiagnosticsValueRule.version.accepts(info.appBuild), info.appBuild)
        XCTAssertTrue(ThermalLevel.allCases.map(\.rawValue).contains(info.thermalState))
    }

    func testTheStateFileRoundTripsAndClearDeletesIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)/upload-state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DiagnosticsFileStateStore(url: url)
        XCTAssertNil(store.load())

        var state = Muesli.DiagnosticsUploadState()
        state.nextSeq = 7
        state.seen = ["a", "b"]
        state.target = Muesli.DiagnosticsTargetRecord(endpoint: "https://studio.example.ts.net/v1/diagnostics", keyFingerprint: "abcd")
        state.stopped = .keyRejected
        store.save(state)
        XCTAssertEqual(store.load(), state)

        store.clear()
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheStateFileNeverHoldsTheAPIKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)/upload-state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = "super-secret-bearer-token"
        var state = Muesli.DiagnosticsUploadState()
        state.target = Muesli.DiagnosticsTargetRecord(endpoint: "https://studio.example.ts.net/v1/diagnostics", keyFingerprint: DiagnosticsKeyFingerprint.of(key))
        DiagnosticsFileStateStore(url: url).save(state)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(key))
    }

    func testAnUnreadableStateFileReadsAsNoState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("upload-state.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(DiagnosticsFileStateStore(url: url).load())
    }
}
