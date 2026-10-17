import Foundation

struct DiagnosticsEngineConfig: Sendable, Equatable {
    var maxBatchEvents = 100
    var maxQueueBytes = 2 * 1024 * 1024
    var maxAge: TimeInterval = 7 * 24 * 3600
    var baseBackoff: TimeInterval = 30
    var maxBackoff: TimeInterval = 15 * 60
    var maxBatchesPerFlush = 5
    var seenLimit = 1_500

    static let standard = DiagnosticsEngineConfig()
}

enum DiagnosticsStopReason: String, Codable, Equatable, Sendable {
    /// The server answered 401 or 403: the key is wrong.
    case keyRejected
    /// The server answered 404 or 405: it has no diagnostics route (yet).
    case routeMissing
}

struct DiagnosticsQueuedEvent: Codable, Equatable, Sendable {
    var event: DiagnosticsEvent
    var queuedAt: Date
    var bytes: Int
}

/// A batch that has been cut and numbered. It is stored with its id before the first send and resent unchanged
/// until the server acknowledges it, so the server can drop a duplicate by the id after a lost response.
struct DiagnosticsSealedBatch: Codable, Equatable, Sendable {
    var id: String
    var seq: Int
    var sealedAt: Date
    var droppedEvents: Int
    var droppedFields: Int
    var rejectedEvents: Int
    var events: [DiagnosticsQueuedEvent]
}

struct DiagnosticsUploadState: Codable, Equatable, Sendable {
    var schema = 1
    var target: DiagnosticsTargetRecord?
    /// Ids of log lines already queued or sent, oldest first and bounded.
    var seen: [String] = []
    /// Ids of log lines that were in the log when diagnostics was switched on. Not sent, unless Send now.
    var baseline: [String] = []
    var queue: [DiagnosticsQueuedEvent] = []
    var inFlight: DiagnosticsSealedBatch?
    var nextSeq = 1
    /// Events lost to the queue's size or age cap, not yet reported to the server.
    var droppedEvents = 0
    /// Fields the allowlist removed from events that were kept, not yet reported.
    var droppedFields = 0
    /// Whole events the allowlist refused (unknown name, bad process or timestamp), not yet reported.
    var rejectedEvents = 0
    var failures = 0
    var retryNotBefore: Date?
    var stopped: DiagnosticsStopReason?
    var lastUploadAt: Date?
    var lastError: String?
}

struct DiagnosticsTargetRecord: Codable, Equatable, Sendable {
    var endpoint: String
    var keyFingerprint: String
}

/// What the app knows about the endpoint, handed to the engine on every pass.
struct DiagnosticsEndpoint: Equatable, Sendable {
    var url: String
    var host: String
    var looksPrivate: Bool
    /// A truncated hash of the API key, never the key.
    var keyFingerprint: String
}

struct DiagnosticsRunSettings: Equatable, Sendable {
    var enabled: Bool
    var endpoint: DiagnosticsEndpoint?
    var acknowledgedHost: String?
}

struct DiagnosticsUploadStatus: Equatable, Sendable {
    var queuedEvents: Int
    var lastUploadAt: Date?
    var stopped: DiagnosticsStopReason?
    var lastError: String?
    var retryNotBefore: Date?
}

enum DiagnosticsFlushReport: Equatable, Sendable {
    case idle
    case sent(batches: Int, events: Int)
    case backingOff(until: Date)
    case stopped(DiagnosticsStopReason)
    case failed(String)
    /// Diagnostics are not allowed to leave the phone right now.
    case blocked(DiagnosticsGate.Reason)
    /// The app ran out of background time (or the task was cancelled) mid-send; the batch stays queued, unpenalized.
    case interrupted
}

protocol DiagnosticsStateStore: Sendable {
    func load() -> DiagnosticsUploadState?
    func save(_ state: DiagnosticsUploadState)
    func clear()
}

protocol DiagnosticsClock: Sendable {
    func now() -> Date
}

enum DiagnosticsTransportResult: Equatable, Sendable {
    case status(Int)
    /// No response: offline, timed out, refused, TLS failure. The code is the `URLError` raw value or 0.
    case networkFailure(code: Int)
    /// The send was cancelled before it finished (background time ran out).
    case cancelled
}

protocol DiagnosticsTransport: Sendable {
    /// Posts `body` to exactly `target.endpoint`, the address the batch was gathered for, with `batchID` as the
    /// idempotency key. If the current key no longer matches `target.keyFingerprint` (settings changed since the
    /// pass began) it returns `.cancelled` instead of sending the old queue with the new credentials.
    func send(body: Data, batchID: String, target: DiagnosticsTargetRecord) async -> DiagnosticsTransportResult
}
