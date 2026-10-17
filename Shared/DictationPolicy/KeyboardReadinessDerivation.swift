import Foundation

/// Why the keyboard cannot dictate without opening Muesli first.
enum NeedsAppReason: String, CaseIterable, Sendable {
    /// The keyboard cannot read the shared store, so it cannot tell. Setup, not a guess.
    case fullAccessOff
    /// Nothing was ever published: a fresh install, or the app has never run.
    case neverOpened
    /// The app has not run since an update (another build, or another OS): the model needs a cold load.
    case appUpdated
    /// The app is not running (killed, or suspended without the mic session).
    case appNotRunning
    /// The app was in the middle of loading the model and has stopped.
    case loadInterrupted
    case modelMissing
    case modelNotLoaded
    /// The keyboard has asked the user to open the app to finish a recording.
    case recovery
}

enum LoadStage: String, Sendable { case downloading, preparing }

/// The one state the keyboard shows. Listening, writing and ready appear only when a live app confirms them.
enum KeyboardReadinessState: Equatable, Sendable {
    /// A beat has not arrived yet. Lasts at most `AppLivenessPolicy.checkingWindow`, then it is `needsApp`.
    case checking
    case needsApp(NeedsAppReason)
    case loading(LoadStage, progress: Double?, elapsed: TimeInterval)
    case ready
    /// Requested or acknowledged, waiting for the microphone.
    case starting
    case recording
    /// A live app owns a recording but no audio level has arrived for a while, so what the keyboard would show is
    /// not known to be true. Shown as a lost connection with a way out, never as an inert pill.
    case connectionLost
    case transcribing
    case failed(ReadinessModelFailure)
}

/// What the Record key does when tapped.
enum RecordAction: String, CaseIterable, Sendable {
    /// The app has a hot mic and a ready model: send the start command.
    case startInPlace
    /// Open Muesli with the usual start request. One trip, the model is known good.
    case openAppToStart
    /// Open Muesli to get ready first (load the model), without a start request that would hang.
    case openAppToPrepare
    /// Open Muesli with the recovery link the keyboard already holds.
    case openAppToRecover
    case stop
    case none
}

struct KeyboardReadiness: Equatable, Sendable {
    var state: KeyboardReadinessState
    var recordAction: RecordAction
    /// The state has lasted past its bound, so the UI offers a way out (cancel, or open Muesli).
    var offersEscape: Bool
}

struct KeyboardReadinessInput: Equatable, Sendable {
    var hasStoreAccess: Bool
    var record: AppReadinessRecord?
    var keyboardStamp: ReadinessBuildStamp
    /// The verdict on the request in play, from `RequestOwnershipPolicy`.
    var request: OwnershipVerdict
    var now: Date
    /// When this keyboard began waiting for a heartbeat. Nil when it is not waiting.
    var checkingStartedAt: Date?
    /// How long since the app last reported audio for the recording in play (or since the recording began, if it
    /// has not yet). Nil when there is no recording to judge.
    var recordingSignalAge: TimeInterval?
}

enum KeyboardReadinessDerivation {
    /// A load longer than this offers "Open Muesli" while it keeps showing as a load.
    static let loadingEscapeAfter: TimeInterval = 120

    static func derive(_ input: KeyboardReadinessInput) -> KeyboardReadiness {
        guard input.hasStoreAccess else {
            return KeyboardReadiness(state: .needsApp(.fullAccessOff), recordAction: .openAppToPrepare, offersEscape: false)
        }
        if var active = activeRequest(input) {
            if active.state == .recording, let age = input.recordingSignalAge, age > AppLivenessPolicy.levelStaleAfter {
                active = KeyboardReadiness(state: .connectionLost, recordAction: .openAppToRecover, offersEscape: true)
            }
            return active
        }

        let liveness = AppLivenessPolicy.liveness(record: input.record, keyboardStamp: input.keyboardStamp, now: input.now)
        guard liveness.liveBootID != nil, let record = input.record else {
            return absent(input)
        }
        return live(record, now: input.now)
    }

    // MARK: A request in play

