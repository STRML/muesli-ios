import Foundation

/// Identifies one live-preview stream so a late callback from an earlier dictation cannot write into the next one.
struct StreamGeneration: Sendable, Equatable {
    private(set) var current = 0

    /// Starts a new stream; every token handed out before is stale from now on.
    mutating func advance() -> Int {
        current += 1
        return current
    }

    /// Ends the current stream without starting another.
    mutating func invalidate() { current += 1 }

    func isCurrent(_ token: Int) -> Bool { token == current }
}

/// The live preview is optional, so stopping must never wait long on it.
enum BoundedWait {
    /// The task's value, or nil when it has not finished within `timeout`. The task is not cancelled here.
    static func value<T: Sendable>(of task: Task<T, Never>, within timeout: Duration) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { once.resume(await task.value) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}
