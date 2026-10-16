import Foundation

/// Remembers the last probe for a short while, so dictation can start the probe when recording starts and read the
/// answer when it ends instead of waiting on the network at the worst moment. One probe runs at a time.
actor RemoteProbeCache {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let probe: @Sendable () async -> RemoteProbeOutcome
    private var verdict: (outcome: RemoteProbeOutcome, at: Date)?
    private var inFlight: (id: Int, task: Task<RemoteProbeOutcome, Never>)?
    private var generation = 0

    init(
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping @Sendable () async -> RemoteProbeOutcome
    ) {
        self.ttl = ttl
        self.now = now
        self.probe = probe
    }

    /// Starts a probe unless a fresh verdict or a running probe already covers it.
    func prewarm() {
        guard freshVerdict() == nil else { return }
        _ = runningProbe()
    }

    func outcome() async -> RemoteProbeOutcome {
        if let fresh = freshVerdict() { return fresh }
        return await runningProbe().value
    }

    private func freshVerdict() -> RemoteProbeOutcome? {
        guard let verdict, now().timeIntervalSince(verdict.at) < ttl else { return nil }
        return verdict.outcome
    }

    private func runningProbe() -> Task<RemoteProbeOutcome, Never> {
        if let inFlight { return inFlight.task }
        generation += 1
        let id = generation
        let task = Task { [probe] in
            let outcome = await probe()
            await self.finish(outcome, id: id)
            return outcome
        }
        inFlight = (id, task)
        return task
    }

    private func finish(_ outcome: RemoteProbeOutcome, id: Int) {
        verdict = (outcome, now())
        if inFlight?.id == id { inFlight = nil }
    }
}
