import Foundation

/// Whether diagnostics may leave the phone right now. Pure: the caller reads the preferences and passes them in.
enum DiagnosticsGate {
    enum Reason: Equatable, Sendable {
        case toggleOff
        case noEndpoint
        /// The endpoint does not look private and the user has not acknowledged that warning for this host.
        case publicEndpointNotAcknowledged
    }

    enum Decision: Equatable, Sendable {
        case allowed
        case blocked(Reason)
    }

    static func decide(
        enabled: Bool,
        endpointHost: String?,
        endpointLooksPrivate: Bool,
        acknowledgedHost: String?
    ) -> Decision {
        guard enabled else { return .blocked(.toggleOff) }
        guard let host = endpointHost, !host.isEmpty else { return .blocked(.noEndpoint) }
        if !endpointLooksPrivate, acknowledgedHost?.lowercased() != host.lowercased() {
            return .blocked(.publicEndpointNotAcknowledged)
        }
        return .allowed
    }
}
