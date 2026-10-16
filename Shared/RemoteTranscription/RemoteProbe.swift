import Foundation

enum RemoteProbeOutcome: Sendable, Equatable {
    /// The transcription route answered. `latency` is the round trip in seconds.
    case reachable(latency: TimeInterval)
    case noRoute
    case unreachable
    case timedOut

    static func classify(statusCode: Int, latency: TimeInterval) -> RemoteProbeOutcome {
        .unreachable
    }

    func isFast(threshold: TimeInterval) -> Bool {
        true
    }

    /// The Settings status row.
    var statusRowText: String { "" }
}
