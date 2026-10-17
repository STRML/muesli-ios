import Foundation
import os

/// Binds the remote transcription logic to the app's settings: the Custom LLM address, its Keychain key and the
/// opt-in. Everything that decides is in `RemoteTranscriptionOrchestrator`; this only reads the configuration.
/// Audio goes to the user's configured endpoint and nowhere else, and neither it nor the key is ever logged.
actor RemoteTranscriptionService {
    static let shared = RemoteTranscriptionService()

    /// Stored on transcripts and results whose text came from the endpoint.
    static let engineIdentifier = "remote-custom-llm"

    private static let logger = Logger(subsystem: MuesliAppConstants.bundleIdentifier, category: "remote-transcription")

    private let session = RemoteTranscriptionClient.makeSession()
    private var cached: (fingerprint: String, orchestrator: RemoteTranscriptionOrchestrator)?

    /// Called when a recording starts, so the probe has answered by the time it ends.
    func prewarm(origin: RemoteDictationOrigin, isPrivateContent: Bool = false) async {
        let context = Self.context(origin: origin, isPrivateContent: isPrivateContent)
        guard let orchestrator = orchestrator() else { return }
        await orchestrator.prewarmIfEligible(context: context)
    }

    /// Transcribes on the phone with `local` and, when allowed, on the endpoint beside it.
    func transcribe(
        audioURL: URL,
        origin: RemoteDictationOrigin,
        isPrivateContent: Bool = false,
        local: @escaping @Sendable () async throws -> String
    ) async throws -> RemoteTranscriptionOrchestrator.Outcome {
        let context = Self.context(origin: origin, isPrivateContent: isPrivateContent)
        guard let orchestrator = orchestrator() else {
            return .init(text: try await local(), source: .onDevice)
        }
        return try await orchestrator.transcribe(audioURL: audioURL, context: context, local: local)
    }

    /// The Settings Test button: a fresh probe of the typed address, not the cached one, with room to show a slow answer.
    static func test(baseURL: String, apiKey: String) async -> RemoteProbeOutcome {
        guard let endpoint = CustomLLMEndpoint.transcriptionsURL(from: baseURL) else { return .unreachable }
        let session = RemoteTranscriptionClient.makeSession()
        defer { session.finishTasksAndInvalidate() }
        return await RemoteTranscriptionClient(endpoint: endpoint, apiKey: apiKey, session: session).probe(timeout: 5)
    }

    private static func context(origin: RemoteDictationOrigin, isPrivateContent: Bool) -> RemoteRequestContext {
        RemoteRequestContext(
            settingEnabled: MuesliPreferences.isRemoteProcessingActive,
            endpointConfigured: MuesliPreferences.hasCustomLLMEndpoint,
            origin: origin,
            // The phone has no private meetings or folders yet; the flag exists so they can never be sent.
            isPrivateContent: isPrivateContent
        )
    }

    /// The endpoint hears the same trimmed copy the on-device model does, and its text goes through the same
    /// hallucinated-tail filter: Qwen3-ASR and Granite are not immune to inventing a sign-off over silence. Guarding
    /// the upload, not the whole race, keeps each side to one analysis and one `transcribe.trimmed` event.
    private static func guardedUpload(_ client: RemoteTranscriptionClient, audioURL: URL) async throws -> String {
        let outcome = try await ClipSilenceGuard.run(
            audioURL: audioURL,
            log: { KeyboardDiagnosticsLog.record($0, $1.merging(["text_source": "remote"]) { $1 }) }
        ) { .init(text: try await client.transcribe(audioURL: $0)) }
        return outcome.text
    }

    private func orchestrator() -> RemoteTranscriptionOrchestrator? {
        guard let endpoint = CustomLLMEndpoint.transcriptionsURL(from: MuesliPreferences.customLLMBaseURL) else {
            cached = nil
            return nil
        }
        let apiKey = MeetingSummaryClient.storedCustomLLMAPIKey()
        let fingerprint = "\(endpoint.absoluteString)\n\(apiKey)"
        if let cached, cached.fingerprint == fingerprint { return cached.orchestrator }

        let timing = RemoteTranscriptionTiming.standard
        let client = RemoteTranscriptionClient(endpoint: endpoint, apiKey: apiKey, session: session)
        let probeCache = RemoteProbeCache(ttl: 30) { await client.probe(timeout: timing.probeThreshold) }
        let orchestrator = RemoteTranscriptionOrchestrator(
            timing: timing,
            probe: { await probeCache.outcome() },
            upload: { try await Self.guardedUpload(client, audioURL: $0) },
            prewarm: { await probeCache.prewarm() },
            log: { Self.logger.notice("\($0, privacy: .public)") },
            invalidateProbe: { await probeCache.invalidate() }
        )
        cached = (fingerprint, orchestrator)
        return orchestrator
    }
}
