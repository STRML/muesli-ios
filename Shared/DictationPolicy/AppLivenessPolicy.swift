import Foundation

/// Whether the app is running, judged from a heartbeat it writes while it runs.
///
/// A suspended or killed app cannot write, so a heartbeat that stops is the proof the keyboard needs: whatever the
/// persisted state says, nobody is there to act on it. The numbers come from the runtime status the app already
/// publishes: it rewrites an unchanged status every `KeyboardRuntimeStatusPublishPolicy.refreshInterval` (5 s)
/// and the keyboard calls it stale after `KeyboardHandoffRecoveryPolicy.runtimeFreshnessInterval` (15 s). The
/// readiness heartbeat uses the same cadence and the same bound, so the two signals can never disagree for long,
/// and a test in the app target pins all three to these constants.
enum AppLivenessPolicy {
    /// How often the app rewrites the record while it runs.
    static let heartbeatInterval: TimeInterval = 5
    /// Three missed beats. One late beat (a busy disk, a contended database lock) is not a dead app; three are.
    static let staleAfter: TimeInterval = 15
    /// Both processes read the same device clock, so a heartbeat can only be a little ahead. A heartbeat further
    /// ahead means the clock moved backwards since it was written. It is not proof, and the live app replaces it
    /// within one beat, so a wrong clock costs one flicker and never a dead owner that looks alive.
    static let clockSkewTolerance: TimeInterval = 2
    /// How long a keyboard that has just appeared waits for a heartbeat before it calls the app absent. The
    /// keyboard asks a running app for an immediate beat when it appears, so a live app answers well inside this.
    static let checkingWindow: TimeInterval = 1.5

    enum Freshness: Equatable, Sendable { case fresh, stale, clockSkewed }

    static func freshness(heartbeatAt: Date, now: Date) -> Freshness {
        let age = now.timeIntervalSince(heartbeatAt)
        if age < -clockSkewTolerance { return .clockSkewed }
        return age <= staleAfter ? .fresh : .stale
    }

    static func liveness(record: AppReadinessRecord?, keyboardStamp: ReadinessBuildStamp?, now: Date) -> AppLiveness {
        guard let record else { return .none }
        let age = max(0, now.timeIntervalSince(record.heartbeatAt))
        let isFresh = freshness(heartbeatAt: record.heartbeatAt, now: now) == .fresh
        let buildMatches = keyboardStamp.map { record.stamp.sameApp(as: $0) } ?? true
        return AppLiveness(
            liveBootID: isFresh && buildMatches ? record.bootID : nil,
            recordedBootID: record.bootID,
            heartbeatAge: age
        )
    }
}

/// Who is alive, as one keyboard read sees it.
struct AppLiveness: Equatable, Sendable {
    /// The boot whose heartbeat is fresh and whose app build is this keyboard's.
    var liveBootID: UUID?
    /// The boot the record names, alive or not.
    var recordedBootID: UUID?
    var heartbeatAge: TimeInterval?

    static let none = AppLiveness(liveBootID: nil, recordedBootID: nil, heartbeatAge: nil)
}
