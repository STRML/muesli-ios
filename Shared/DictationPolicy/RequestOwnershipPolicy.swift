import Foundation

/// The handoff phases, as plain values this package can see. The raw values are the ones of
/// `KeyboardHandoffPhase`, and a test in the app target keeps the two lists equal.
enum HandoffPhaseKind: String, CaseIterable, Sendable {
    case idle, startRequested, startAcknowledged, recordingStarted, stopRequested, cancelRequested
    case stopAcknowledged, audioSaved, transcribingStarted, resultReady, inserted, copyRequired
    case recoveryRequested, failed, cancelled
}

enum ProgressStage: String, CaseIterable, Sendable {
    case starting, recording, stopping, transcribing
}

enum AbandonReason: String, CaseIterable, Sendable {
    /// A newer boot is running, or the app was updated: the process that owned the request is gone.
    case appRestarted = "app_restarted"
    /// The owner is the last boot on record and has stopped beating (suspended or killed), or nobody took it.
    case ownerLost = "owner_lost"

    /// Stored with the request. Never shown as a failure: the keyboard shows idle.
    var message: String {
        switch self {
        case .appRestarted: "Muesli restarted"
        case .ownerLost: "Muesli stopped responding"
        }
    }
}

/// What the policy says about a persisted request.
enum OwnershipVerdict: Equatable, Sendable {
    /// Nothing is running for it: settled, or no request.
    case notInProgress
    /// The result is saved and queued. The keyboard inserts it itself, so no owner is needed.
    case deliverable(isFresh: Bool)
    /// The keyboard asked the user to open the app to finish. An honest prompt, not a running state.
    case recoveryPrompt
    /// A live app owns it and it is within its stage's bound.
    case live(ProgressStage)
    /// The keyboard wrote it and no app has adopted it yet, within the bound.
    case pendingAdoption(ProgressStage)
    /// A live app owns it (or should) and has sat in this stage past its bound. The UI offers an escape.
    case stalled(ProgressStage)
    /// Its owner is gone. It is shown as idle and recorded once as terminal.
    case abandoned(AbandonReason)
}

/// Decides whether the owner of a persisted request is still there.
///
/// The app stamps every request it works on with its boot id, and the keyboard carries that stamp forward when it
/// writes (stop, cancel). A phase that needs a running app is therefore live only when its stamp is the boot whose
/// heartbeat is fresh. The one thing the keyboard writes with no owner is a request nobody has adopted yet.
enum RequestOwnershipPolicy {
    /// The same numbers as `KeyboardHandoffRecoveryPolicy.keyboardDefaults`, so the stall bound and the retry
    /// and recovery that already fire on it cannot disagree. A test in the app target pins them.
    static let startBound: TimeInterval = 10
    static let stopBound: TimeInterval = 8
    static let transcribeBound: TimeInterval = 120
    /// A queued result is inserted the moment the keyboard reads it. Past this it is idle (the text is in history).
    static let deliverBound: TimeInterval = 15

    static func evaluate(
        phase: HandoffPhaseKind,
        owner: UUID?,
        updatedAt: Date,
        liveness: AppLiveness,
        now: Date
    ) -> OwnershipVerdict {
        let age = max(0, now.timeIntervalSince(updatedAt))
        switch phase {
        case .idle, .inserted, .copyRequired, .cancelled, .failed:
            return .notInProgress
        case .resultReady:
            return .deliverable(isFresh: age <= deliverBound)
        case .recoveryRequested:
            return .recoveryPrompt
        case .startRequested, .stopRequested, .cancelRequested:
            guard owner != nil else { return unadopted(stage: stage(of: phase), age: age, liveness: liveness) }
        case .startAcknowledged, .recordingStarted, .stopAcknowledged, .audioSaved, .transcribingStarted:
            break
        }
        return owned(stage: stage(of: phase), owner: owner, age: age, liveness: liveness)
    }

    static func stage(of phase: HandoffPhaseKind) -> ProgressStage {
        switch phase {
        case .startRequested, .startAcknowledged: .starting
        case .recordingStarted: .recording
        case .stopRequested, .cancelRequested: .stopping
        case .stopAcknowledged, .audioSaved, .transcribingStarted, .resultReady: .transcribing
        case .idle, .inserted, .copyRequired, .recoveryRequested, .failed, .cancelled: .starting
        }
    }

    private static func bound(for stage: ProgressStage) -> TimeInterval? {
        switch stage {
        case .starting: startBound
        case .stopping: stopBound
        case .transcribing: transcribeBound
        case .recording: nil
        }
    }

    private static func owned(stage: ProgressStage, owner: UUID?, age: TimeInterval, liveness: AppLiveness) -> OwnershipVerdict {
        guard let live = liveness.liveBootID else {
            // Nobody is alive. If the record names a newer boot than the owner, the owner's process is long gone;
            // if the owner is the last boot on record, it stopped beating.
            let restarted = liveness.recordedBootID != nil && owner != liveness.recordedBootID
            return .abandoned(restarted ? .appRestarted : .ownerLost)
        }
        guard owner == live else { return .abandoned(.appRestarted) }
        if let limit = bound(for: stage), age > limit { return .stalled(stage) }
        return .live(stage)
    }

    private static func unadopted(stage: ProgressStage, age: TimeInterval, liveness: AppLiveness) -> OwnershipVerdict {
        let limit = bound(for: stage) ?? startBound
        if age <= limit { return .pendingAdoption(stage) }
        // A live app that has not taken it is slow, not dead: the existing retry and recovery handle that.
        return liveness.liveBootID != nil ? .stalled(stage) : .abandoned(.ownerLost)
    }
}