    private static func activeRequest(_ input: KeyboardReadinessInput) -> KeyboardReadiness? {
        switch input.request {
        case .notInProgress, .abandoned, .deliverable(isFresh: false):
            return nil
        case .recoveryPrompt:
            return KeyboardReadiness(state: .needsApp(.recovery), recordAction: .openAppToRecover, offersEscape: false)
        case .deliverable(isFresh: true):
            return KeyboardReadiness(state: .transcribing, recordAction: .none, offersEscape: false)
        case let .live(stage), let .pendingAdoption(stage):
            return progress(stage, escape: false)
        case let .stalled(stage):
            return progress(stage, escape: true)
        }
    }

    private static func progress(_ stage: ProgressStage, escape: Bool) -> KeyboardReadiness {
        switch stage {
        case .starting: KeyboardReadiness(state: .starting, recordAction: .stop, offersEscape: escape)
        case .recording, .stopping: KeyboardReadiness(state: .recording, recordAction: .stop, offersEscape: escape)
        case .transcribing: KeyboardReadiness(state: .transcribing, recordAction: .none, offersEscape: escape)
        }
    }

    // MARK: No live app

    private static func absent(_ input: KeyboardReadinessInput) -> KeyboardReadiness {
        guard let record = input.record else {
            return KeyboardReadiness(state: .needsApp(.neverOpened), recordAction: .openAppToPrepare, offersEscape: false)
        }
        let sameBuild = record.stamp == input.keyboardStamp
        // The model is known good only when the app that last ran is this build on this OS and it was ready.
        let action: RecordAction = sameBuild && record.model.isUsable ? .openAppToStart : .openAppToPrepare

        if let started = input.checkingStartedAt,
           input.now.timeIntervalSince(started) < AppLivenessPolicy.checkingWindow {
            return KeyboardReadiness(state: .checking, recordAction: action, offersEscape: false)
        }
        let reason: NeedsAppReason
        if !sameBuild {
            reason = .appUpdated
        } else if case .loading = record.model {
            reason = .loadInterrupted
        } else {
            reason = .appNotRunning
        }
        return KeyboardReadiness(state: .needsApp(reason), recordAction: action, offersEscape: false)
    }

    // MARK: A live app, by model

    private static func live(_ record: AppReadinessRecord, now: Date) -> KeyboardReadiness {
        switch record.model {
        case .ready, .readyOnDemand:
            let action: RecordAction = record.mic == .ready ? .startInPlace : .openAppToStart
            return KeyboardReadiness(state: .ready, recordAction: action, offersEscape: false)
        case let .downloading(progress):
            return KeyboardReadiness(
                state: .loading(.downloading, progress: progress, elapsed: 0),
                recordAction: .openAppToPrepare,
                offersEscape: false
            )
        case let .loading(since, progress):
            let elapsed = max(0, now.timeIntervalSince(since))
            return KeyboardReadiness(
                state: .loading(.preparing, progress: progress, elapsed: elapsed),
                recordAction: .openAppToPrepare,
                offersEscape: elapsed > loadingEscapeAfter
            )
        case .notDownloaded:
            return KeyboardReadiness(state: .needsApp(.modelMissing), recordAction: .openAppToPrepare, offersEscape: false)
        case .notLoaded, .deferredByBackoff:
            return KeyboardReadiness(state: .needsApp(.modelNotLoaded), recordAction: .openAppToPrepare, offersEscape: false)
        case let .failed(failure):
            return KeyboardReadiness(state: .failed(failure), recordAction: .openAppToPrepare, offersEscape: false)
        }
    }
}

extension KeyboardReadinessState {
    /// A short word for the diagnostics log: one per state, with the reason where there is one.
    var code: String {
        switch self {
        case .checking: "checking"
        case let .needsApp(reason): "needsApp.\(reason.rawValue)"
        case let .loading(stage, _, _): "loading.\(stage.rawValue)"
        case .ready: "ready"
        case .starting: "starting"
        case .recording: "recording"
        case .connectionLost: "connectionLost"
        case .transcribing: "transcribing"
        case let .failed(failure): "failed.\(failure.rawValue)"
        }
    }
}
