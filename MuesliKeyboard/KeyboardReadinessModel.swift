import Foundation
import Observation

/// What the keyboard knows about whether dictation can start: the app's published record, the heartbeat, and the
/// verdict on the request in play, reduced to the one state the views show (`KeyboardReadinessDerivation`).
///
/// It owns no decision. It reads the store, asks the pure policies, and writes one log line when the state
/// changes, so the controller carries a property and a few call sites rather than the logic.
@MainActor
@Observable
final class KeyboardReadinessModel {
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored var now: () -> Date = { .now }
    /// Whether the keyboard has Full Access. A store that cannot be read means different things with it on and off.
    @ObservationIgnored var hasFullAccess: (() -> Bool)?

    let stamp = ReadinessBuildStamp.current
    private(set) var record: AppReadinessRecord?
    private(set) var hasStoreAccess = true
    private(set) var liveness = AppLiveness.none
    private(set) var readiness: KeyboardReadiness
    private(set) var presentation: KeyboardReadinessPresentation
    private var request = OwnershipVerdict.notInProgress
    /// How long since the app last reported audio for the recording in play. Set by the controller with the request.
    var recordingSignalAge: TimeInterval?
    private var checkingStartedAt: Date?
    @ObservationIgnored private var loggedCode: String?
    /// Nothing is logged before the store has been read once: the placeholder state is not something the user saw.
    @ObservationIgnored private var hasLoaded = false

    init(store: SharedStore) {
        self.store = store
        let initial = KeyboardReadinessDerivation.derive(KeyboardReadinessInput(
            hasStoreAccess: true, record: nil, keyboardStamp: .current, request: .notInProgress,
            now: .now, checkingStartedAt: nil
        ))
        readiness = initial
        presentation = .make(initial)
    }

    var isAppLive: Bool { liveness.liveBootID != nil }

    /// The keyboard has just appeared: give a heartbeat a moment to arrive before calling the app absent.
    func beginChecking() {
        checkingStartedAt = now()
        reload()
    }

    /// Reads the record. A store that cannot be read with Full Access on keeps what was known: the heartbeat ages
    /// out by itself, so the state still becomes `needsApp` on time.
    func reload() {
        hasLoaded = true
        do {
            record = try store.appReadiness()
            hasStoreAccess = true
        } catch {
            hasStoreAccess = hasFullAccess?() ?? false
        }
        recompute()
    }

    /// The verdict on a persisted handoff, remembered as the request in play.
    @discardableResult
    func judge(_ state: KeyboardHandoffState) -> OwnershipVerdict {
        let verdict = verdict(for: state)
        setRequest(verdict)
        return verdict
    }

    func verdict(for state: KeyboardHandoffState) -> OwnershipVerdict {
        guard state.requestID != nil else { return .notInProgress }
        return RequestOwnershipPolicy.evaluate(
            phase: state.phase.kind,
            owner: state.ownerBootID,
            updatedAt: state.updatedAt,
            liveness: liveness,
            now: now()
        )
    }

    /// A live app confirms this request: its owner is the live boot and, for a recording, audio is arriving.
    var isOwnerConfirmed: Bool {
        switch request {
        case .live, .stalled: readiness.state != .connectionLost
        default: false
        }
    }

    func setRequest(_ verdict: OwnershipVerdict) {
        request = verdict
        recompute()
    }

    private func recompute() {
        let current = now()
        liveness = AppLivenessPolicy.liveness(record: record, keyboardStamp: stamp, now: current)
        let derived = KeyboardReadinessDerivation.derive(KeyboardReadinessInput(
            hasStoreAccess: hasStoreAccess,
            record: record,
            keyboardStamp: stamp,
            request: request,
            now: current,
            checkingStartedAt: checkingStartedAt,
            recordingSignalAge: recordingSignalAge
        ))
        if derived != readiness {
            readiness = derived
            presentation = .make(derived)
        }
        logTransition(derived)
    }

    /// One line per change, shared across keyboard instances through the store.
    private func logTransition(_ derived: KeyboardReadiness) {
        let code = derived.state.code
        guard hasLoaded, code != loggedCode else { return }
        loggedCode = code
        guard (try? store.noteLogged(topic: "keyboard.readiness", value: code)) == true else { return }
        var detail = [
            "readiness": code,
            "action": derived.recordAction.rawValue,
            "model_state": record?.model.code ?? "none",
        ]
        if let record { detail["boot"] = record.bootID.uuidString }
        if let age = liveness.heartbeatAge { detail["heartbeat_age_ms"] = String(Int(age * 1_000)) }
        KeyboardDiagnosticsLog.record("keyboard.readiness", detail)
    }
}
