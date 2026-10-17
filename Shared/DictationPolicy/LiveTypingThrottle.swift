import Foundation

/// Coalesces streaming updates so the host field is written at most about six times a second.
///
/// The latest text always wins and updates are never reordered: a burst inside the window leaves one pending
/// write, which the caller performs when the window closes.
struct LiveTypingThrottle: Sendable {
    static let minInterval: TimeInterval = 1.0 / 6.0
    private static let slack: TimeInterval = 1e-9

    enum Decision: Equatable, Sendable {
        /// Write this text now.
        case applyNow(String)
        /// Call `takePending` at this time.
        case waitUntil(TimeInterval)
        /// Nothing to write.
        case none
    }

    private var lastApplied: String?
    private var lastAppliedAt: TimeInterval?
    private var pending: String?

    mutating func offer(_ text: String, now: TimeInterval) -> Decision {
        if let last = lastAppliedAt, now - last < Self.minInterval - Self.slack {
            if text == lastApplied {
                // It changed and changed back inside the window: nothing to write.
                pending = nil
                return .none
            }
            pending = text
            return .waitUntil(last + Self.minInterval)
        }
        if text == lastApplied, pending == nil { return .none }
        lastApplied = text
        lastAppliedAt = now
        pending = nil
        return .applyNow(text)
    }

    /// The text to write now that the window may have closed, if one is waiting.
    mutating func takePending(now: TimeInterval) -> String? {
        guard let text = pending, let last = lastAppliedAt, now >= last + Self.minInterval - Self.slack else { return nil }
        pending = nil
        guard text != lastApplied else { return nil }
        lastApplied = text
        lastAppliedAt = now
        return text
    }

    mutating func reset() {
        lastApplied = nil
        lastAppliedAt = nil
        pending = nil
    }
}
