import Foundation

/// Where the opt-in diagnostics are posted. The Settings screen and the uploader both ask this one function, so
/// what the screen says is the address the batches go to.
enum DiagnosticsServerSource: Equatable, Sendable {
    /// The "Diagnostics server" field in Settings.
    case ownField
    /// The Server URL under AI Services, used while the field is empty.
    case aiSummaries
}

struct ResolvedDiagnosticsServer: Equatable, Sendable {
    var url: URL
    var host: String
    var source: DiagnosticsServerSource
    var looksPrivate: Bool
}

enum DiagnosticsServerResolution: Equatable, Sendable {
    /// Neither the field nor AI Services holds an https address.
    case none
    /// The field is filled in but is not an https address. It is never replaced by the AI Services server: the
    /// user asked for a different place, so sending the log somewhere else would be a surprise.
    case invalidOverride
    case resolved(ResolvedDiagnosticsServer)

    var server: ResolvedDiagnosticsServer? {
        if case .resolved(let server) = self { return server }
        return nil
    }
}

enum DiagnosticsServerResolver {
    static func resolve(override: String, aiSummariesBaseURL: String) -> DiagnosticsServerResolution {
        let own = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if own.isEmpty { return resolve(aiSummariesBaseURL, source: .aiSummaries, failure: .none) }
        return resolve(own, source: .ownField, failure: .invalidOverride)
    }

    private static func resolve(
        _ address: String, source: DiagnosticsServerSource, failure: DiagnosticsServerResolution
    ) -> DiagnosticsServerResolution {
        guard let url = CustomLLMEndpoint.diagnosticsURL(from: address), let host = url.host?.lowercased() else {
            return failure
        }
        return .resolved(ResolvedDiagnosticsServer(
            url: url,
            host: host,
            source: source,
            looksPrivate: RemoteTranscriptionPolicy.publicEndpointWarning(baseURL: address) == nil
        ))
    }
}
