import Foundation

/// Publishes the app's readiness record and keeps its heartbeat alive.
///
/// The heartbeat is the proof that this process is running. It is written from a utility queue and a timer, never
/// from the main actor, so a busy main thread cannot make a healthy app look dead, and a suspended app (whose
/// queues stop with it) stops beating, which is exactly what the keyboard needs to see.
final class AppReadinessPublisher: @unchecked Sendable {
    let boot: AppBootIdentity

    private let store: SharedStore
    private let queue: DispatchQueue
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var model: ReadinessModelState = .notLoaded
    private var mic: ReadinessMicState = .off
    private var lastWritten: AppReadinessRecord?
    private var timer: DispatchSourceTimer?

    init(
        store: SharedStore,
        boot: AppBootIdentity,
        queue: DispatchQueue = DispatchQueue(label: "com.samuelreed.muesli.readiness", qos: .utility),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.boot = boot
        self.queue = queue
        self.clock = clock
    }

    deinit { timer?.cancel() }

    /// Writes the first record synchronously, so a launch-time reconcile and the keyboard both see this boot before
    /// anything else happens, then beats every `AppLivenessPolicy.heartbeatInterval`.
    func start(model: ReadinessModelState, mic: ReadinessMicState) {
        lock.lock()
        self.model = model
        self.mic = mic
        lock.unlock()
        queue.sync { write() }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = AppLivenessPolicy.heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.write() }
        timer.resume()
        lock.lock()
        self.timer?.cancel()
        self.timer = timer
        lock.unlock()
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// The model or the mic changed. Written at once, and announced to the keyboard if it is news.
    func update(model: ReadinessModelState, mic: ReadinessMicState) {
        lock.lock()
        let changed = self.model != model || self.mic != mic
        self.model = model
        self.mic = mic
        lock.unlock()
        guard changed else { return }
        queue.async { [weak self] in self?.write() }
    }

    /// A keyboard has just appeared and wants to know now.
    func beat() {
        queue.async { [weak self] in self?.write() }
    }

    /// Blocks until queued writes have happened. For tests.
    func flush() {
        queue.sync {}
    }

    private func write() {
        lock.lock()
        let record = AppReadinessRecord(boot: boot, heartbeatAt: clock(), model: model, mic: mic)
        let isNews = lastWritten.map { !$0.isMaterially(equalTo: record) } ?? true
        lastWritten = record
        lock.unlock()
        try? store.saveAppReadiness(record, notify: isNews)
    }
}
