import Foundation

/// Decides whether the app needs to write the keyboard runtime status again.
///
/// The idle keyboard session republishes "ready" on every input buffer. Every write is a database
/// transaction plus a Darwin notification that wakes the keyboard extension, so an unchanged status
/// is only rewritten often enough to stay fresh in the keyboard's eyes.
struct KeyboardRuntimeStatusPublishPolicy: Equatable {
    /// Must stay well under `KeyboardHandoffRecoveryPolicy.runtimeFreshnessInterval`.
    static let refreshInterval: TimeInterval = 5

    private var lastPublished: KeyboardRuntimeStatus?
    private var lastPublishedAt: Date?

    func shouldPublish(_ status: KeyboardRuntimeStatus, now: Date) -> Bool {
        guard let lastPublished, let lastPublishedAt else { return true }
        guard Self.hasSameContent(status, lastPublished) else { return true }
        return now.timeIntervalSince(lastPublishedAt) >= Self.refreshInterval
    }

    mutating func notePublished(_ status: KeyboardRuntimeStatus, now: Date) {
        lastPublished = status
        lastPublishedAt = now
    }

    /// Call when something else wrote the status, so the next write is never skipped as a repeat.
    mutating func invalidate() {
        lastPublished = nil
        lastPublishedAt = nil
    }

    private static func hasSameContent(_ lhs: KeyboardRuntimeStatus, _ rhs: KeyboardRuntimeStatus) -> Bool {
        lhs.isActive == rhs.isActive
            && lhs.activeRequestID == rhs.activeRequestID
            && lhs.phase == rhs.phase
            && lhs.message == rhs.message
            && lhs.supportsBackgroundStart == rhs.supportsBackgroundStart
            && lhs.canAcceptStartCommand == rhs.canAcceptStartCommand
            && lhs.inputLevel == rhs.inputLevel
            && lhs.rewriteAvailable == rhs.rewriteAvailable
    }
}
