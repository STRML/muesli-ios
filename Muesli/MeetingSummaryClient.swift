import Foundation

enum MeetingSummaryError: Error, LocalizedError {
    case missingCredentials(MeetingSummaryBackend)
    case backendFailed(backend: String, statusCode: Int?, message: String)
    case emptyResponse(String)
    case requestFailed(backend: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let backend):
            "\(backend.label) is not configured."
        case let .backendFailed(backend, statusCode, message):
            "\(backend) could not generate meeting notes\(statusCode.map { " (HTTP \($0))" } ?? ""). \(message)"
        case .emptyResponse(let backend):
            "\(backend) returned an empty meeting summary."
        case let .requestFailed(backend, underlying):
            "\(backend) could not be reached. \(underlying.localizedDescription)"
        }
    }
}

enum MeetingSummaryClient {
    static let openRouterAPIKeyAccount = "openrouter_api_key"
    static let customLLMAPIKeyAccount = "custom_llm_api_key"
    static let anthropicAPIKeyAccount = "anthropic_api_key"

    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"
    private static let maxOutputTokens = 2500
    private static let keychain = KeychainStore(service: "\(MuesliAppConstants.bundleIdentifier).summary")

    private static let baseSummaryInstructions = """
    You are a meeting notes assistant. Given a raw meeting transcript, produce concise, professional markdown notes.
    Do not invent facts. Prefer concrete takeaways over filler. Capture owners only when they are actually mentioned.
    If a requested section has no content, write "None noted."
    """

    private static let titleInstructions = """
    Generate a short, descriptive meeting title (3-7 words) from this transcript.
    Return only the title text, with no quotes, prefix, or explanation.
    """

    static func storedOpenRouterAPIKey() -> String {
        (try? keychain.string(for: openRouterAPIKeyAccount)) ?? ""
    }

