import Foundation

/// When the app may load the selected transcription model ahead of need.
///
/// Loading a Core ML model onto the Neural Engine is the most expensive thing the app does at startup, so the app
/// loads it ahead of need only when that can pay off. A failed load is not retried at once, and a load that
/// compiled for minutes is no reason to stop. Four rules:
///
/// - **Opening the app warms the model only until it has loaded once under this build and OS.** After that a
///   launch or foreground does not load it. The load happens at the moment it is needed (see ``Trigger``). An
///   app update or an OS update is a cold load again, so the first launch after one warms the model: the compile
///   that took 935 s must not run inside the first dictation.
/// - **A failed load, or one slower than ``slowLoadSeconds``, starts a wait** that doubles with each repeat up to
///   ``maxBackoffSeconds``. The wait is stored, so a relaunch respects it. Every prewarm trigger honors it.
/// - **The lazy load at transcription time is never gated.** Dictation and meeting transcription load the model on
///   their own when it is missing, so a wait only ever delays the head start, never the feature.
/// - **A load the user asked for is never refused by the wait**, and a success clears it. The wait exists to stop
///   automatic retries, not to second-guess a person who is looking at a Loading screen.
///
/// The policy is pure: the caller supplies the clock reading and the load duration.
enum ModelPrewarmPolicy {
    /// Why the app is asking to prewarm. The raw value is the telemetry reason.
    enum Trigger: String, Sendable, Equatable, CaseIterable {
        case launch
        case launchScreen = "launch_screen"
        case foreground
        case onboardingCompleted = "onboarding_completed"
        case keyboardSession = "keyboard_session"
        case recordingStart = "recording_start"
        case meetingRecording = "meeting_recording"
        case userRequested = "user_requested"

        /// Launch and foreground happen whether or not the user is about to dictate. The others mean the model is
        /// about to be used: a keyboard session was armed, a recording is starting, onboarding just finished.
        var isOpportunistic: Bool {
            switch self {
            case .launch, .launchScreen, .foreground: true
            case .onboardingCompleted, .keyboardSession, .recordingStart, .meetingRecording, .userRequested: false
            }
        }

        /// A request from the user is not an automatic retry, so the wait does not apply to it.
        var bypassesBackoff: Bool { self == .userRequested }
    }

    enum Decision: Sendable, Equatable {
        /// Load the model now.
        case load
        /// The model files are not on the phone. Start the download, as the prewarm path always did.
        case download
        case skip(SkipReason)
    }

    enum SkipReason: Sendable, Equatable {
        case alreadyLoaded
        case loadInFlight
        /// A recent load failed or was slow, and its wait is not over.
        case backingOff
        /// The model has loaded under this app build and OS before, so opening the app does not load it again.
        case alreadyWarmedOnce
    }

    /// A load that succeeds but takes longer than this counts as a strike. A normal load is about two seconds.
    static let slowLoadSeconds: TimeInterval = 30
    static let baseBackoffSeconds: TimeInterval = 300
    static let maxBackoffSeconds: TimeInterval = 6 * 3600

    /// The wait after `strikes` failed or slow loads in a row: 5 minutes, doubling, capped at 6 hours.
    static func backoffSeconds(forStrikes strikes: Int) -> TimeInterval {
        guard strikes > 0 else { return 0 }
        // 300 * 2^7 already passes the cap, so the shift never needs to go further and cannot overflow.
        let doublings = min(strikes - 1, 7)
        return min(maxBackoffSeconds, baseBackoffSeconds * Double(1 << doublings))
    }

    static func decide(
        trigger: Trigger,
        isDownloaded: Bool,
        isLoaded: Bool,
        loadInFlight: Bool,
        history: ModelPrewarmHistory,
        stamp: String,
        now: Date
    ) -> Decision {
        if loadInFlight { return .skip(.loadInFlight) }
        if isLoaded { return .skip(.alreadyLoaded) }
        if !isDownloaded { return .download }
        if !trigger.bypassesBackoff, history.remainingBackoff(now: now, stamp: stamp) > 0 { return .skip(.backingOff) }
        if trigger.isOpportunistic, history.isWarm(for: stamp) { return .skip(.alreadyWarmedOnce) }
        return .load
    }
}

/// What the app has learned about loading one model on this install.
struct ModelPrewarmHistory: Codable, Sendable, Equatable {
    /// A load that started and has not reported back. If the next boot finds it, the app died during the load.
    struct LoadMarker: Codable, Sendable, Equatable {
        var bootID: UUID
        var startedAt: Date
        /// The build and OS it was loading under, so the strike lands on the right build.
        var stamp: String?
    }

