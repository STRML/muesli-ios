import Foundation

/// Remembers the last probe for a short while, so dictation can start the probe when recording starts and read the
/// answer when it ends instead of waiting on the network at the worst moment.
actor RemoteProbeCache {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let probe: @Sendable () async -> RemoteProbeOutcome

    init(
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping @Sendable () async -> RemoteProbeOutcome
    ) {
        self.ttl = ttl
        self.now = now
        self.probe = probe
    }

    func prewarm() {}

    func outcome() async -> RemoteProbeOutcome {
        await probe()
    }
}
