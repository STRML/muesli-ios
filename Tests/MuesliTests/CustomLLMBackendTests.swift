import XCTest
@testable import Muesli

final class CustomLLMBackendTests: XCTestCase {
    func testEndpointAppendsChatCompletionsToABaseURL() {
        XCTAssertEqual(
            CustomLLMEndpoint.chatCompletionsURL(from: "https://studio.example.ts.net/v1")?.absoluteString,
            "https://studio.example.ts.net/v1/chat/completions"
        )
        XCTAssertEqual(
            CustomLLMEndpoint.chatCompletionsURL(from: "  https://studio.example.ts.net/v1/  ")?.absoluteString,
            "https://studio.example.ts.net/v1/chat/completions"
        )
        XCTAssertEqual(
            CustomLLMEndpoint.chatCompletionsURL(from: "https://studio.example.ts.net")?.absoluteString,
            "https://studio.example.ts.net/chat/completions"
        )
    }

    func testEndpointAcceptsAPastedFullPathWithoutDoublingIt() {
        XCTAssertEqual(
            CustomLLMEndpoint.chatCompletionsURL(from: "https://studio.example.ts.net/v1/chat/completions")?.absoluteString,
            "https://studio.example.ts.net/v1/chat/completions"
        )
    }

    func testEndpointRejectsEmptyNonHTTPSAndUnparseableValues() {
        XCTAssertNil(CustomLLMEndpoint.chatCompletionsURL(from: ""))
        XCTAssertNil(CustomLLMEndpoint.chatCompletionsURL(from: "   "))
        XCTAssertNil(CustomLLMEndpoint.chatCompletionsURL(from: "http://studio.example.ts.net/v1"))
        XCTAssertNil(CustomLLMEndpoint.chatCompletionsURL(from: "studio.example.ts.net/v1"))
        XCTAssertNil(CustomLLMEndpoint.chatCompletionsURL(from: "https://"))
    }

    func testBackendIdentityAndTelemetryNeverCarryTheModelName() {
        XCTAssertEqual(MeetingSummaryBackend(rawValue: "custom_llm"), .customLLM)
        XCTAssertEqual(MeetingSummaryBackend.customLLM.label, "Custom")
        XCTAssertEqual(
            SummaryModelPreset.telemetryIdentifier(for: "private-model-name", backend: .customLLM),
            "custom"
        )
    }

    func testPreferencesTrimTheStoredURLAndModel() {
        let defaults = UserDefaults.standard
        let keys = [MuesliPreferences.customLLMBaseURLKey, MuesliPreferences.customLLMModelKey]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("  https://studio.example.ts.net/v1 \n", forKey: MuesliPreferences.customLLMBaseURLKey)
        defaults.set(" some-model ", forKey: MuesliPreferences.customLLMModelKey)
        XCTAssertEqual(MuesliPreferences.customLLMBaseURL, "https://studio.example.ts.net/v1")
        XCTAssertEqual(MuesliPreferences.customLLMModel, "some-model")
    }

    func testSummarizeRefusesBeforeAnyRequestWhenTheURLOrModelIsMissing() async {
        let defaults = UserDefaults.standard
        let keys = [
            MuesliPreferences.meetingSummaryBackendKey,
            MuesliPreferences.customLLMBaseURLKey,
            MuesliPreferences.customLLMModelKey,
        ]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(MeetingSummaryBackend.customLLM.rawValue, forKey: MuesliPreferences.meetingSummaryBackendKey)

        defaults.set("", forKey: MuesliPreferences.customLLMBaseURLKey)
        defaults.set("some-model", forKey: MuesliPreferences.customLLMModelKey)
        await assertNotConfigured()

        defaults.set("https://studio.example.ts.net/v1", forKey: MuesliPreferences.customLLMBaseURLKey)
        defaults.set("", forKey: MuesliPreferences.customLLMModelKey)
        await assertNotConfigured()
    }

    private func assertNotConfigured(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await MeetingSummaryClient.summarize(transcript: "hello", meetingTitle: "t")
            XCTFail("expected missingCredentials", file: file, line: line)
        } catch MeetingSummaryError.missingCredentials(let backend) {
            XCTAssertEqual(backend, .customLLM, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }
}
