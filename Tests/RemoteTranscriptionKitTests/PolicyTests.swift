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
}
