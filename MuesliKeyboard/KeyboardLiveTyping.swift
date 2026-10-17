import Foundation
import UIKit

/// The host text field as live typing writes to it. The keyboard wraps `UITextDocumentProxy`; tests use fakes.
@MainActor
protocol LiveTypingHost: AnyObject {
    /// `setMarkedText(_:selectedRange:)` with the cursor at the end of the text.
    func setMarkedText(_ text: String)
    func unmarkText()
    func deleteBackward()
    func insertText(_ text: String)
    func snapshot() -> LiveTypingSnapshot
}

/// `UITextDocumentProxy` as a live typing host.
///
/// `setMarkedText(_:selectedRange:)` and `unmarkText()` are declared on `UITextDocumentProxy` in
/// `UIInputViewController.h` (iOS 13.0, so no availability check at this app's iOS 17 floor). The documentation
/// there: "Setting marked text either replaces the existing marked text or, if none is present, inserts it in place
/// of the current input location." `selectedRange` is relative to the marked text and counts UTF-16 units.
@MainActor
final class ProxyLiveTypingHost: LiveTypingHost {
    private let proxy: @MainActor () -> UITextDocumentProxy?

    init(proxy: @escaping @MainActor () -> UITextDocumentProxy?) {
        self.proxy = proxy
    }

    func setMarkedText(_ text: String) {
        proxy()?.setMarkedText(text, selectedRange: LiveTypingText.markedSelection(for: text))
    }

    func unmarkText() {
        proxy()?.unmarkText()
    }

    func deleteBackward() {
        proxy()?.deleteBackward()
    }

    func insertText(_ text: String) {
        proxy()?.insertText(text)
    }

    func snapshot() -> LiveTypingSnapshot {
        guard let proxy = proxy() else { return LiveTypingSnapshot() }
        return LiveTypingSnapshot(
            before: proxy.documentContextBeforeInput ?? "",
            after: proxy.documentContextAfterInput ?? "",
            selection: proxy.selectedText ?? "",
            // Not `proxy.documentIdentifier`: that getter traps while the host has no document yet.
            documentID: TypingDocumentIdentity.read(from: proxy as AnyObject)
        )
    }
}

/// Time for live typing: a clock and timers, injected so tests control both.
struct LiveTypingScheduler {
    var now: @MainActor () -> TimeInterval
    /// Runs `action` on the main actor after `delay`; the returned closure cancels it.
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    static let system = LiveTypingScheduler(
        now: { ProcessInfo.processInfo.systemUptime },
        schedule: { delay, action in
            let task = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
    )
}

/// Performs a `LiveTypingSession`'s decisions on the host field, on the main actor and never from a background
/// queue, and feeds it what the field looks like afterwards.
@MainActor
final class KeyboardLiveTyper {
    /// How long a marked write may take to show in the proxy's context before the host is called unsupported.
    static let probeTimeout: TimeInterval = 0.35
    /// How soon after a write the keyboard looks again, and how old a write must be before a mismatch counts: the
    /// proxy is an out-of-process snapshot and can still show the text from before the write.
    static let settleDelay: TimeInterval = 0.3
    private static let probePoll: TimeInterval = 0.1

    var host: LiveTypingHost?
    var isEnabled = true

    private let scheduler: LiveTypingScheduler
    private(set) var session: LiveTypingSession?
    private var throttle = LiveTypingThrottle()
    private var lastWriteAt = -TimeInterval.infinity
    private var lastUpdatedAt: Date?
    private var cancelFlush: (() -> Void)?
    private var cancelProbePoll: (() -> Void)?
    private var cancelProbeTimeout: (() -> Void)?
    private var cancelRecheck: (() -> Void)?

    init(scheduler: LiveTypingScheduler = .system) {
        self.scheduler = scheduler
    }

    var sessionRequestID: UUID? { session?.requestID }

    // MARK: Streaming words

    /// The newest partial of a dictation. Only a keyboard with a host to write to ever starts a session.
    func receive(partial text: String, requestID: UUID, updatedAt: Date, isRewrite: Bool) {
        guard let host else { return }
        if session?.requestID != requestID {
            endSessionForNewRequest()
            lastUpdatedAt = nil
            session = LiveTypingSession(
                requestID: requestID,
                base: host.snapshot(),
                isEnabled: isEnabled,
                hasHost: true,
                isRewrite: isRewrite
            )
        }
        // An older update must never overwrite a newer one.
        if let lastUpdatedAt, updatedAt < lastUpdatedAt { return }
        lastUpdatedAt = updatedAt
        let trimmed = LiveTypingText.trimmedPartial(text)
        guard !trimmed.isEmpty, session?.acceptsPartials == true else { return }
        switch throttle.offer(trimmed, now: scheduler.now()) {
        case .applyNow(let next): apply(next)
        case .waitUntil(let time): scheduleFlush(at: time)
        case .none: break
        }
    }

