import Foundation

/// An OpenAI-compatible server the user runs or trusts, such as a home server reached over Tailscale.
enum CustomLLMEndpoint {
    private static let chatSuffix = "/chat/completions"
    private static let transcriptionsSuffix = "/audio/transcriptions"

    /// Accepts a base URL (`https://host/v1`) or a pasted full path, and returns the chat completions URL.
    /// Only https is accepted, so credentials and transcripts never travel in the clear.
    static func chatCompletionsURL(from value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(chatSuffix) { text.removeLast(chatSuffix.count) }
        guard let components = URLComponents(string: text + chatSuffix),
              components.scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// The speech-to-text route next to the chat route, for remote transcription. Same rules as the chat URL.
    static func transcriptionsURL(from value: String) -> URL? {
        nil
    }
}
