import Foundation

/// An OpenAI-compatible server the user runs or trusts, such as a home server reached over Tailscale.
enum CustomLLMEndpoint {
    private static let chatSuffix = "/chat/completions"
    private static let transcriptionsSuffix = "/audio/transcriptions"
    private static let diagnosticsSuffix = "/diagnostics"

    /// Accepts a base URL (`https://host/v1`) or a pasted full path, and returns the chat completions URL.
    /// Only https is accepted, so credentials and transcripts never travel in the clear.
    static func chatCompletionsURL(from value: String) -> URL? {
        url(from: value, appending: chatSuffix)
    }

    /// The speech-to-text route next to the chat route, for remote transcription. Same rules as the chat URL.
    static func transcriptionsURL(from value: String) -> URL? {
        url(from: value, appending: transcriptionsSuffix)
    }

    /// Where opt-in diagnostics are posted: the same server, `<base>/diagnostics`. Same https-only rule.
    static func diagnosticsURL(from value: String) -> URL? {
        url(from: value, appending: diagnosticsSuffix)
    }

    private static func url(from value: String, appending route: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        for known in [chatSuffix, transcriptionsSuffix, diagnosticsSuffix] where text.hasSuffix(known) {
            text.removeLast(known.count)
        }
        guard let components = URLComponents(string: text + route),
              components.scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }
}
