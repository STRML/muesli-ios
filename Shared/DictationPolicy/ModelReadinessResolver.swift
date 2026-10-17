import Foundation

/// The app's model preparation phase, as a plain value this package can see (`ModelPreparationPhase`).
enum PreparationPhaseKind: String, CaseIterable, Sendable {
    case idle, downloading, preparing, ready, failed
}

/// Turns what the app knows about the speech model into the state it publishes to the keyboard.
enum ModelReadinessResolver {
    static func resolve(
        phase: PreparationPhaseKind,
        progress: Double?,
        loadStartedAt: Date?,
        failure: ReadinessModelFailure?,
        isDownloaded: Bool,
        history: ModelPrewarmHistory,
        stamp: String,
        now: Date
    ) -> ReadinessModelState {
        switch phase {
        case .ready:
            return .ready
        case .downloading:
            return .downloading(progress: progress)
        case .preparing:
            return .loading(since: loadStartedAt ?? now, progress: progress)
        case .failed:
            return .failed(failure ?? .unknown)
        case .idle:
            return idle(isDownloaded: isDownloaded, history: history, stamp: stamp, now: now)
        }
    }

    /// Nothing is happening. Whether dictation can start depends on whether a load now would be quick.
    private static func idle(isDownloaded: Bool, history: ModelPrewarmHistory, stamp: String, now: Date) -> ReadinessModelState {
        guard isDownloaded else { return .notDownloaded }
        // Loaded under this build and OS before: the compiled model is cached and a load takes seconds. This holds
        // for a fresh launch and for a model the app let go of after a memory warning.
        if history.isWarm(for: stamp) { return .readyOnDemand }
        let remaining = history.remainingBackoff(now: now, stamp: stamp)
        if remaining > 0, let lastStrikeAt = history.lastStrikeAt {
            return .deferredByBackoff(until: lastStrikeAt.addingTimeInterval(ModelPrewarmPolicy.backoffSeconds(forStrikes: history.strikes)))
        }
        return .notLoaded
    }
}
