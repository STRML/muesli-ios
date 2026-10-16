import Foundation

/// Runs on-device transcription and, when allowed, the remote one beside it, and picks one text.
/// Placeholder: the naive version that always asks the remote first.
struct RemoteTranscriptionOrchestrator: Sendable {
    typealias Probe = @Sendable () async -> RemoteProbeOutcome
    typealias Upload = @Sendable (URL) async throws -> String
    typealias Prewarm = @Sendable () async -> Void
    typealias Log = @Sendable (String) -> Void

    enum Source: Sendable, Equatable { case onDevice, remote }

    struct Outcome: Sendable, Equatable {
        let text: String
        let source: Source
    }

    let timing: RemoteTranscriptionTiming
    let probe: Probe
    let upload: Upload
    let prewarm: Prewarm
    let log: Log

    init(
        timing: RemoteTranscriptionTiming = .standard,
        probe: @escaping Probe,
        upload: @escaping Upload,
        prewarm: @escaping Prewarm = {},
        log: @escaping Log = { _ in }
    ) {
        self.timing = timing
        self.probe = probe
        self.upload = upload
        self.prewarm = prewarm
        self.log = log
    }

    func prewarmIfEligible(context: RemoteRequestContext) async {
        await prewarm()
    }

    func transcribe(
        audioURL: URL,
        context: RemoteRequestContext,
        local: @escaping @Sendable () async throws -> String
    ) async throws -> Outcome {
        _ = await probe()
        if let text = try? await upload(audioURL) { return Outcome(text: text, source: .remote) }
        return Outcome(text: try await local(), source: .onDevice)
    }
}
