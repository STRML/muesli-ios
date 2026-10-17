@preconcurrency import ActivityKit
import Foundation

/// The ActivityKit calls the controller makes on activities it does not hold, behind a seam so tests can fake them.
@MainActor
protocol KeyboardMicActivitySystem {
    var activitiesEnabled: Bool { get }
    func cards() -> [KeyboardMicCardPolicy.Card]
    func end(cardID: String) async
}

struct SystemKeyboardMicActivities: KeyboardMicActivitySystem {
    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func cards() -> [KeyboardMicCardPolicy.Card] {
        Activity<KeyboardMicActivityAttributes>.activities.map {
            .init(id: $0.id, sessionID: $0.attributes.sessionID, isStale: $0.activityState == .stale)
        }
    }

    func end(cardID: String) async {
        for item in Activity<KeyboardMicActivityAttributes>.activities where item.id == cardID {
            await item.end(nil, dismissalPolicy: .immediate)
        }
    }
}

@MainActor
final class KeyboardMicActivityController {
    private let system: KeyboardMicActivitySystem
    private let dictationSwitch: () -> Bool
    private let keyboardMicSwitch: () -> Bool

    init(
        system: KeyboardMicActivitySystem = SystemKeyboardMicActivities(),
        dictationSwitch: @escaping () -> Bool = { MuesliPreferences.liveActivitiesForDictationsEnabled },
        keyboardMicSwitch: @escaping () -> Bool = { MuesliPreferences.liveActivitiesForKeyboardMicEnabled }
    ) {
        self.system = system
        self.dictationSwitch = dictationSwitch
        self.keyboardMicSwitch = keyboardMicSwitch
    }

    /// The card may exist only when the system, the voice note switch and the keyboard mic switch all allow it.
    var cardsAllowed: Bool {
        KeyboardMicCardPolicy.allowsCard(
            systemActivitiesEnabled: system.activitiesEnabled,
            dictationSwitch: dictationSwitch(),
            keyboardMicSwitch: keyboardMicSwitch()
        )
    }

    private var activity: Activity<KeyboardMicActivityAttributes>?
    private var lastState: KeyboardMicActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    /// The Island goes stale when the app stops vouching for it. While the mic session is alive the app
    /// renews this every `keepAliveInterval`; if iOS suspends or kills the app the renewals stop, the
    /// activity turns stale, and the widget shows "Mic off" instead of claiming the mic is on.
    static let staleAfter: TimeInterval = 180
    static let keepAliveInterval: TimeInterval = 60

    private static func staleDate() -> Date { Date.now.addingTimeInterval(staleAfter) }

    func hasActivity(sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return activity?.attributes.sessionID == sessionID.uuidString
            && (activity?.activityState == .active || activity?.activityState == .stale)
    }

    func start(sessionID: UUID, isRecording: Bool) {
        guard activity == nil, cardsAllowed else { return }
        do {
            let state = KeyboardMicActivityAttributes.ContentState(isRecording: isRecording, isReady: true)
            activity = try Activity.request(
                attributes: KeyboardMicActivityAttributes(sessionID: sessionID.uuidString),
                content: ActivityContent(state: state, staleDate: Self.staleDate()),
                pushType: nil
            )
            lastState = state
            startKeepAlive()
        } catch {
            KeyboardDiagnosticsLog.record("keyboardMic.activityFailed", ["error": String(describing: error)])
        }
    }

    func update(sessionID: UUID, isRecording: Bool, isReady: Bool) {
        guard let activity, activity.attributes.sessionID == sessionID.uuidString else { return }
        let state = KeyboardMicActivityAttributes.ContentState(
            isRecording: isRecording, isReady: isReady,
            waveform: isRecording ? lastState?.waveform : nil,
            completionExpiresAt: !isRecording && isReady ? lastState?.completionExpiresAt : nil
        )
        if isRecording || !isReady {
            completionTask?.cancel()
            completionTask = nil
        }
        enqueue(state, activity: activity)
    }

    func showCompletion(sessionID: UUID?) {
        guard let sessionID, let activity,
              activity.attributes.sessionID == sessionID.uuidString,
              var state = lastState, !state.isRecording, state.isReady else { return }
        completionTask?.cancel()
        let expiry = Date.now.addingTimeInterval(5)
        state.completionExpiresAt = expiry
        enqueue(state, activity: activity)
        completionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, self.activity?.id == activity.id,
                  var current = self.lastState, current.completionExpiresAt == expiry else { return }
            current.completionExpiresAt = nil
            self.enqueue(current, activity: activity)
            self.completionTask = nil
        }
    }

    private func enqueue(_ state: KeyboardMicActivityAttributes.ContentState,
                         activity: Activity<KeyboardMicActivityAttributes>) {
        guard lastState != state else { return }
        lastState = state
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            guard !Task.isCancelled, self.activity?.id == activity.id,
                  self.lastState == state else { return }
            await activity.update(ActivityContent(state: state, staleDate: Self.staleDate()))
        }
    }

    func updateWaveform(_ samples: [Double], sessionID: UUID) async {
        guard let activity, activity.attributes.sessionID == sessionID.uuidString,
              var state = lastState, state.isRecording else { return }
        state.waveform = MuesliLiveActivityWaveform.bars(samples)
        enqueue(state, activity: activity)
        await updateTask?.value
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.keepAliveInterval))
                guard !Task.isCancelled, let self, let activity = self.activity,
                      let state = self.lastState else { return }
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate()))
            }
        }
    }

    /// Stops the renewals and updates for the card this instance holds and forgets it.
    private func releaseOwnedActivity() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        completionTask?.cancel()
        completionTask = nil
        activity = nil
        lastState = nil
        let pendingUpdate = updateTask
        updateTask = nil
        pendingUpdate?.cancel()
        await pendingUpdate?.value
    }

    /// Ends every keyboard mic activity, whatever session it belongs to. For when the mic is known to be off.
    func endAll() async {
        await releaseOwnedActivity()
        for card in system.cards() { await system.end(cardID: card.id) }
    }

    func end(sessionID: UUID) async {
        if activity?.attributes.sessionID == sessionID.uuidString { await releaseOwnedActivity() }
        for card in system.cards() where card.sessionID == sessionID.uuidString {
            await system.end(cardID: card.id)
        }
    }

    /// Ends every card that should not be on screen: all of them when cards are not allowed, otherwise any that is
    /// stale, from another session, or a duplicate of the one this instance holds. A stale card of the live session
    /// that this instance holds is renewed instead, since the mic really is on.
    func removeOrphanedActivities(liveSessionID: UUID?) async {
        let plan = KeyboardMicCardPolicy.reconcile(
            cards: system.cards(),
            ownedCardID: activity?.id,
            liveSessionID: liveSessionID?.uuidString,
            cardsAllowed: cardsAllowed
        )
        if let activity, plan.end.contains(activity.id) { await releaseOwnedActivity() }
        for id in plan.end { await system.end(cardID: id) }
        if let activity, plan.renew.contains(activity.id), let state = lastState {
            await activity.update(ActivityContent(state: state, staleDate: Self.staleDate()))
        }
    }
}
