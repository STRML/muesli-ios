import Foundation

// The app's published answer to "can this keyboard dictate right now?". The app writes it, the keyboard reads it,
// and `KeyboardReadinessDerivation` turns it into the one state the keyboard shows. Everything here is a plain
// value so the whole decision runs in `swift test` without a phone.

/// What the speech model is doing in the live app. Written by the app, read by the keyboard.
enum ReadinessModelState: Codable, Equatable, Sendable {
    /// The model files are not on the phone.
    case notDownloaded
    case downloading(progress: Double?)
    /// Compiling or loading onto the Neural Engine. `since` lets the keyboard show elapsed time without a timer
    /// in the app; `progress` is only present when the loader reports one.
    case loading(since: Date, progress: Double?)
    /// Downloaded and never loaded under this app build and OS: a load now is the slow, cold one.
    case notLoaded
    /// Downloaded, loaded before under this build and OS, and not resident now (a fresh launch, or the app let it
    /// go after a memory warning). Loading it again takes seconds, so the keyboard treats it as ready.
    case readyOnDemand
    case ready
    case failed(ReadinessModelFailure)
    /// A load failed, was interrupted or ran very long recently, so automatic loads wait. A user-initiated load
    /// ignores the wait.
    case deferredByBackoff(until: Date)

    /// Dictation can start without a cold load first.
    var isUsable: Bool {
        switch self {
        case .ready, .readyOnDemand: true
        default: false
        }
    }

    /// A short word for logs.
    var code: String {
        switch self {
        case .notDownloaded: "notDownloaded"
        case .downloading: "downloading"
        case .loading: "loading"
        case .notLoaded: "notLoaded"
        case .readyOnDemand: "readyOnDemand"
        case .ready: "ready"
        case .failed: "failed"
        case .deferredByBackoff: "deferredByBackoff"
        }
    }
}

/// Why a model is in the failed state, as a code the keyboard can show and the log can carry.
enum ReadinessModelFailure: String, Codable, CaseIterable, Sendable {
    case downloadFailed
    case loadFailed
    /// The app was gone before a load it started had finished.
    case loadInterrupted
    case unknown
}

/// The microphone session the app keeps for the keyboard.
enum ReadinessMicState: String, Codable, CaseIterable, Sendable {
    case off
    case starting
    case ready
    case recording
}

/// The app build and the OS it runs on. A compiled Neural Engine model is only good under the pair that compiled
/// it, so a change in either is a cold load.
struct ReadinessBuildStamp: Codable, Equatable, Sendable {
    var appVersion: String
    var appBuild: String
    var osVersion: String

    /// The key `ModelPrewarmHistory` stores a successful load under.
    var loadKey: String { "\(appVersion)(\(appBuild))/\(osVersion)" }

    /// Same app build, whatever the OS. The keyboard extension ships inside the app, so a record from another
    /// build means the app has not run since an update.
    func sameApp(as other: ReadinessBuildStamp) -> Bool {
        appVersion == other.appVersion && appBuild == other.appBuild
    }
}

/// One app process launch. The id is new every time the process starts.
struct AppBootIdentity: Codable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var stamp: ReadinessBuildStamp
}

/// The shared readiness record: boot identity, model state, mic state and the heartbeat.
struct AppReadinessRecord: Codable, Equatable, Sendable {
    var bootID: UUID
    var bootStartedAt: Date
    var stamp: ReadinessBuildStamp
    /// Rewritten every `AppLivenessPolicy.heartbeatInterval` while the process runs. It is the liveness proof.
    var heartbeatAt: Date
    var model: ReadinessModelState
    var mic: ReadinessMicState

    init(
        boot: AppBootIdentity,
        heartbeatAt: Date,
        model: ReadinessModelState,
        mic: ReadinessMicState
    ) {
        bootID = boot.id
        bootStartedAt = boot.startedAt
        stamp = boot.stamp
        self.heartbeatAt = heartbeatAt
        self.model = model
        self.mic = mic
    }

    /// Whether a rewrite would tell the keyboard anything new. The heartbeat, and loading progress below
    /// `progressStep`, are not news: the keyboard re-reads the record on its own tick.
    func isMaterially(equalTo other: AppReadinessRecord, progressStep: Double = 0.02) -> Bool {
        guard bootID == other.bootID, stamp == other.stamp, mic == other.mic else { return false }
        switch (model, other.model) {
        case let (.downloading(a), .downloading(b)):
            return Self.progressIsClose(a, b, step: progressStep)
        case let (.loading(sinceA, a), .loading(sinceB, b)):
            return sinceA == sinceB && Self.progressIsClose(a, b, step: progressStep)
        default:
            return model == other.model
        }
    }

    private static func progressIsClose(_ a: Double?, _ b: Double?, step: Double) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) < step
        default: false
        }
    }
}
