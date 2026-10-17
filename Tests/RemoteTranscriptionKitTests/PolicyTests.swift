import XCTest
@testable import RemoteTranscriptionKit

/// Matrix rows 1, 2, 10, 12 and the settings copy. Pure decisions, no I/O.
final class PolicyTests: XCTestCase {
    private func context(
        enabled: Bool = true,
        endpoint: Bool = true,
        origin: RemoteDictationOrigin = .app,
        isPrivate: Bool = false
    ) -> RemoteRequestContext {
        RemoteRequestContext(
            settingEnabled: enabled, endpointConfigured: endpoint, origin: origin, isPrivateContent: isPrivate
        )
    }

    func testRow01SettingOffIsNeverEligible() {
        XCTAssertEqual(RemoteTranscriptionPolicy.eligibility(for: context(enabled: false)), .skip(.settingOff))
        XCTAssertEqual(
            RemoteTranscriptionPolicy.eligibility(for: context(enabled: false, endpoint: false)),
            .skip(.settingOff)
        )
    }

    func testRow02NoEndpointIgnoresAStaleSetting() {
        XCTAssertEqual(RemoteTranscriptionPolicy.eligibility(for: context(enabled: true, endpoint: false)), .skip(.noEndpoint))
    }

    func testRow16PrivateLookingEndpointsGetNoWarningAndPublicOnesDo() {
        let privateHosts = [
            "https://studio.tail13013.ts.net/v1", "http://127.0.0.1:11240/v1", "http://localhost:8080",
            "http://192.168.1.20/v1", "http://10.0.0.5", "http://172.16.4.2", "http://172.31.255.1",
            "http://100.64.0.1", "http://100.127.9.9", "http://studio.local/v1", "http://[::1]:8080",
            "http://[fd12:3456::1]/v1", "http://169.254.10.10",
        ]
        for url in privateHosts {
            XCTAssertNil(RemoteTranscriptionPolicy.publicEndpointWarning(baseURL: url), url)
        }
        let publicHosts = [
            "https://api.openai.com/v1", "https://openrouter.ai/api/v1", "https://example.com",
            "http://172.32.0.1", "http://100.128.0.1", "http://8.8.8.8", "https://ts.net.evil.com/v1",
        ]
        for url in publicHosts {
            XCTAssertEqual(
                RemoteTranscriptionPolicy.publicEndpointWarning(baseURL: url),
                RemoteTranscriptionPolicy.publicEndpointWarningText,
                url
            )
        }
        XCTAssertNil(RemoteTranscriptionPolicy.publicEndpointWarning(baseURL: "not a url"))
    }

    func testRow15SwitchingAwayFromCustomLLMStopsUploadsTheHiddenCheckboxWouldKeepSending() {
        XCTAssertTrue(RemoteTranscriptionPolicy.isSettingActive(stored: true, endpointConfigured: true, summaryBackendIsCustomLLM: true))
        XCTAssertFalse(RemoteTranscriptionPolicy.isSettingActive(stored: true, endpointConfigured: true, summaryBackendIsCustomLLM: false))
        XCTAssertFalse(RemoteTranscriptionPolicy.isSettingActive(stored: true, endpointConfigured: false, summaryBackendIsCustomLLM: true))
        XCTAssertFalse(RemoteTranscriptionPolicy.isSettingActive(stored: false, endpointConfigured: true, summaryBackendIsCustomLLM: true))
    }

    func testRow02CheckboxIsShownOnlyWhenAnEndpointIsSet() {
        XCTAssertTrue(RemoteTranscriptionPolicy.showsCheckbox(endpointConfigured: true))
        XCTAssertFalse(RemoteTranscriptionPolicy.showsCheckbox(endpointConfigured: false))
    }

    func testRow10KeyboardWithoutFullAccessIsNeverEligible() {
        XCTAssertEqual(
            RemoteTranscriptionPolicy.eligibility(for: context(origin: .keyboard(hasFullAccess: false))),
            .skip(.keyboardNeedsFullAccess)
        )
    }

    func testRow10KeyboardWithFullAccessAndTheAppAreEligible() {
        XCTAssertEqual(RemoteTranscriptionPolicy.eligibility(for: context(origin: .keyboard(hasFullAccess: true))), .eligible)
        XCTAssertEqual(RemoteTranscriptionPolicy.eligibility(for: context(origin: .app)), .eligible)
    }

    func testRow10KeyboardBannerAppearsOnlyWhenRemoteIsOnAndFullAccessIsOff() {
        XCTAssertEqual(
            RemoteTranscriptionPolicy.keyboardBanner(remoteProcessingEnabled: true, hasFullAccess: false),
            "Full Access needed for remote processing"
        )
        XCTAssertNil(RemoteTranscriptionPolicy.keyboardBanner(remoteProcessingEnabled: true, hasFullAccess: true))
        XCTAssertNil(RemoteTranscriptionPolicy.keyboardBanner(remoteProcessingEnabled: false, hasFullAccess: false))
    }

