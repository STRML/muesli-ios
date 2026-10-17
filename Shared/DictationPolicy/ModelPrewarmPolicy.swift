import Foundation

/// When the app may load the selected transcription model ahead of need.
///
/// Loading a Core ML model onto the Neural Engine is the most expensive thing the app does at startup, and it used
/// to run on every launch and every foreground. A load that fails was also retried on the next foreground with no
/// delay, and a load that compiled for minutes was no reason to stop. This policy replaces that with three rules:
///
/// - **Opening the app warms the model only until it has loaded once.** After that a launch or foreground does not
///   load it. The load happens at the moment it is needed (see ``Trigger``).
/// - **A failed load, or one slower than ``slowLoadSeconds``, starts a wait** that doubles with each repeat up to
///   ``maxBackoffSeconds``. The wait is stored, so a relaunch respects it. Every prewarm trigger honors it.
/// - **The lazy load at transcription time is never gated.** Dictation and meeting transcription load the model on
///   their own when it is missing, so a wait only ever delays the head start, never the feature.
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

        /// Launch and foreground happen whether or not the user is about to dictate. The others mean the model is
        /// about to be used: a keyboard session was armed, a recording is starting, onboarding just finished.
        var isOpportunistic: Bool {
            switch self {
            case .launch, .launchScreen, .foreground: true
            case .onboardingCompleted, .keyboardSession, .recordingStart, .meetingRecording: false
            }
        }
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
        /// The model has loaded on this install before, so opening the app does not load it again.
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
        now: Date
    ) -> Decision {
        if loadInFlight { return .skip(.loadInFlight) }
        if isLoaded { return .skip(.alreadyLoaded) }
        if !isDownloaded { return .download }
        if history.remainingBackoff(now: now) > 0 { return .skip(.backingOff) }
        if trigger.isOpportunistic, history.hasLoadedSuccessfully { return .skip(.alreadyWarmedOnce) }
        return .load
    }
}

/// What the app has learned about loading one model on this install.
struct ModelPrewarmHistory: Codable, Sendable, Equatable {
    var modelID: String
    /// The model has loaded at least once, however slowly.
    var hasLoadedSuccessfully = false
    /// Failed or slow loads in a row. A fast load sets it back to zero.
    var strikes = 0
    var lastStrikeAt: Date?

    init(modelID: String) {
        self.modelID = modelID
    }

    /// Seconds left of the wait. A clock that moved backwards, or a record with strikes but no timestamp, reads as
    /// over: a wrong clock may cost one extra load, never a lockout.
    func remainingBackoff(now: Date) -> TimeInterval {
        guard strikes > 0, let lastStrikeAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastStrikeAt)
        guard elapsed >= 0 else { return 0 }
        return max(0, ModelPrewarmPolicy.backoffSeconds(forStrikes: strikes) - elapsed)
    }

    mutating func recordFailure(now: Date) {
        strikes += 1
        lastStrikeAt = now
    }

    mutating func recordLoad(seconds: TimeInterval, now: Date) {
        hasLoadedSuccessfully = true
        guard seconds > ModelPrewarmPolicy.slowLoadSeconds else {
            strikes = 0
            lastStrikeAt = nil
            return
        }
        recordFailure(now: now)
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

    func recordFailure(modelID: String, now: Date) {
        var history = history(for: modelID)
        history.recordFailure(now: now)
        save(history)
    }

    func recordLoad(modelID: String, seconds: TimeInterval, now: Date) {
        var history = history(for: modelID)
        history.recordLoad(seconds: seconds, now: now)
        save(history)
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
