import Foundation

enum RemoteProbeOutcome: Sendable, Equatable {
    /// The transcription route answered. `latency` is the round trip in seconds.
    case reachable(latency: TimeInterval)
    case noRoute
    case keyRejected
    case unreachable
    case timedOut

    /// The probe is a form POST without a recording. A server that has the route answers it (a 400 or 422 for the
    /// missing file counts). The Studio checks the key before the route, so a 401 or 403 means a wrong key.
    static func classify(statusCode: Int, latency: TimeInterval) -> RemoteProbeOutcome {
        switch statusCode {
        case 401, 403:
            .keyRejected
        case 404, 405:
            .noRoute
        case 200..<300, 400, 413, 415, 422:
            .reachable(latency: latency)
        default:
            .unreachable
        }
    }

    func isFast(threshold: TimeInterval) -> Bool {
        guard case .reachable(let latency) = self else { return false }
        return latency <= threshold
    }

    /// The Settings status row.
    var statusRowText: String {
        switch self {
        case .reachable(let latency):
            "Reachable, \(Int((latency * 1000).rounded())) ms"
        case .noRoute:
            "No transcription route"
        case .keyRejected:
            "API key rejected"
        case .unreachable, .timedOut:
            "Unreachable"
        }
    }
}

enum RemoteTranscriptText {
    /// The text worth using, or nil for an empty or punctuation-only answer.
    static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return trimmed
    }
}
