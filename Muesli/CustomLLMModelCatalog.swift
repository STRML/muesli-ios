import Foundation

enum CustomLLMModelCatalogError: LocalizedError, Equatable {
    case invalidEndpoint
    case unauthorized
    case http(Int)
    case unreachable(String)
    case unreadable
    case noModels

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "the server URL is not a valid https address"
        case .unauthorized:
            "the server refused the API key"
        case .http(let status):
            "the server answered HTTP \(status)"
        case .unreachable(let message):
            "the server is unreachable (\(message))"
        case .unreadable:
            "the server did not return a model list"
        case .noModels:
            "the server lists no models"
        }
    }
}

/// Asks a Custom LLM server which models it serves, so Settings can offer a dropdown instead of a
/// free-text field. OpenAI-compatible servers answer `GET .../v1/models`.
enum CustomLLMModelCatalog {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Short: the picker waits on this while the user is looking at Settings.
    static let timeout: TimeInterval = 10

    /// The models URL next to the chat endpoint the app already resolves, so every form of the address the
    /// user may type (base URL, `/v1`, the full `chat/completions` path) lists from the same place.
    static func modelsURL(from baseURL: String) -> URL? {
        guard let chat = CustomLLMEndpoint.chatCompletionsURL(from: baseURL),
              var components = URLComponents(url: chat, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        parts.removeLast(2) // chat/completions, which chatCompletionsURL always appends
        components.path = "/" + (parts + ["models"]).joined(separator: "/")
        components.query = nil
        return components.url
    }

    static func fetch(
        baseURL: String,
        apiKey: String,
        transport: Transport = { try await CustomLLMSession.shared.data(for: $0) }
    ) async throws -> [String] {
        guard let url = modelsURL(from: baseURL) else { throw CustomLLMModelCatalogError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CustomLLMModelCatalogError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CustomLLMModelCatalogError.unreadable }
        switch http.statusCode {
        case 200..<300:
            return try parseModelIDs(from: data)
        case 401, 403:
            throw CustomLLMModelCatalogError.unauthorized
        default:
            throw CustomLLMModelCatalogError.http(http.statusCode)
        }
    }

    /// Understands OpenAI and LM Studio (`data[].id`), Ollama (`models[].name`) and a bare array.
    static func parseModelIDs(from data: Data) throws -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw CustomLLMModelCatalogError.unreadable
        }
        let entries: [Any]
        if let list = json as? [Any] {
            entries = list
        } else if let object = json as? [String: Any],
                  let list = (object["data"] as? [Any]) ?? (object["models"] as? [Any]) {
            entries = list
        } else {
            throw CustomLLMModelCatalogError.unreadable
        }

        var seen = Set<String>()
        var ids: [String] = []
        for entry in entries {
            let raw: String?
            if let text = entry as? String {
                raw = text
            } else if let object = entry as? [String: Any] {
                raw = (object["id"] as? String) ?? (object["name"] as? String) ?? (object["model"] as? String)
            } else {
                raw = nil
            }
            guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { throw CustomLLMModelCatalogError.noModels }
        return ids
    }

    /// What the dropdown offers: the listed models, plus the saved one when the server no longer lists it, so
    /// opening Settings never swaps a working model for another.
    static func pickerChoices(listed: [String], current: String) -> [String] {
        let saved = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty, !listed.contains(saved) else { return listed }
        return [saved] + listed
    }
}