    var modelID: String
    /// The app build and OS the model last loaded under (``ReadinessBuildStamp/loadKey``). The compiled model is
    /// only good under that pair, so a different pair is a cold load again.
    var loadedStamp: String?
    /// Failed, slow or interrupted loads in a row. A fast load sets it back to zero.
    var strikes = 0
    var lastStrikeAt: Date?
    /// The build and OS the strikes were earned under. A wait earned under another build does not apply: an update
    /// is a new situation, and the 5 minute wait a failed load left behind must not keep the first launch after
    /// the update from warming the model.
    var strikeStamp: String?
    var loadMarker: LoadMarker?

    init(modelID: String) {
        self.modelID = modelID
    }

    /// The model has loaded, however slowly, under this app build and OS.
    func isWarm(for stamp: String) -> Bool {
        loadedStamp == stamp
    }

    /// Seconds left of the wait. A clock that moved backwards, or a record with strikes but no timestamp, reads as
    /// over: a wrong clock may cost one extra load, never a lockout.
    func remainingBackoff(now: Date, stamp: String? = nil) -> TimeInterval {
        guard strikes > 0, let lastStrikeAt else { return 0 }
        if let stamp, strikeStamp != stamp { return 0 }
        let elapsed = now.timeIntervalSince(lastStrikeAt)
        guard elapsed >= 0 else { return 0 }
        return max(0, ModelPrewarmPolicy.backoffSeconds(forStrikes: strikes) - elapsed)
    }

    mutating func recordFailure(now: Date, stamp: String) {
        // Strikes from another build do not count towards this one's wait.
        strikes = strikeStamp == stamp || strikes == 0 ? strikes + 1 : 1
        lastStrikeAt = now
        strikeStamp = stamp
    }

    /// A load finished. A fast one clears the strikes; a slow one is a strike, unless the user asked for it: a
    /// person who watched the Loading screen to the end has not caused anything the wait should guard against.
    mutating func recordLoad(seconds: TimeInterval, now: Date, stamp: String, userInitiated: Bool = false) {
        loadedStamp = stamp
        loadMarker = nil
        guard seconds > ModelPrewarmPolicy.slowLoadSeconds, !userInitiated else {
            strikes = 0
            lastStrikeAt = nil
            strikeStamp = nil
            return
        }
        recordFailure(now: now, stamp: stamp)
    }

    mutating func markLoadStarted(boot: UUID, now: Date, stamp: String) {
        loadMarker = LoadMarker(bootID: boot, startedAt: now, stamp: stamp)
    }

    mutating func markLoadFinished() {
        loadMarker = nil
    }

    /// Call once per boot. A marker from another boot is a load that never finished (a crash, a kill, a suspension
    /// that never resumed), and counts as a strike, so a launch loop backs off instead of retrying forever.
    @discardableResult
    mutating func recoverInterruptedLoad(currentBoot: UUID, now: Date) -> Bool {
        guard let marker = loadMarker, marker.bootID != currentBoot else { return false }
        loadMarker = nil
        recordFailure(now: now, stamp: marker.stamp ?? "")
        return true
    }
}

/// Persists one ``ModelPrewarmHistory`` in `UserDefaults`, for the model that reported last. Switching models
/// therefore starts clean, and an unreadable record reads as clean rather than as a lockout.
struct ModelPrewarmHistoryStore {
    static let defaultKey = "muesli.transcription.prewarmHistory"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = ModelPrewarmHistoryStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func history(for modelID: String) -> ModelPrewarmHistory {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(ModelPrewarmHistory.self, from: data),
              stored.modelID == modelID else {
            return ModelPrewarmHistory(modelID: modelID)
        }
        return stored
    }

    func recordFailure(modelID: String, now: Date, stamp: String) {
        var history = history(for: modelID)
        history.recordFailure(now: now, stamp: stamp)
        save(history)
    }

    func recordLoad(modelID: String, seconds: TimeInterval, now: Date, stamp: String, userInitiated: Bool = false) {
        var history = history(for: modelID)
        history.recordLoad(seconds: seconds, now: now, stamp: stamp, userInitiated: userInitiated)
        save(history)
    }

    func markLoadStarted(modelID: String, boot: UUID, now: Date, stamp: String) {
        var history = history(for: modelID)
        history.markLoadStarted(boot: boot, now: now, stamp: stamp)
        save(history)
    }

    func markLoadFinished(modelID: String) {
        var history = history(for: modelID)
        guard history.loadMarker != nil else { return }
        history.markLoadFinished()
        save(history)
    }

    @discardableResult
    func recoverInterruptedLoad(modelID: String, currentBoot: UUID, now: Date) -> Bool {
        var history = history(for: modelID)
        guard history.recoverInterruptedLoad(currentBoot: currentBoot, now: now) else { return false }
        save(history)
        return true
    }

    func reset(modelID: String) {
        guard history(for: modelID) != ModelPrewarmHistory(modelID: modelID) else { return }
        defaults.removeObject(forKey: key)
    }

    private func save(_ history: ModelPrewarmHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: key)
    }
}

extension Duration {
    /// Whole and fractional seconds, for comparing a measured duration with ``ModelPrewarmPolicy/slowLoadSeconds``.
    var totalSeconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
