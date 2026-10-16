import Foundation

enum RemoteTranscriptionError: Error, Equatable {
    case fileTooLarge
    case unreadableAudio
    case httpStatus(Int)
    case unusableResponse
    case transport(Int)

    /// What goes in the log. Never the URL, the key, or the audio.
    var logCategory: String { "" }
}

/// OpenAI-compatible `POST .../audio/transcriptions`, sent to the user's own Custom LLM endpoint only.
struct RemoteTranscriptionClient: Sendable {
    let endpoint: URL
    let apiKey: String
    let model: String
    let session: URLSession

    init(endpoint: URL, apiKey: String, model: String = RemoteTranscriptionPolicy.asrModel, session: URLSession) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// One session for the probe and the upload, so the warmed connection is reused, and one that never follows a
    /// redirect: a 307 would re-send the recording to whatever host it names.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration)
    }

    func probe(timeout: TimeInterval) async -> RemoteProbeOutcome {
        .unreachable
    }

    func transcribe(audioURL: URL) async throws -> String {
        throw RemoteTranscriptionError.unusableResponse
    }
}