    static func saveOpenRouterAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: openRouterAPIKeyAccount)
        } else {
            try keychain.set(trimmed, for: openRouterAPIKeyAccount)
        }
    }

    static func storedCustomLLMAPIKey() -> String {
        (try? keychain.string(for: customLLMAPIKeyAccount)) ?? ""
    }

    static func saveCustomLLMAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: customLLMAPIKeyAccount)
        } else {
            try keychain.set(trimmed, for: customLLMAPIKeyAccount)
        }
    }

    static func storedAnthropicAPIKey() -> String {
        (try? keychain.string(for: anthropicAPIKeyAccount)) ?? ""
    }

    static func saveAnthropicAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: anthropicAPIKeyAccount)
        } else {
            try keychain.set(trimmed, for: anthropicAPIKeyAccount)
        }
    }

    /// One completion on the provider chosen in Settings, for voice rewrite (Quill). A short timeout: the user is
    /// waiting at the keyboard.
    static func completeForQuill(system: String, user: String) async throws -> String {
        guard MuesliPreferences.isVoiceRewriteConfigured else {
            throw VoiceRewriteError.notConfigured
        }
        return try await complete(
            backend: MuesliPreferences.meetingSummaryBackend,
            system: system,
            user: user,
            maxTokens: 8_000,
            timeout: 30
        )
    }

    static func summarize(
        transcript: String,
        meetingTitle: String,
        manualNotesToRetain: String? = nil
    ) async throws -> MeetingSummaryResult {
        let backend = MuesliPreferences.meetingSummaryBackend
        guard MuesliPreferences.isProviderConfigured(backend) else {
            throw MeetingSummaryError.missingCredentials(backend)
        }
        let notes = try await complete(
            backend: backend,
            system: baseSummaryInstructions,
            user: summaryPrompt(
                transcript: transcript,
                meetingTitle: meetingTitle,
                manualNotesToRetain: manualNotesToRetain
            ),
            maxTokens: maxOutputTokens,
            timeout: 60
        )
        let title = (try? await complete(
            backend: backend,
            system: titleInstructions,
            user: String(transcript.prefix(1500)),
            maxTokens: 80,
            timeout: 60
        ))?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\""))) ?? meetingTitle
        return MeetingSummaryResult(
            notes: notes,
            title: title,
            backend: backend,
            model: MuesliPreferences.model(for: backend)
        )
    }

    /// The one place a request is routed: summaries, titles and Quill all go through the provider config here.
    private static func complete(
        backend: MeetingSummaryBackend,
        system: String,
        user: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        let model = MuesliPreferences.model(for: backend)
        switch backend {
        case .customLLM:
            guard let url = CustomLLMEndpoint.chatCompletionsURL(from: MuesliPreferences.customLLMBaseURL),
                  !model.isEmpty
            else {
                throw MeetingSummaryError.missingCredentials(.customLLM)
            }
            return try await callChatCompletions(
                url: url,
                backend: "Custom",
                apiKey: storedCustomLLMAPIKey(),
                model: model,
                systemPrompt: system,
                userPrompt: user,
                maxTokens: maxTokens,
                extraHeaders: [:],
                timeout: timeout,
                session: CustomLLMSession.shared
            )
        case .openRouter:
            let apiKey = storedOpenRouterAPIKey()
            guard !apiKey.isEmpty else { throw MeetingSummaryError.missingCredentials(.openRouter) }
            return try await callChatCompletions(
                url: openRouterURL,
                backend: "OpenRouter",
                apiKey: apiKey,
                model: model,
                systemPrompt: system,
                userPrompt: user,
                maxTokens: maxTokens,
                extraHeaders: ["X-OpenRouter-Title": "Muesli"],
                timeout: timeout
            )
        case .anthropic:
            let apiKey = storedAnthropicAPIKey()
            guard !apiKey.isEmpty else { throw MeetingSummaryError.missingCredentials(.anthropic) }
            return try await callAnthropic(
                apiKey: apiKey,
                model: model,
                systemPrompt: system,
                userPrompt: user,
                maxTokens: maxTokens,
                timeout: timeout
            )
        case .chatGPT:
            do {
                let text = try await callWHAM(systemPrompt: system, userPrompt: user, model: model)
                guard !text.isEmpty else { throw MeetingSummaryError.emptyResponse("ChatGPT") }
                return text
            } catch {
                if error is MeetingSummaryError { throw error }
                throw MeetingSummaryError.requestFailed(backend: "ChatGPT", underlying: error)
            }
        }
    }

    static func failureNotes(
        transcript: String,
        meetingTitle: String,
        error: Error,
        manualNotes: String? = nil
    ) -> String {
        let writtenNotesSection = optionalNotesSection(
            header: "## Written Notes",
            notes: manualNotes,
            separatesHeaderAndBody: true
        )
        return """
        ## Summary failed

        Meeting: \(meetingTitle)

        Muesli could not generate structured meeting notes.

        \(error.localizedDescription)
        \(writtenNotesSection)

        ## Raw Transcript

        \(transcript)
        """
    }

    private static func summaryPrompt(
        transcript: String,
        meetingTitle: String,
        manualNotesToRetain: String?
    ) -> String {
        let template = MuesliPreferences.meetingTemplate
        let manualNotesSection = optionalNotesSection(
            header: "User-written notes to retain:",
            notes: manualNotesToRetain
        )
        return """
        Meeting title: \(meetingTitle)

        Meeting note template: \(template.label)

        Template guidance:
        \(template.instructions)
        \(manualNotesSection)

        Raw transcript:
        \(transcript)
        """
    }

    private static func optionalNotesSection(
        header: String,
        notes: String?,
        separatesHeaderAndBody: Bool = false
    ) -> String {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedNotes.isEmpty else { return "" }
        let separator = separatesHeaderAndBody ? "\n\n" : "\n"
        return """

        \(header)\(separator)\(trimmedNotes)
        """
    }

    private static func callChatCompletions(
        url: URL,
        backend: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        extraHeaders: [String: String],
        timeout: TimeInterval = 60,
        session: URLSession = .shared
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "max_tokens": maxTokens,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response, data: data, backend: backend)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = extractChatCompletionsText(from: json),
                  !text.isEmpty else {
                throw MeetingSummaryError.emptyResponse(backend)
            }
            return text
        } catch {
            if error is MeetingSummaryError {
                throw error
            }
            throw MeetingSummaryError.requestFailed(backend: backend, underlying: error)
        }
    }

    private static func callAnthropic(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        var request = URLRequest(url: anthropicURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Anthropic")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = extractAnthropicText(from: json),
                  !text.isEmpty else {
                throw MeetingSummaryError.emptyResponse("Anthropic")
            }
            return text
        } catch {
            if error is MeetingSummaryError { throw error }
            throw MeetingSummaryError.requestFailed(backend: "Anthropic", underlying: error)
        }
    }

    private static func extractAnthropicText(from payload: [String: Any]) -> String? {
        let blocks = payload["content"] as? [[String: Any]] ?? []
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func callWHAM(systemPrompt: String, userPrompt: String, model: String) async throws -> String {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": userPrompt],
                    ],
                ] as [String: Any],
            ],
        ]

        var request = URLRequest(url: whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let message = extractErrorMessage(from: errorData)
                ?? String(data: errorData, encoding: .utf8)
                ?? "unknown error"
            throw MeetingSummaryError.backendFailed(
                backend: "ChatGPT",
                statusCode: statusCode,
                message: String(message.prefix(800))
            )
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }
            if let type = json["type"] as? String,
               type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
        }
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, backend: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MeetingSummaryError.backendFailed(
                backend: backend,
                statusCode: httpResponse.statusCode,
                message: String(message.prefix(800))
            )
        }
    }

    private static func extractChatCompletionsText(from payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { entry -> String? in
                guard (entry["type"] as? String) == "text",
                      let text = entry["text"] as? String else {
                    return nil
                }
                return text
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? String(describing: error)
        }
        return (json["message"] as? String) ?? (json["detail"] as? String)
    }
}

struct MeetingSummaryResult {
    let notes: String
    let title: String
    let backend: MeetingSummaryBackend
    let model: String
}