    func testRow10OnlyTheKeyboardExtensionNeedsFullAccessNotTheActionButton() {
        typealias Origin = RemoteDictationOrigin
        XCTAssertEqual(Origin.resolve(startedFromKeyboard: false, isActionButton: false, keyboardHasFullAccess: false), .app)
        XCTAssertEqual(Origin.resolve(startedFromKeyboard: true, isActionButton: true, keyboardHasFullAccess: nil), .app)
        XCTAssertEqual(
            Origin.resolve(startedFromKeyboard: true, isActionButton: false, keyboardHasFullAccess: true),
            .keyboard(hasFullAccess: true)
        )
        XCTAssertEqual(
            Origin.resolve(startedFromKeyboard: true, isActionButton: false, keyboardHasFullAccess: false),
            .keyboard(hasFullAccess: false)
        )
        XCTAssertEqual(
            Origin.resolve(startedFromKeyboard: true, isActionButton: false, keyboardHasFullAccess: nil),
            .keyboard(hasFullAccess: false),
            "an unknown Full Access state fails closed"
        )
    }

    func testRow12PrivateContentIsNeverRemoteFromAnyOrigin() {
        XCTAssertEqual(RemoteTranscriptionPolicy.eligibility(for: context(isPrivate: true)), .skip(.privateContent))
        XCTAssertEqual(
            RemoteTranscriptionPolicy.eligibility(for: context(origin: .keyboard(hasFullAccess: true), isPrivate: true)),
            .skip(.privateContent)
        )
    }

    func testSettingsCopyIsVerbatim() {
        XCTAssertEqual(RemoteTranscriptionPolicy.checkboxTitle, "Use remote processing for higher accuracy")
        XCTAssertEqual(
            RemoteTranscriptionPolicy.footnote,
            "Used when it can be done quickly. This endpoint gets full access to your recordings. Turn it on only if you trust the remote machine or control it completely."
        )
    }

    func testStandardTimingMatchesTheIssue() {
        XCTAssertEqual(RemoteTranscriptionTiming.standard.probeThreshold, 0.4)
        XCTAssertEqual(RemoteTranscriptionTiming.standard.resultBudget, 3)
        XCTAssertLessThanOrEqual(RemoteTranscriptionTiming.standard.unresolvedProbeGrace, 0.1)
    }

    // MARK: Endpoint

    func testTranscriptionsURLFollowsEveryFormOfTheAddress() {
        XCTAssertEqual(
            CustomLLMEndpoint.transcriptionsURL(from: "https://studio.example.ts.net/v1")?.absoluteString,
            "https://studio.example.ts.net/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            CustomLLMEndpoint.transcriptionsURL(from: "  https://studio.example.ts.net/v1/  ")?.absoluteString,
            "https://studio.example.ts.net/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            CustomLLMEndpoint.transcriptionsURL(from: "https://studio.example.ts.net")?.absoluteString,
            "https://studio.example.ts.net/audio/transcriptions"
        )
        XCTAssertEqual(
            CustomLLMEndpoint.transcriptionsURL(from: "https://studio.example.ts.net/v1/chat/completions")?.absoluteString,
            "https://studio.example.ts.net/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            CustomLLMEndpoint.transcriptionsURL(from: "https://studio.example.ts.net/v1/audio/transcriptions")?.absoluteString,
            "https://studio.example.ts.net/v1/audio/transcriptions"
        )
    }

    func testTranscriptionsURLRefusesAnythingButHTTPS() {
        XCTAssertNil(CustomLLMEndpoint.transcriptionsURL(from: ""))
        XCTAssertNil(CustomLLMEndpoint.transcriptionsURL(from: "http://studio.example.ts.net/v1"))
        XCTAssertNil(CustomLLMEndpoint.transcriptionsURL(from: "studio.example.ts.net/v1"))
        XCTAssertNil(CustomLLMEndpoint.transcriptionsURL(from: "https://"))
    }

    func testDiagnosticsURLFollowsEveryFormOfTheAddress() {
        for address in [
            "https://studio.tail13013.ts.net/v1",
            "  https://studio.tail13013.ts.net/v1/  ",
            "https://studio.tail13013.ts.net/v1/chat/completions",
            "https://studio.tail13013.ts.net/v1/audio/transcriptions",
            "https://studio.tail13013.ts.net/v1/diagnostics",
        ] {
            XCTAssertEqual(
                CustomLLMEndpoint.diagnosticsURL(from: address)?.absoluteString,
                "https://studio.tail13013.ts.net/v1/diagnostics",
                address
            )
        }
    }

    func testDiagnosticsURLRefusesAnythingButHTTPS() {
        XCTAssertNil(CustomLLMEndpoint.diagnosticsURL(from: ""))
        XCTAssertNil(CustomLLMEndpoint.diagnosticsURL(from: "http://studio.tail13013.ts.net/v1"))
        XCTAssertNil(CustomLLMEndpoint.diagnosticsURL(from: "studio.tail13013.ts.net/v1"))
        XCTAssertNil(CustomLLMEndpoint.diagnosticsURL(from: "https://"))
    }
}