    private func scheduleFlush(at time: TimeInterval) {
        guard cancelFlush == nil else { return }
        cancelFlush = scheduler.schedule(max(0, time - scheduler.now())) { [weak self] in
            guard let self else { return }
            self.cancelFlush = nil
            if let next = self.throttle.takePending(now: self.scheduler.now()) { self.apply(next) }
        }
    }

    private func apply(_ text: String) {
        guard session != nil else { return }
        perform(session?.partial(text) ?? [])
    }

    // MARK: Watching the field

    /// The host reported a change (`textDidChange`, `selectionDidChange`).
    func hostDidChange() {
        guard session?.writesToHost == true else { return }
        observe(forced: false)
    }

    private func observe(forced: Bool) {
        guard let host, session != nil else { return }
        let settled = scheduler.now() - lastWriteAt >= Self.settleDelay
        perform(session?.observed(host.snapshot(), forced: forced, settled: settled) ?? [])
        if !forced, session?.phase == .live, !settled { scheduleRecheck() }
    }

    private func scheduleRecheck() {
        cancelRecheck?()
        let wait = max(0.02, lastWriteAt + Self.settleDelay - scheduler.now())
        cancelRecheck = scheduler.schedule(wait) { [weak self] in
            self?.cancelRecheck = nil
            self?.observe(forced: false)
        }
    }

    private func scheduleProbeChecks() {
        cancelProbePoll?()
        cancelProbeTimeout?()
        cancelProbePoll = scheduler.schedule(Self.probePoll) { [weak self] in
            self?.cancelProbePoll = nil
            self?.observe(forced: false)
        }
        cancelProbeTimeout = scheduler.schedule(Self.probeTimeout) { [weak self] in
            self?.cancelProbeTimeout = nil
            self?.observe(forced: true)
        }
    }

    // MARK: Ending

    /// The final text. Returns what the keyboard still has to do with it.
    func final(_ text: String, requestID: UUID) -> LiveTypingFinal.Outcome {
        guard session?.requestID == requestID else { return .insertPlain(text) }
        cancelTimers()
        throttle.reset()
        let snapshot = host?.snapshot() ?? LiveTypingSnapshot()
        guard let result = session?.final(text, snapshot: snapshot) else { return .insertPlain(text) }
        perform(result.commands)
        return result.outcome
    }

    /// Something is about to edit the field, or the keyboard is going away.
    func yield(_ reason: LiveTypingOff) {
        guard session != nil else { return }
        cancelTimers()
        throttle.reset()
        perform(session?.yield(reason) ?? [])
    }

    /// The user cancelled this dictation.
    func cancel(requestID: UUID) {
        guard session?.requestID == requestID else { return }
        cancelTimers()
        throttle.reset()
        let snapshot = host?.snapshot() ?? LiveTypingSnapshot()
        perform(session?.cancel(snapshot: snapshot) ?? [])
    }

    /// The dictation ended with no text for the keyboard to insert: the words stay as plain text.
    func endWithoutResult(requestID: UUID) {
        guard session?.requestID == requestID else { return }
        cancelTimers()
        throttle.reset()
        perform(session?.endWithoutResult() ?? [])
    }

    private func endSessionForNewRequest() {
        cancelTimers()
        throttle.reset()
        if session != nil { perform(session?.endWithoutResult() ?? []) }
        session = nil
    }

    /// A new dictation starts: anything left from the last one is kept as plain text, and its state forgotten.
    func reset() {
        endSessionForNewRequest()
        lastUpdatedAt = nil
    }

    private func cancelTimers() {
        for cancel in [cancelFlush, cancelProbePoll, cancelProbeTimeout, cancelRecheck] { cancel?() }
        cancelFlush = nil
        cancelProbePoll = nil
        cancelProbeTimeout = nil
        cancelRecheck = nil
    }

    // MARK: Performing commands

    private func perform(_ commands: [LiveTypingCommand]) {
        guard !commands.isEmpty else { return }
        var wrote = false
        for command in commands {
            switch command {
            case .setMarked(let text):
                host?.setMarkedText(text)
                wrote = true
            case .unmark:
                host?.unmarkText()
                wrote = true
            case .clearMarked:
                host?.setMarkedText("")
                host?.unmarkText()
                wrote = true
            case .deleteBackward(let count):
                for _ in 0..<count { host?.deleteBackward() }
                wrote = true
            case .insert(let text):
                host?.insertText(text)
                wrote = true
            case .log(let event, let reason):
                KeyboardDiagnosticsLog.record(event, ["reason": reason])
            }
        }
        if wrote { lastWriteAt = scheduler.now() }
        guard let session else { return }
        if session.isProbing {
            scheduleProbeChecks()
        } else if session.phase == .live, wrote {
            scheduleRecheck()
        } else if !session.writesToHost {
            cancelProbePoll?(); cancelProbeTimeout?(); cancelRecheck?()
            cancelProbePoll = nil; cancelProbeTimeout = nil; cancelRecheck = nil
        }
    }
}
