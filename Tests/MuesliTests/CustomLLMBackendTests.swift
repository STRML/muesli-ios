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

    // MARK: Anthropic, and Quill on the chosen provider

    private func withProvider(
        _ backend: MeetingSummaryBackend,
        anthropicKey: String,
        _ body: () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MuesliPreferences.meetingSummaryBackendKey)
        let originalKey = MeetingSummaryClient.storedAnthropicAPIKey()
        defer {
            if let original { defaults.set(original, forKey: MuesliPreferences.meetingSummaryBackendKey) }
            else { defaults.removeObject(forKey: MuesliPreferences.meetingSummaryBackendKey) }
            try? MeetingSummaryClient.saveAnthropicAPIKey(originalKey)
        }
        defaults.set(backend.rawValue, forKey: MuesliPreferences.meetingSummaryBackendKey)
        try? MeetingSummaryClient.saveAnthropicAPIKey(anthropicKey)
        try await body()
    }

    func testSummarizeOnAnthropicRefusesWithoutAKey() async {
        await withProvider(.anthropic, anthropicKey: "") {
            do {
                _ = try await MeetingSummaryClient.summarize(transcript: "hello", meetingTitle: "t")
                XCTFail("expected missingCredentials")
            } catch MeetingSummaryError.missingCredentials(let backend) {
                XCTAssertEqual(backend, .anthropic)
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    func testQuillIsOffUntilTheChosenProviderIsReady() async {
        await withProvider(.anthropic, anthropicKey: "") {
            XCTAssertFalse(MuesliPreferences.isVoiceRewriteConfigured)
            do {
                _ = try await MeetingSummaryClient.completeForQuill(system: "s", user: "u")
                XCTFail("expected notConfigured")
            } catch VoiceRewriteError.notConfigured {
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        await withProvider(.anthropic, anthropicKey: "sk-ant-test") {
            XCTAssertTrue(MuesliPreferences.isVoiceRewriteConfigured)
        }
    }

    func testQuillOnAnthropicSendsAMessagesRequestAndReadsTheText() async throws {
        URLProtocol.registerClass(AnthropicStubProtocol.self)
        defer { URLProtocol.unregisterClass(AnthropicStubProtocol.self) }
        AnthropicStubProtocol.reset()
        try await withProvider(.anthropic, anthropicKey: "sk-ant-test") {
            let text = try await MeetingSummaryClient.completeForQuill(system: "Rewrite only.", user: "make it shorter")
            XCTAssertEqual(text, "Rewritten.")
        }
        let request = try XCTUnwrap(AnthropicStubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(AnthropicStubProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, MuesliPreferences.model(for: .anthropic))
        XCTAssertEqual(body["system"] as? String, "Rewrite only.")
        XCTAssertNotNil(body["max_tokens"] as? Int)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "make it shorter")
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

/// Answers api.anthropic.com in-process: records the request and returns one text block.
private final class AnthropicStubProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let payload = Data(#"{"content":[{"type":"text","text":" Rewritten. "}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
