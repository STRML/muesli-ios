import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class KeyboardController {
    private static let staleRecordingInterval: TimeInterval = 45
    private static let staleStoppingInterval: TimeInterval = 10
    private static let staleTranscribingInterval: TimeInterval = 120
    private let store: SharedStore
    private let eventBus: any CrossProcessEventStreaming
    /// Whether dictation can start, and the truthful state to show (see `KeyboardReadinessModel`).
    let readinessModel: KeyboardReadinessModel
    private let setupVerificationStore: SetupVerificationStore
    private let handoffRecoveryPolicy = KeyboardHandoffRecoveryPolicy.keyboardDefaults
    private var eventObservationTask: Task<Void, Never>?
    private var commandAcknowledgementTask: Task<Void, Never>?
    private var visibilityHeartbeatTask: Task<Void, Never>?
    var currentFullAccess: (() -> Bool)?
    private var latestResultID: UUID?
    private var preparedRequest: DictationRequest?
    private var activeRequestID: UUID? {
        didSet { if activeRequestID == nil { activeRewrite = nil } }
    }
    /// The text a voice edit is working on, while its spoken instruction is being recorded and rewritten.
    private(set) var activeRewrite: RewriteContext?
    /// What the last rewrite replaced, so the user can take it back. Retired by typing or a new dictation.
    private(set) var lastRewrite: RewriteUndo?
    private var recoveryRequestID: UUID?
    private var latestHandoffState: KeyboardHandoffState?
    private var latestRuntimeStatus: KeyboardRuntimeStatus?
    private var insertedRequestIDs = Set<UUID>()
    private var completedClipboardRequestIDs = Set<UUID>()
    private var cancelledRequestIDs = Set<UUID>()
    private var pendingCancellationIDs = Set<UUID>()
    /// The request whose stop is on its way to the app, so a second tap on the pill or the Record key sends no
    /// second stop. It names a request, so the next dictation is unaffected.
    private var pendingStopID: UUID?
    private var isBlockedByAppVoiceNote = false
    /// Names the next readiness trip in the log. A new one after each tap.
    private var prepareTripID = UUID()
    /// Tracked separately from `latestHandoffState`, which `refreshLatestDictation`
    /// overwrites before `apply(handoffState:)` runs -- comparing against it
    /// there always says "unchanged".
    private var lastRecordedHandoff: (requestID: UUID, phase: KeyboardHandoffPhase)?
    private var lastLevelFreshness: Bool?
    private var pendingModelRawValue: String?
    private var hasOpenAccessForSetup = false

    var statusText = "Record a voice note first"
    var hasLatestDictation = false
    var dictationPhase: DictationPhase = .idle {
        didSet {
            // A running dictation owns the strip, so suggestions stop being computed or tappable.
            typing.setSuggestionsSuspended(showsActiveWaveform)
            // Taking the Type page back lasts for one dictation.
            if dictationPhase != .recording, dictationPhase != .transcribing { holdsTypePageThisDictation = false }
            // The preview's elapsed time counts from when this keyboard saw recording begin.
            if dictationPhase == .recording, oldValue != .recording {
                recordingStartedAt = Date()
            } else if dictationPhase != .recording, dictationPhase != .transcribing {
                recordingStartedAt = nil
            }
        }
    }
    private(set) var recordingStartedAt: Date?
    var launchURL: URL?
    var textInserter: (@MainActor (String) -> Void)?
    var textDeleter: (@MainActor (Int) -> Void)?
    /// What the host field holds around the cursor, read when Quill is tapped and again before a rewrite is applied.
    var textContextProvider: (@MainActor () -> KeyboardTextContext)?
    /// The host field as live typing writes to it. Without one, the streaming words only show in the strip.
    var liveTypingHost: LiveTypingHost? {
        get { liveTyper.host }
        set { liveTyper.host = newValue }
    }
    var inputModeSwitcher: (@MainActor () -> Void)?
    var keyboardDismisser: (@MainActor () -> Void)?
    /// `handleInputModeList(from:with:)`: the system keyboard picker. The event is optional only so tests can
    /// call it; UIKit's own touch actions always carry one.
    var inputModeListPresenter: (@MainActor (UIView, UIEvent?) -> Void)?
    var liveTranscript = ""
    /// The app marks the final text it is about to deliver; it is never shown as a preview.
    private var liveTranscriptIsFinal = false
    var inputLevel = 0.0
    var isLaunchSettled = false
    var modelCatalog: KeyboardTranscriptionModelCatalog?
    var setupVerificationChallenge: KeyboardSetupVerificationChallenge?
    private var lastInsertedCharacterCount = 0
    private var canUseRuntimeStart = false
    /// Types the streaming words into the host field as marked text while recording, when the host allows it.
    @ObservationIgnored let liveTyper: KeyboardLiveTyper
    /// Why a delivered result left the field as it was, for the status line.
    private var deliveryNote: String?

    /// Typing (layout, shift, suggestions). Dictation state stays here; the Type page only reads it.
    let typing = KeyboardTypingModel()
    /// The page the user chose. It lives here, not in a view, so a reopened keyboard and its launch snapshot come
    /// up on the page it was left on, and switching pages never touches a running dictation.
    /// Remembered in the keyboard's own defaults (not the shared store, which needs Full Access) so the next
    /// launch opens on the page it was left on. Only a chosen page is stored, never one forced by setup verification.
    var selectedSurface: TypingSurface {
        didSet {
            // Minimal has no Type page to choose, so it must not overwrite the page Full remembered.
            guard selectedSurface != oldValue, layout.offersTypePage else { return }
            surfaceDefaults?.set(selectedSurface.storedValue, forKey: Self.selectedSurfaceDefaultsKey)
        }
    }
    static let selectedSurfaceDefaultsKey = "keyboard.selectedSurface"
    @ObservationIgnored private let surfaceDefaults: UserDefaults?
    var surface: TypingSurface {
        TypingSurface.resolve(
            layout: layout,
            selected: selectedSurface,
            hasPendingSetupVerification: hasPendingSetupVerification,
            phase: pillPhase,
            holdsTypePage: holdsTypePageThisDictation || !showsDictatePanelWhileRecording
        )
    }
    /// The Settings choice to let Full switch to the Dictate panel for a dictation. Off keeps the Type page, which
    /// is what holding it does for one dictation.
    private(set) var showsDictatePanelWhileRecording = false
    /// The user tapped ABC while Full was showing the Dictate page for a dictation: the Type page stays for the rest
    /// of that dictation and the next one switches again. Never written anywhere; it ends with the dictation.
    private(set) var holdsTypePageThisDictation = false

    /// The ABC key on the Dictate page. A plain page choice (remembered like any), and when a dictation is on
    /// screen it is also held for the rest of that dictation, so the page does not jump back under the thumb.
    func showTypePage() {
        guard layout.offersTypePage else { return }
        selectedSurface = .type
        if dictationPhase == .recording || dictationPhase == .transcribing { holdsTypePageThisDictation = true }
    }
    /// The layout the keyboard is showing: Full until an appearance reads another from the shared store. It
    /// changes only at an appearance, never while the keyboard is up (`loadTypingSettings(appliesLayout:)`).
    private(set) var layout: KeyboardLayout = .fallback
    var recordKeyMode: TypingRecordKey.Mode {
        TypingRecordKey.mode(opensMuesli: opensMuesliFromPrimaryButton, hasLaunchURL: effectiveLaunchURL != nil)
    }

    /// The clock the readiness checks use. A test moves it; the extension never touches it.
    var now: () -> Date {
        get { readinessModel.now }
        set { readinessModel.now = newValue }
    }

    var readiness: KeyboardReadiness { readinessModel.readiness }

    /// A live app owns a recording but no audio has arrived for a while: what is on screen is not known to be true.
    /// Stop, insert and the waveform give way to a way back to Muesli, and Cancel works without the app.
    var isConnectionLost: Bool { readiness.state == .connectionLost }
    var readinessPresentation: KeyboardReadinessPresentation { readinessModel.presentation }

    /// Where Record sends the user. When the app is not ready it is a prepare trip: load the model, then say when
    /// to come back. A start request there would only hang.
    var effectiveLaunchURL: URL? {
        if isConnectionLost { return openAppURL }
        return readiness.recordAction == .openAppToPrepare ? prepareURL : launchURL
    }

    private var prepareURL: URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.prepareHost
        components.queryItems = [URLQueryItem(name: MuesliAppConstants.tripQueryItem, value: prepareTripID.uuidString)]
        return components.url
    }

    /// Opens the app and nothing else, for the way out of a state that has stalled.
    var openAppURL: URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.openHost
        return components.url
    }

    init(
        store: SharedStore? = nil,
        eventBus: any CrossProcessEventStreaming = DarwinCrossProcessEventBus.shared,
        setupVerificationStore: SetupVerificationStore = SetupVerificationStore(),
        liveTypingScheduler: LiveTypingScheduler = .system,
        surfaceDefaults: UserDefaults? = nil
    ) {
        self.surfaceDefaults = surfaceDefaults
        selectedSurface = TypingSurface.atLaunch(
            layout: .fallback,
            stored: surfaceDefaults?.string(forKey: Self.selectedSurfaceDefaultsKey),
            hasPendingSetupVerification: false,
            phase: .idle
        )
        liveTyper = KeyboardLiveTyper(scheduler: liveTypingScheduler)
        self.eventBus = eventBus
        let resolvedStore = store ?? SharedStore(eventPoster: eventBus)
        self.store = resolvedStore
        readinessModel = KeyboardReadinessModel(store: resolvedStore)
        self.setupVerificationStore = setupVerificationStore
        typing.document.inserter = { [weak self] in self?.insertTypedText($0) }
        typing.document.backspacer = { [weak self] in self?.deleteTypedBackward() }
        readinessModel.hasFullAccess = { [weak self] in
            guard let self else { return false }
            return self.currentFullAccess?() ?? self.hasOpenAccessForSetup
        }
    }

    static let unreachableAppMessage = "Couldn't reach Muesli. Open the app."

    /// A shared-store error usually means Full Access is off. When it is on, asking for it again is wrong:
    /// the App Group is unreachable for another reason, and opening the app is what can fix it.
    private func sharedStoreFailureMessage(withoutFullAccess: String = "Enable Full Access") -> String {
        (currentFullAccess?() ?? hasOpenAccessForSetup) ? Self.unreachableAppMessage : withoutFullAccess
    }

    var hasPendingSetupVerification: Bool {
        setupVerificationChallenge?.isActive() == true
    }

    var setupVerificationDetail: String {
        hasOpenAccessForSetup
            ? "Proves Keyboard and Full Access"
            : "Proves Keyboard • Full Access still off"
    }

    var showsLiveTranscript: Bool { livePreview != nil }

    /// The streaming words shown while recording, dimmed while the final pass runs. Display only: live typing into
    /// the field is `liveTyper`'s job, and only a delivered result is ever handed to `textInserter`.
    var livePreview: KeyboardLivePreview? {
        guard activeRequestID != nil else { return nil }
        return KeyboardLivePreview.make(
            isRecording: dictationPhase == .recording,
            isTranscribing: dictationPhase == .transcribing,
            isRewriting: activeRewrite != nil,
            text: liveTranscript,
            isFinal: liveTranscriptIsFinal
        )
    }

    var primaryButtonTitle: String {
        return switch primaryButtonRole {
        case .blocked:
            "Voice Note Active"
        case .openMuesliRecovery:
            "Open Muesli"
        case .waitingForMuesli:
            "Waiting for Muesli"
        case .openMuesliRequested:
            "Open Muesli"
        case .prepareMuesli:
            readinessPresentation.recordTitle
        case .stop:
            "Stop"
        case .transcribing:
            "Transcribing"
        case .inserted:
            "Inserted"
        case .record:
            "Record"
        }
    }

    var primaryButtonIcon: String {
        return switch primaryButtonRole {
        case .blocked:
            "waveform"
        case .openMuesliRecovery:
            "arrow.up.forward.app"
        case .waitingForMuesli:
            "hourglass"
        case .openMuesliRequested:
            "arrow.up.forward.app"
        case .prepareMuesli:
            readinessPresentation.recordSymbol
        case .stop:
            "stop.fill"
        case .transcribing:
            "waveform"
        case .inserted:
            "checkmark"
        case .record:
            "mic.fill"
        }
    }

    var stylesPrimaryButtonAsStop: Bool {
        primaryButtonRole == .stop
    }

    var primaryButtonRole: KeyboardPrimaryButtonRole {
        if isBlockedByAppVoiceNote {
            return .blocked
        }
        if recoveryRequestID != nil {
            return .openMuesliRecovery
        }

        if latestHandoffState.map({ [.stopRequested, .cancelRequested].contains($0.phase) }) == true {
            return .waitingForMuesli
        }

        if isConnectionLost {
            return .openMuesliRecovery
        }
        if isIdleForPrimaryButton, readiness.recordAction == .openAppToPrepare {
            return .prepareMuesli
        }

        return switch dictationPhase {
        case .requested:
            activeRequestID == nil ? .openMuesliRequested : .stop
        case .recording:
            .stop
        case .transcribing:
            .transcribing
        case .finished:
            .record
        default:
            .record
        }
    }

    var isPrimaryButtonDisabled: Bool {
        guard !isConnectionLost else { return false }
        return isBlockedByAppVoiceNote || recoveryRequestID == nil && (
            dictationPhase == .transcribing
            || latestHandoffState.map({ [.stopRequested, .cancelRequested].contains($0.phase) }) == true
        )
    }

    var canInsertLatest: Bool {
        hasLatestDictation && activeRequestID == nil
    }

    var canUndoRewrite: Bool { lastRewrite != nil }

    /// The app has a Custom LLM, so the Quill key can work.
    var canRewrite: Bool {
        latestRuntimeStatus?.rewriteAvailable == true
    }

    /// Remote processing is on in the app but this keyboard has no Full Access, so dictations stay on the phone.
    var remoteProcessingBanner: String? {
        RemoteTranscriptionPolicy.keyboardBanner(
            remoteProcessingEnabled: latestRuntimeStatus?.remoteProcessingEnabled == true,
            hasFullAccess: hasOpenAccessForSetup
        )
    }

    var showsActiveWaveform: Bool {
        [.requested, .recording, .transcribing].contains(dictationPhase)
    }

    var waveformMode: MuesliFloatingWaveformMode {
        MuesliKeyboardWaveformPresentation.mode(for: dictationPhase)
    }

    var waveformLevel: Double? {
        MuesliKeyboardWaveformPresentation.level(for: dictationPhase, inputLevel: inputLevel)
    }

    var canCancelActiveDictation: Bool {
        [.requested, .recording, .transcribing].contains(dictationPhase)
            && !(activeRequestID.map { pendingCancellationIDs.contains($0) } ?? false)
    }

    private var isStopPending: Bool {
        activeRequestID != nil && pendingStopID == activeRequestID
    }

    private var isCancelPending: Bool {
        activeRequestID.map { pendingCancellationIDs.contains($0) } ?? false
    }

    private static let settledPillPhases: [KeyboardHandoffPhase: TypingPillPhase] = [
        .copyRequired: .copyRequired,
        .cancelled: .cancelled,
    ]

    private var pillPhase: TypingPillPhase {
        switch dictationPhase {
        case .idle:
            Self.settledPillPhases[latestHandoffState?.phase ?? .idle] ?? .idle
        case .requested: .requested
        case .recording: .recording
        case .transcribing: .transcribing
        case .finished: .inserting
        case .failed: .failed
        }
    }

    /// Whether the wide pill in the strip stops and saves the dictation right now: while it records, and not
    /// once a stop or a cancel is on its way.
    var canStopFromStatusPill: Bool {
        !isConnectionLost && TypingStripPill.isTappable(phase: pillPhase, stopRequested: isStopPending, cancelRequested: isCancelPending)
    }

    /// A tap on the strip's pill: the Record key's stop, behind the pill's own guard.
    func stopFromStatusPill() {
        refreshLatestDictation()
        guard canStopFromStatusPill else { return }
        stopActiveDictation()
    }

    var selectedTranscriptionModel: KeyboardTranscriptionModelOption? {
        modelCatalog?.selectedModel
    }

    var readyTranscriptionModels: [KeyboardTranscriptionModelOption] {
        modelCatalog?.readyModels ?? []
    }

    var canSelectTranscriptionModel: Bool {
        modelCatalog?.canSelectModels == true
            && !showsActiveWaveform
            && pendingModelRawValue == nil
    }

    var modelChipTitle: String {
        selectedTranscriptionModel?.shortName ?? "Model"
    }

    var isModelSelectionPending: Bool {
        pendingModelRawValue != nil
    }

    var settingsURL: URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.settingsHost
        return components.url
    }

    private var isIdleForPrimaryButton: Bool {
        dictationPhase == .idle
            || dictationPhase == .finished
            || dictationPhase == .failed
            || (dictationPhase == .requested && activeRequestID == nil)
    }

    /// Not ready to dictate: the app has to load, or finish something, before a start request could work.
    private var readinessSendsTheUserToTheApp: Bool {
        [.openAppToPrepare, .openAppToRecover].contains(readiness.recordAction)
    }

    var opensMuesliFromPrimaryButton: Bool {
        !isBlockedByAppVoiceNote
            && (recoveryRequestID != nil
                || isConnectionLost
                || (!canUseRuntimeStart || readinessSendsTheUserToTheApp) && isIdleForPrimaryButton)
    }

    func primaryLaunchAction() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        if recoveryRequestID != nil || isConnectionLost {
            statusText = "Opening Muesli"
            return
        }
        if readiness.recordAction == .openAppToPrepare {
            noteReadinessTrip()
            return
        }

        startDictation()
    }

    /// The tap that opens Muesli to get ready. No request is claimed: the app is not in a position to start one.
    private func noteReadinessTrip() {
        MuesliHaptics.dictationStart()
        KeyboardDiagnosticsLog.record("intent.prepare", [
            "readiness": readiness.state.code,
            "action": readiness.recordAction.rawValue,
        ])
        prepareTripID = UUID()
        statusText = "Opening Muesli"
    }

    func primaryAction() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        switch dictationPhase {
        case .requested, .recording:
            stopActiveDictation()
        case .transcribing:
            break
        case .finished:
            if canUseRuntimeStart {
                startDictation()
            } else {
                prepareLaunchRequestIfNeeded()
                statusText = "Open Muesli"
            }
        default:
            startDictation()
        }
    }

    func insertLatestDictation() {
        do {
            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                statusText = "Record a voice note first"
                return
            }

            guard textInserter != nil else { return }
            insertDictatedText(result.text)
            insertedRequestIDs.insert(result.requestID)
            try store.acknowledgeKeyboardDelivery(for: result.requestID)
            latestResultID = result.id
            hasLatestDictation = true
            statusText = "Inserted"
        } catch {
            statusText = sharedStoreFailureMessage()
        }
    }

    func selectTranscriptionModel(_ model: KeyboardTranscriptionModelOption) {
        guard model.isReady,
              model.rawValue != modelCatalog?.selectedRawValue,
              canSelectTranscriptionModel
        else { return }

        do {
            pendingModelRawValue = model.rawValue
            try store.saveKeyboardModelSelectionRequest(.init(modelRawValue: model.rawValue))
            statusText = "Switching to \(model.shortName)"
            KeyboardDiagnosticsLog.record("model.select", ["model": model.rawValue])
        } catch {
            pendingModelRawValue = nil
            statusText = sharedStoreFailureMessage()
        }
    }

    func prepareLaunchRequestIfNeeded() {
        guard preparedRequest == nil, activeRequestID == nil, recoveryRequestID == nil else { return }
        let request = DictationRequest()
        preparedRequest = request
        launchURL = makeLaunchURL(for: request)
    }

    /// The Quill key: record a spoken instruction and rewrite the selection, or the last paragraph before the
    /// cursor, with it.
    func startRewrite() {
        guard !isBlockedByAppVoiceNote else { return }
        guard canRewrite else {
            statusText = "Set up a Custom LLM in Muesli"
            return
        }
        guard readiness.recordAction != .openAppToPrepare else {
            statusText = readinessPresentation.caption ?? "Open Muesli to get ready"
            return
        }
        let text = textContextProvider?() ?? KeyboardTextContext()
        switch RewriteCapture.context(from: text) {
        case .failure(.nothingToFix):
            statusText = "Nothing to fix"
        case .failure(.selectionTooLong):
            statusText = "Selection too long"
        case .success(let context):
            preparedRequest = DictationRequest(rewrite: context)
            startDictation()
        }
    }

    func startDictation() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }

        MuesliHaptics.dictationStart()
        KeyboardDiagnosticsLog.record("intent.start", [
            "canUseRuntimeStart": canUseRuntimeStart ? "yes" : "no",
            "appPhase": latestRuntimeStatus?.phase.rawValue ?? "unknown",
            "appSeenAt": latestRuntimeStatus.map {
                String(format: "%.1fs", Date.now.timeIntervalSince($0.updatedAt))
            } ?? "never"
        ])
        let request = preparedRequest ?? DictationRequest()
        do {
            try store.claimRequest(request)
        } catch SharedStoreError.requestInProgress {
            refreshLatestDictation()
            statusText = "Finish the current dictation"
            return
        } catch {
            statusText = sharedStoreFailureMessage()
            return
        }
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = makeLaunchURL(for: request)
        lastRewrite = nil
        liveTyper.reset()
        activeRequestID = request.id
        activeRewrite = request.rewrite
        liveTranscript = ""
        insertedRequestIDs.remove(request.id)
        cancelledRequestIDs.remove(request.id)
        dictationPhase = .requested
        statusText = "Opening Muesli"

        do {
            try store.clearKeyboardLiveTranscript()
            try store.saveKeyboardHandoffState(.init(
                requestID: request.id,
                phase: .startRequested,
                message: canUseRuntimeStart ? "Starting" : "Opening Muesli"
            ))
            if canUseRuntimeStart {
                try store.saveCommand(.init(requestID: request.id, action: .start))
                awaitCommandAcknowledgement(
                    requestID: request.id,
                    action: .start,
                    requestedPhase: .startRequested
                )
            }
        } catch {
            statusText = sharedStoreFailureMessage()
            activeRequestID = nil
            dictationPhase = .idle
            return
        }

        statusText = canUseRuntimeStart ? "Starting" : "Recording in Muesli"
    }

    private func stopActiveDictation() {
        guard let activeRequestID else {
            dictationPhase = .idle
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }
        guard !isStopPending, !isCancelPending else { return }

        MuesliHaptics.dictationStop()
        KeyboardDiagnosticsLog.record("intent.stop", [
            "request": String(activeRequestID.uuidString.prefix(8).lowercased()),
            "localPhase": dictationPhase.rawValue
        ])
        do {
            try store.saveKeyboardHandoffState(.init(
                requestID: activeRequestID,
                phase: .stopRequested,
                message: "Stopping"
            ))
            try store.saveCommand(.init(requestID: activeRequestID, action: .stop))
            pendingStopID = activeRequestID
            dictationPhase = .recording
            statusText = "Stopping"
            awaitCommandAcknowledgement(
                requestID: activeRequestID,
                action: .stop,
                requestedPhase: .stopRequested
            )
        } catch {
            statusText = sharedStoreFailureMessage()
        }
    }

    /// A key typed on the Type page. It retires an Undo edit like any typing, but leaves the status text alone.
    func insertTypedText(_ text: String) {
        lastRewrite = nil
        insertText(text)
    }

    func deleteTypedBackward() {
        lastRewrite = nil
        deleteFromHost(1)
        lastInsertedCharacterCount = 0
    }

    func insertSpace() {
        lastRewrite = nil
        insertText(" ")
    }

    func insertTextKey(_ text: String) {
        lastRewrite = nil
        insertText(text)
    }

    func insertReturn() {
        lastRewrite = nil
        insertText("\n")
    }

    func switchInputMode() {
        inputModeSwitcher?()
    }

    /// Every touch on our globe, which only exists when the system draws none. The system tracks the touch: it
    /// switches on a tap and lists the keyboards on a long press.
    func globeTouchTracked(from view: UIView, with event: UIEvent?) {
        inputModeListPresenter?(view, event)
    }

    func dismissKeyboard() {
        keyboardDismisser?()
    }

    func clearInsertedText() {
        let deleteCount = max(lastInsertedCharacterCount, 1)
        deleteFromHost(deleteCount)
        lastInsertedCharacterCount = 0
        statusText = deleteCount > 1 ? "Cleared" : "Deleted"
    }

    func deleteBackward() {
        lastRewrite = nil
        deleteFromHost(1)
        lastInsertedCharacterCount = 0
        statusText = "Deleted"
    }

    /// iOS's own dictation started under this keyboard. Two dictations cannot share the mic, so Muesli's ends.
    func systemDictationDidStart() {
        guard [.requested, .recording].contains(dictationPhase) else { return }
        cancelActiveDictation()
    }

    /// Whether iOS's own dictation is on, as read by the view controller when the keyboard appears.
    var systemDictationEnabled: Bool?

    func cancelActiveDictation() {
        refreshLatestDictation()
        guard canCancelActiveDictation else {
            statusText = dictationPhase == .transcribing ? "Transcribing" : statusText
            return
        }

        guard let activeRequestID else {
            dictationPhase = .idle
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }

        MuesliHaptics.dictationStop()
        do {
            try store.saveKeyboardHandoffState(.init(
                requestID: activeRequestID,
                phase: .cancelRequested,
                message: "Cancelling"
            ))
            try store.saveCommand(.init(requestID: activeRequestID, action: .cancel))
            // Nobody confirms this request, so nobody will acknowledge the cancel. End it here, once, so the
            // persisted state can never bring the recording back when the keyboard is next shown.
            if !readinessModel.isOwnerConfirmed {
                cancelWithoutAnOwner(activeRequestID)
                return
            }
            pendingCancellationIDs.insert(activeRequestID)
            // The words come out now; a late partial from the app is ignored.
            liveTyper.cancel(requestID: activeRequestID)
            latestHandoffState = .init(requestID: activeRequestID, phase: .cancelRequested, message: "Cancelling")
            dictationPhase = .recording
            statusText = "Cancelling"
            awaitCommandAcknowledgement(
                requestID: activeRequestID,
                action: .cancel,
                requestedPhase: .cancelRequested
            )
        } catch {
            statusText = sharedStoreFailureMessage()
        }
    }

    /// The user cancelled a request no live app confirms. The cancel command stays for an app that only looks
    /// quiet, and the request ends as cancelled by this keyboard, atomically, whatever the app does later.
    private func cancelWithoutAnOwner(_ requestID: UUID) {
        let owner = (try? store.keyboardHandoffState())?.ownerBootID
        let won = (try? store.abandonRequest(requestID, expectedOwner: owner, reason: .ownerLost, endingAs: .cancelled)) ?? false
        if won { logAbandoned(requestID, reason: .ownerLost, phase: .cancelRequested, owner: owner) }
        liveTyper.cancel(requestID: requestID)
        cancelledRequestIDs.insert(requestID)
        pendingCancellationIDs.remove(requestID)
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = nil
        pendingStopID = nil
        latestHandoffState = .init(requestID: requestID, phase: .cancelled, message: "Cancelled", ownerBootID: owner, endReason: AbandonReason.ownerLost.rawValue)
        releaseLocalRequest(requestID)
        readinessModel.setRequest(.notInProgress)
    }

    private func hasPendingCancelCommand() -> Bool {
        guard let command = try? store.pendingCommand(), command.action == .cancel else { return false }
        return cancelledRequestIDs.contains(command.requestID)
    }

    func prepareInitialPresentationState() {
        refreshSetupVerificationChallenge()
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
    }

    func startObservingSharedState(hasOpenAccess: Bool = true) {
        hasOpenAccessForSetup = hasOpenAccess
        refreshSetupVerificationChallenge()
        KeyboardDiagnosticsLog.record("keyboard.appeared")
        markKeyboardVisible(hasOpenAccess: hasOpenAccess)
        // Ask a running app for a beat right now, and give it a moment to answer before calling it absent.
        readinessModel.beginChecking()
        eventBus.post(.readinessProbe)
        visibilityHeartbeatTask?.cancel()
        visibilityHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.publishVisibilityHeartbeat()
                self.reevaluateReadiness()
            }
        }
        eventObservationTask?.cancel()
        let events = eventBus.events()
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
        eventObservationTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .runtimeStatusChanged:
                    self.refreshRuntimeStatus()
                case .modelCatalogChanged:
                    self.refreshModelCatalog()
                case .liveTranscriptChanged:
                    self.refreshLiveTranscript()
                case .handoffStatusChanged, .resultChanged, .ownershipChanged:
                    self.refreshLatestDictation()
                case .typingSettingsChanged:
                    self.loadTypingSettings()
                case .readinessChanged:
                    self.reevaluateReadiness()
                case .commandChanged, .modelSelectionRequested, .readinessProbe:
                    break
                }
            }
        }
    }

    /// Re-reads the app's record and re-judges the request in play. Time passing is an input (a heartbeat ages out,
    /// a stage passes its bound), so this runs on the keyboard's one-second tick as well as on events. The full
    /// refresh only runs when something that could change a request's fate has.
    func reevaluateReadiness() {
        let liveBefore = readinessModel.liveness.liveBootID
        readinessModel.reload()
        let hasRequestInPlay = showsActiveWaveform
            || latestHandoffState.map { $0.phase.kind != .idle && !Self.settledPhases.contains($0.phase) } == true
        if liveBefore != readinessModel.liveness.liveBootID || hasRequestInPlay {
            refreshLatestDictation()
        }
    }

    private static let settledPhases: Set<KeyboardHandoffPhase> = [.idle, .inserted, .copyRequired, .cancelled, .failed]

    func publishVisibilityHeartbeat() {
        let access = currentFullAccess?() ?? hasOpenAccessForSetup
        hasOpenAccessForSetup = access
        refreshSetupVerificationChallenge()
        // Heartbeats must not replace recording or setup messages on failure.
        try? store.saveKeyboardExtensionStatus(.init(
            lastSeenAt: .now, hasOpenAccess: access, isVisible: true, systemDictationEnabled: systemDictationEnabled
        ))
    }

    func markKeyboardVisible(hasOpenAccess: Bool = true) {
        hasOpenAccessForSetup = hasOpenAccess
        refreshSetupVerificationChallenge()
        do {
            try store.saveKeyboardExtensionStatus(.init(
                lastSeenAt: .now,
                hasOpenAccess: hasOpenAccess,
                isVisible: true,
                systemDictationEnabled: systemDictationEnabled
            ))
        } catch {
            statusText = sharedStoreFailureMessage()
        }
    }

    func stopObservingSharedState() {
        // The waveform renders live microphone input. Off screen there is none,
        // so holding the last level is wrong -- and the controller outlives a
        // dismissal, so that stale level gets baked into the launch snapshot
        // and replayed for a moment on the way back in. Settle it now; the
        // refresh in prepareInitialPresentationState repopulates it from the
        // app's published status if a recording is still running.
        inputLevel = 0
        liveTranscript = ""
        // While the proxy is still there: take the marked words out, so none dangles and a recreated keyboard that
        // replays the delivery cannot insert them a second time.
        liveTyper.yield(.hidden)

        KeyboardDiagnosticsLog.record("keyboard.disappeared", [
            "localPhase": dictationPhase.rawValue,
            "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none"
        ])
        eventObservationTask?.cancel()
        eventObservationTask = nil
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = nil
        visibilityHeartbeatTask?.cancel()
        visibilityHeartbeatTask = nil
        if let status = try? store.keyboardExtensionStatus() {
            try? store.saveKeyboardExtensionStatus(.init(
                lastSeenAt: .now,
                hasOpenAccess: status.hasOpenAccess,
                isVisible: false,
                systemDictationEnabled: status.systemDictationEnabled
            ))
        }
    }

    func verifyKeyboardSetup() {
        refreshSetupVerificationChallenge()
        guard let challenge = setupVerificationChallenge, challenge.isActive() else {
            statusText = "Return to Muesli and restart the test"
            return
        }

        // Inserting the nonce response through UITextDocumentProxy proves that
        // this keyboard is both installed and active. It deliberately bypasses
        // insertText(_:), whose character count belongs to transcript replacement.
        liveTyper.yield(.yielded)
        textInserter?(challenge.responseToken)
        if hasOpenAccessForSetup {
            setupVerificationStore.saveKeyboardReceipt(
                for: challenge,
                hasFullAccess: true
            )
            statusText = "Setup verified"
        } else {
            statusText = "Keyboard verified • Enable Full Access"
        }
    }

    private func refreshSetupVerificationChallenge() {
        setupVerificationChallenge = setupVerificationStore.activeKeyboardChallenge()
    }

    private func refreshLatestDictation() {
        readinessModel.reload()
        do {
            refreshModelCatalog()
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            let status = try store.status()
            let handoffState = try store.keyboardHandoffState()
            if handoffState.phase == .copyRequired, let requestID = handoffState.requestID {
                completedClipboardRequestIDs.insert(requestID)
            }
            if handoffState.phase == .cancelled, let requestID = handoffState.requestID {
                cancelledRequestIDs.insert(requestID)
                pendingCancellationIDs.remove(requestID)
            }
            if handoffState.phase == .inserted, let requestID = handoffState.requestID {
                insertedRequestIDs.insert(requestID)
            }
            apply(runtimeStatus: runtimeStatus)
            if let command = try store.pendingCommand(), command.action == .cancel {
                pendingCancellationIDs.insert(command.requestID)
            }
            latestHandoffState = handoffState
            apply(handoffState: handoffState)
            apply(liveTranscript: try store.keyboardLiveTranscript())

            let statusBelongsToAppVoiceNote = applyAppVoiceNoteOwnership(status: status)
            if !statusBelongsToAppVoiceNote,
               (handoffState.requestID == nil || status.requestID == handoffState.requestID),
               (handoffState.requestID == nil
                || [.idle, .failed, .cancelled, .inserted].contains(handoffState.phase)) {
                apply(status: status)
            }
            if isBlockedByAppVoiceNote {
                return
            }

            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                if activeRequestID == nil, !isBlockedByAppVoiceNote {
                    statusText = "Ready"
                }
                return
            }

            hasLatestDictation = true
            // Delivery is independent of whichever request now owns capture.
            for pending in try store.pendingKeyboardDeliveries() {
                insertCompletedResult(pending)
            }

            if latestResultID != result.id {
                latestResultID = result.id
                if activeRequestID == nil, !isBlockedByAppVoiceNote {
                    statusText = "Latest ready"
                }
            } else if activeRequestID == nil,
                      !isBlockedByAppVoiceNote,
                      statusText != "Inserted",
                      statusText != Self.staleRewriteMessage,
                      statusText != Self.keptWordsMessage {
                statusText = "Latest ready"
            }
        } catch {
            apply(runtimeStatus: latestRuntimeStatus)
            statusText = sharedStoreFailureMessage(withoutFullAccess: "Waiting for Full Access")
        }
    }

    private func refreshModelCatalog() {
        guard let catalog = try? store.keyboardModelCatalog() else { return }
        modelCatalog = catalog
        guard let pendingModelRawValue else { return }

        if catalog.selectedRawValue == pendingModelRawValue {
            self.pendingModelRawValue = nil
            statusText = "\(catalog.selectedModel?.shortName ?? "Model") ready"
        } else if (try? store.keyboardModelSelectionRequest()) == nil {
            self.pendingModelRawValue = nil
            statusText = catalog.canSelectModels ? "Model unchanged" : "Finish recording to switch"
        }
    }

    private func refreshRuntimeStatus() {
        do {
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            apply(runtimeStatus: runtimeStatus)
        } catch {
            statusText = sharedStoreFailureMessage(withoutFullAccess: "Waiting for Full Access")
        }
    }

    private func refreshLiveTranscript() {
        do {
            apply(liveTranscript: try store.keyboardLiveTranscript())
        } catch {
            statusText = sharedStoreFailureMessage(withoutFullAccess: "Waiting for Full Access")
        }
    }

    private func apply(handoffState: KeyboardHandoffState) {
        guard let requestID = handoffState.requestID else {
            readinessModel.setRequest(.notInProgress)
            return
        }
        settleLiveTyping(for: handoffState.phase, requestID: requestID)

        // Nothing below runs for a request whose owner is gone. A persisted phase is a claim, and only a live owner
        // can make it true: otherwise the keyboard would show listening or writing for a request nobody holds.
        readinessModel.recordingSignalAge = recordingSignalAge(for: handoffState)
        let verdict = readinessModel.judge(handoffState)
        if case let .abandoned(reason) = verdict {
            settleAbandoned(handoffState, reason: reason)
            return
        }
        if case .deliverable(isFresh: false) = verdict {
            releaseLocalRequest(requestID)
            return
        }

        if let activeRequestID, activeRequestID != requestID {
            // A resumed extension must follow the durable owner, even if the
            // previous request completed while this keyboard was off screen.
            self.activeRequestID = nil
            recoveryRequestID = nil
            preparedRequest = nil
            liveTranscript = ""
            inputLevel = 0
            dictationPhase = .idle
        }

        recordObservedHandoff(handoffState, requestID: requestID)

        if insertedRequestIDs.contains(requestID) {
            reconcileInsertedRequest(requestID)
            return
        }

        // A late recorder/transcriber update must not reverse the user's Cancel.
        if pendingCancellationIDs.contains(requestID) {
            if [.cancelled, .failed, .idle].contains(handoffState.phase) {
                pendingCancellationIDs.remove(requestID)
                cancelledRequestIDs.insert(requestID)
            } else if !(handoffState.phase == .recoveryRequested && handoffState.recoveryAction == .cancel) {
                activeRequestID = requestID
                recoveryRequestID = nil
                latestHandoffState = .init(requestID: requestID, phase: .cancelRequested, message: "Cancelling")
                dictationPhase = .recording
                inputLevel = 0
                liveTranscript = ""
                statusText = "Cancelling"
                return
            }
        }

        if ![.startRequested, .stopRequested, .cancelRequested].contains(handoffState.phase) {
            commandAcknowledgementTask?.cancel()
            commandAcknowledgementTask = nil
        }

        if cancelledRequestIDs.contains(requestID) {
            if [.cancelled, .idle, .failed].contains(handoffState.phase),
               activeRequestID == nil || activeRequestID == requestID
            {
                activeRequestID = nil
                recoveryRequestID = nil
                liveTranscript = ""
                dictationPhase = .idle
                inputLevel = 0
                statusText = hasLatestDictation ? "Latest ready" : "Ready"
            }
            return
        }

        if completedClipboardRequestIDs.contains(requestID) {
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            dictationPhase = .finished
            statusText = handoffState.phase == .copyRequired
                ? "Saved — open Muesli to copy" : "Saved to Voice Notes"
            return
        }

        activeRequestID = requestID

        if markHandoffForRecoveryIfStale(handoffState) {
            return
        }

        recoveryRequestID = handoffState.phase == .recoveryRequested ? requestID : nil

        switch handoffState.phase {
        case .idle:
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        case .startRequested:
            dictationPhase = .requested
            statusText = handoffState.message ?? "Starting"
        case .startAcknowledged:
            dictationPhase = .requested
            statusText = handoffState.message ?? "Starting"
        case .recordingStarted:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Listening"
        case .stopRequested:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Stopping"
        case .cancelRequested:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Cancelling"
        case .stopAcknowledged:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Finalizing audio"
        case .audioSaved:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Audio saved"
        case .transcribingStarted:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Transcribing"
        case .resultReady:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Inserting"
        case .copyRequired:
            dictationPhase = .finished
            activeRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = "Saved — open Muesli to copy"
        case .inserted:
            dictationPhase = .finished
            activeRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = "Inserted"
        case .recoveryRequested:
            dictationPhase = .failed
            recoveryRequestID = requestID
            launchURL = makeLaunchURL(
                for: requestID,
                action: urlAction(for: handoffState.recoveryAction ?? .start)
            )
            statusText = handoffState.message ?? "Open Muesli to finish"
        case .failed:
            // A request ended because its owner was gone is not a failure the user needs to read.
            let endedByAbandon = handoffState.endReason != nil
            dictationPhase = endedByAbandon ? .idle : .failed
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = endedByAbandon
                ? (hasLatestDictation ? "Latest ready" : "Ready")
                : (handoffState.message ?? "Voice note failed")
        case .cancelled:
            cancelledRequestIDs.insert(requestID)
            dictationPhase = .idle
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    /// The handoff record is written by both processes with no ordering guarantee, so record what arrived and what
    /// we were already showing. A phase that moves backwards is visible here and nowhere else. The keyboard is
    /// rebuilt constantly and each new instance used to log the row it found again, so the store remembers the
    /// last one logged.
    private func recordObservedHandoff(_ handoffState: KeyboardHandoffState, requestID: UUID) {
        guard lastRecordedHandoff?.phase != handoffState.phase || lastRecordedHandoff?.requestID != requestID else { return }
        lastRecordedHandoff = (requestID, handoffState.phase)
        let shortID = requestID.uuidString.prefix(8).lowercased()
        guard (try? store.noteLogged(topic: "handoff.observed", value: "\(shortID).\(handoffState.phase.rawValue)")) ?? true else {
            return
        }
        var observed = [
            "phase": handoffState.phase.rawValue,
            "request": shortID,
            "localPhase": dictationPhase.rawValue,
            "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none",
            "inserted": insertedRequestIDs.contains(requestID) ? "yes" : "no"
        ]
        if handoffState.phase == .failed, let message = handoffState.message {
            observed["reason"] = message
        }
        KeyboardDiagnosticsLog.record("handoff.observed", observed)
    }

    private func apply(runtimeStatus: KeyboardRuntimeStatus?) {
        let now = Date()
        // The waveform draws live microphone input. It needs two facts and no
        // bookkeeping: the app is recording, and a level arrived recently.
        //
        // This used to also require the level to name the request this keyboard
        // had adopted. That match was added when the waveform was first switched
        // on, not in response to any bug, and it caused one: iOS destroys and
        // rebuilds the keyboard constantly, and a rebuilt one has adopted
        // nothing, so levels milliseconds old were thrown away and every bar
        // collapsed to zero while the pill still said "Listening".
        //
        // It is not what stops the keyboard rendering an in-app voice note's
        // audio either. A recording the keyboard does not own blocks it
        // outright and hides the waveform card -- see applyAppVoiceNoteOwnership.
        //
        // The freshness rule stays: when levels stop arriving the bars settle
        // rather than freezing on the last sample.
        let hasFreshRecordingLevel = runtimeStatus.map {
            $0.phase == .recording && now.timeIntervalSince($0.updatedAt) < 2
        } ?? false
        // A recording whose levels have gone stale collapses every waveform bar
        // to zero, so the strip looks empty while the pill still says
        // "Listening". Record the transition, not every sample.
        if runtimeStatus?.phase == .recording, hasFreshRecordingLevel != lastLevelFreshness {
            lastLevelFreshness = hasFreshRecordingLevel
            KeyboardDiagnosticsLog.record("level.freshness", [
                "fresh": hasFreshRecordingLevel ? "yes" : "no",
                "age": runtimeStatus.map { String(format: "%.1fs", now.timeIntervalSince($0.updatedAt)) } ?? "none",
                "appPhase": runtimeStatus?.phase.rawValue ?? "none",
                "matchesActive": runtimeStatus?.activeRequestID == activeRequestID ? "yes" : "no"
            ])
        }
        inputLevel = hasFreshRecordingLevel ? (runtimeStatus?.inputLevel ?? 0) : 0
        canUseRuntimeStart = runtimeStatus.map {
            $0.canAcceptStartCommand && now.timeIntervalSince($0.updatedAt) < handoffRecoveryPolicy.runtimeFreshnessInterval
        } ?? false

        guard activeRequestID == nil, canUseRuntimeStart, readinessModel.isAppLive else { return }
        guard let runtimeRequestID = runtimeStatus?.activeRequestID,
              !insertedRequestIDs.contains(runtimeRequestID),
              !cancelledRequestIDs.contains(runtimeRequestID),
              !completedClipboardRequestIDs.contains(runtimeRequestID)
        else {
            return
        }

        activeRequestID = runtimeRequestID
        if runtimeStatus?.phase == .idle {
            statusText = runtimeStatus?.message ?? "Session ready"
        }
    }

    private func apply(status: DictationStatus) {
        guard !applyAppVoiceNoteOwnership(status: status) else { return }
        guard let requestID = status.requestID else {
            if activeRequestID != nil {
                activeRequestID = nil
                dictationPhase = .idle
                liveTranscript = ""
            }
            return
        }

        if activeRequestID == nil, preparedRequest?.id == requestID, status.phase == .requested {
            return
        }

        if insertedRequestIDs.contains(requestID) {
            reconcileInsertedRequest(requestID)
            return
        }
        if cancelledRequestIDs.contains(requestID) || completedClipboardRequestIDs.contains(requestID) {
            return
        }

        let resumablePhases: [DictationPhase] = [.requested, .recording, .transcribing, .finished]
        let isRecentStatus = Date().timeIntervalSince(status.updatedAt) < 120
        // A status is only worth adopting while the app that wrote it is alive.
        if activeRequestID == nil, isRecentStatus, readinessModel.isAppLive, resumablePhases.contains(status.phase) {
            activeRequestID = requestID
        }

        guard activeRequestID == requestID else { return }

        if markForRecoveryIfStale(status, requestID: requestID) {
            return
        }

        switch status.phase {
        case .requested:
            recoveryRequestID = nil
            if activeRequestID == nil {
                dictationPhase = .requested
                statusText = "Open Muesli to record"
            } else {
                dictationPhase = .recording
                statusText = "Recording in Muesli"
            }
        case .recording:
            recoveryRequestID = nil
            dictationPhase = .recording
            statusText = "Recording in Muesli"
        case .transcribing:
            recoveryRequestID = nil
            dictationPhase = .transcribing
            statusText = status.message ?? "Transcribing"
        case .failed:
            recoveryRequestID = nil
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            statusText = status.message ?? "Voice note failed"
        case .finished:
            recoveryRequestID = nil
            dictationPhase = .finished
            break
        case .idle:
            recoveryRequestID = nil
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    @discardableResult
    private func applyAppVoiceNoteOwnership(status: DictationStatus) -> Bool {
        guard let requestID = status.requestID,
              let session = try? store.recordingSession(requestID: requestID),
              !session.isKeyboardOwnedVoiceNote
        else {
            isBlockedByAppVoiceNote = false
            return false
        }

        isBlockedByAppVoiceNote = session.hasActiveVoiceNoteWork
        if isBlockedByAppVoiceNote {
            activeRequestID = nil
            recoveryRequestID = nil
            dictationPhase = .idle
            liveTranscript = ""
            inputLevel = 0
            statusText = "Finish the voice note in Muesli"
        }
        return true
    }

    private func apply(liveTranscript transcript: KeyboardLiveTranscript?) {
        guard let activeRequestID else {
            liveTranscript = ""
            return
        }

        guard let transcript,
              transcript.requestID == activeRequestID,
              Date().timeIntervalSince(transcript.updatedAt) < 120
        else {
            return
        }

        liveTranscript = transcript.text
        liveTranscriptIsFinal = transcript.isFinal
        typeLive(transcript)
    }

    /// Hands a streaming partial to live typing. The final text is never a partial: it arrives as a result.
    private func typeLive(_ transcript: KeyboardLiveTranscript) {
        guard !transcript.isFinal,
              !isCancelPending,
              !cancelledRequestIDs.contains(transcript.requestID),
              !insertedRequestIDs.contains(transcript.requestID),
              [.requested, .recording, .transcribing].contains(dictationPhase)
        else { return }
        liveTyper.receive(
            partial: transcript.text,
            requestID: transcript.requestID,
            updatedAt: transcript.updatedAt,
            isRewrite: activeRewrite != nil
        )
    }

    /// How the app's verdict on a dictation changes the words typed live. A cancel removes them, a recovery takes
    /// them out so the later result is inserted as usual, and a failure or a clipboard copy leaves them as text.
    private func settleLiveTyping(for phase: KeyboardHandoffPhase, requestID: UUID) {
        guard liveTyper.sessionRequestID == requestID else { return }
        switch phase {
        case .cancelled:
            liveTyper.cancel(requestID: requestID)
        case .recoveryRequested:
            liveTyper.yield(.yielded)
        case .failed, .copyRequired, .inserted:
            liveTyper.endWithoutResult(requestID: requestID)
        default:
            break
        }
    }

    /// The host reported that the field changed (`textDidChange`, `selectionDidChange`).
    func liveTypingHostDidChange() {
        liveTyper.hostDidChange()
    }

    /// How long since the app last reported audio for a recording, or since the recording began if it has not yet.
    /// While recording the app publishes a level at least every 0.75 s, so a long silence is not a quiet room.
    private func recordingSignalAge(for state: KeyboardHandoffState) -> TimeInterval? {
        guard [.recordingStarted, .stopRequested, .cancelRequested].contains(state.phase) else { return nil }
        let current = readinessModel.now()
        var age = max(0, current.timeIntervalSince(state.updatedAt))
        if let status = latestRuntimeStatus, status.phase == .recording, status.activeRequestID == state.requestID {
            age = min(age, max(0, current.timeIntervalSince(status.updatedAt)))
        }
        return age
    }

    /// The owner of this request is gone. Show idle, end the request once in the store (whichever process gets
    /// there first records it; the others only read), and leave any audio to the app's recovery.
    private func settleAbandoned(_ state: KeyboardHandoffState, reason: AbandonReason) {
        guard let requestID = state.requestID else { return }
        let won = (try? store.abandonRequest(requestID, expectedOwner: state.ownerBootID, reason: reason)) ?? false
        if won { logAbandoned(requestID, reason: reason, phase: state.phase, owner: state.ownerBootID) }
        liveTyper.endWithoutResult(requestID: requestID)
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = nil
        pendingStopID = nil
        pendingCancellationIDs.remove(requestID)
        latestHandoffState = state.advanced(to: .failed, message: reason.message, endReason: reason.rawValue)
        releaseLocalRequest(requestID)
        readinessModel.setRequest(.notInProgress)
    }

    private func logAbandoned(_ requestID: UUID, reason: AbandonReason, phase: KeyboardHandoffPhase, owner: UUID?) {
        var detail = [
            "request": String(requestID.uuidString.prefix(8).lowercased()),
            "reason": reason.rawValue,
            "phase": phase.rawValue,
        ]
        if let owner { detail["boot"] = owner.uuidString }
        if let age = readinessModel.liveness.heartbeatAge { detail["heartbeat_age_ms"] = String(Int(age * 1_000)) }
        KeyboardDiagnosticsLog.record("request.abandoned", detail)
    }

    /// Drops this keyboard's own claim to a request that is over, if it holds it.
    private func releaseLocalRequest(_ requestID: UUID) {
        guard activeRequestID == nil || activeRequestID == requestID else { return }
        activeRequestID = nil
        recoveryRequestID = nil
        liveTranscript = ""
        inputLevel = 0
        dictationPhase = .idle
        statusText = hasLatestDictation ? "Latest ready" : "Ready"
        prepareLaunchRequestIfNeeded()
    }

    private func markForRecoveryIfStale(_ status: DictationStatus, requestID: UUID) -> Bool {
        if let latestRuntimeStatus,
           latestRuntimeStatus.activeRequestID == requestID,
           Date().timeIntervalSince(latestRuntimeStatus.updatedAt) < handoffRecoveryPolicy.runtimeFreshnessInterval,
           [.recording, .transcribing].contains(latestRuntimeStatus.phase)
        {
            recoveryRequestID = nil
            dictationPhase = latestRuntimeStatus.phase
            statusText = latestRuntimeStatus.message ?? status.message ?? latestRuntimeStatus.phase.rawValue.capitalized
            return true
        }

        let age = Date().timeIntervalSince(status.updatedAt)
        let threshold: TimeInterval
        let message: String

        switch status.phase {
        case .requested, .recording:
            threshold = Self.staleRecordingInterval
            message = "Open Muesli to continue"
        case .transcribing:
            threshold = status.message == "Stopping" ? Self.staleStoppingInterval : Self.staleTranscribingInterval
            message = "Open Muesli to finish"
        default:
            return false
        }

        guard age > threshold else { return false }

        recoveryRequestID = requestID
        launchURL = makeLaunchURL(for: requestID, action: MuesliAppConstants.startAction)
        dictationPhase = .failed
        activeRequestID = nil
        liveTranscript = ""
        statusText = message
        return true
    }

    private func markHandoffForRecoveryIfStale(_ state: KeyboardHandoffState) -> Bool {
        guard let requestID = state.requestID else { return false }

        let action = handoffRecoveryPolicy.action(
            for: state,
            latestRuntimeStatus: latestRuntimeStatus,
            canUseRuntimeStart: canUseRuntimeStart
        )

        switch action {
        case .none:
            return false

        case let .retry(retryAction, retrying):
            try? store.saveCommand(.init(requestID: requestID, action: retryAction))
            try? store.saveKeyboardHandoffState(retrying)
            latestHandoffState = retrying
            dictationPhase = retrying.phase.dictationPhase
            statusText = retrying.message ?? "Retrying"
            return true

        case let .recover(recovery):
            try? store.saveKeyboardHandoffState(recovery)
            latestHandoffState = recovery
            recoveryRequestID = requestID
            launchURL = makeLaunchURL(for: requestID, action: urlAction(for: recovery.recoveryAction ?? .start))
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            statusText = recovery.message ?? "Open Muesli to finish"
            return true
        }
    }

    private func reconcileInsertedRequest(_ requestID: UUID) {
        // A delayed completion for A must not reset a newer dictation B.
        guard activeRequestID == nil || activeRequestID == requestID else { return }
        activeRequestID = nil
        recoveryRequestID = nil
        liveTranscript = ""
        inputLevel = 0
        dictationPhase = .idle
        statusText = "Latest ready"
    }

    private func insertCompletedResult(_ result: DictationResult) {
        guard textInserter != nil, !pendingCancellationIDs.contains(result.requestID) else { return }
        // Only an explicit resultReady handoff queues automatic insertion.
        // Capture source does not determine whether the keyboard may deliver it.
        let shortID = result.requestID.uuidString.prefix(8).lowercased()

        guard !insertedRequestIDs.contains(result.requestID) else {
            try? store.acknowledgeKeyboardDelivery(for: result.requestID)
            reconcileInsertedRequest(result.requestID)
            KeyboardDiagnosticsLog.record("insert.skipped", [
                "reason": "alreadyInserted",
                "request": String(shortID),
                "localPhase": dictationPhase.rawValue,
                "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none"
            ])
            return
        }
        guard !cancelledRequestIDs.contains(result.requestID) else {
            KeyboardDiagnosticsLog.record("insert.skipped", [
                "reason": "cancelled",
                "request": String(shortID),
                "localPhase": dictationPhase.rawValue
            ])
            return
        }

        // Character count only -- never the text itself.
        KeyboardDiagnosticsLog.record("insert.performed", [
            "request": String(shortID),
            "characters": String(result.text.count)
        ])
        deliveryNote = nil
        let replacedStaleField = !deliver(result)
        let note = deliveryNote
        deliveryNote = nil
        insertedRequestIDs.insert(result.requestID)
        latestResultID = result.id
        hasLatestDictation = true
        try? store.acknowledgeKeyboardDelivery(for: result.requestID)
        // Acknowledging A must not clear B's command, transcript, or UI.
        guard activeRequestID == result.requestID else {
            if replacedStaleField { statusText = Self.staleRewriteMessage }
            else if let note { statusText = note }
            return
        }
        activeRequestID = nil
        liveTranscript = ""
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = nil
        dictationPhase = .idle
        statusText = replacedStaleField ? Self.staleRewriteMessage : (note ?? "Latest ready")
        try? store.clearPendingRequest(matching: result.requestID)
        try? store.clearPendingCommand(matching: result.requestID)
        prepareLaunchRequestIfNeeded()

    }

    private func awaitCommandAcknowledgement(
        requestID: UUID,
        action: DictationCommandAction,
        requestedPhase: KeyboardHandoffPhase
    ) {
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = Task { @MainActor [weak self, eventBus] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.refreshLatestDictation()
            guard self.isAwaitingAcknowledgement(requestID: requestID, phase: requestedPhase) else { return }
            // The app consumes a command without posting any notification, so
            // the only way to detect a missed intent is to re-post and wait.
            KeyboardDiagnosticsLog.record("ack.retry", [
                "action": action.rawValue,
                "request": String(requestID.uuidString.prefix(8).lowercased()),
                "waited": "750ms"
            ])
            eventBus.post(.commandChanged)

            try? await Task.sleep(for: .milliseconds(1_250))
            guard !Task.isCancelled else { return }
            self.refreshLatestDictation()
            guard self.isAwaitingAcknowledgement(requestID: requestID, phase: requestedPhase) else { return }

            // Two sleeps elapsed with no state change: the app never serviced
            // this intent. Usually it is not running.
            KeyboardDiagnosticsLog.record("ack.timedOut", [
                "action": action.rawValue,
                "request": String(requestID.uuidString.prefix(8).lowercased()),
                "waited": "2000ms",
                "escalation": "recoveryRequested"
            ])

            let urlAction: String
            let message: String
            switch action {
            case .start:
                urlAction = MuesliAppConstants.startAction
                message = "Open Muesli to start"
            case .stop:
                urlAction = MuesliAppConstants.stopAction
                message = "Open Muesli to finish"
            case .cancel:
                urlAction = MuesliAppConstants.cancelAction
                message = "Open Muesli to cancel"
            }
            let recovery = KeyboardHandoffState(
                requestID: requestID,
                phase: .recoveryRequested,
                message: message,
                recoveryAttemptCount: 1,
                recoveryAction: action
            )
            try? self.store.saveKeyboardHandoffState(recovery)
            self.latestHandoffState = recovery
            self.canUseRuntimeStart = false
            if self.pendingStopID == requestID { self.pendingStopID = nil }
            self.recoveryRequestID = requestID
            self.activeRequestID = nil
            self.dictationPhase = .failed
            self.launchURL = self.makeLaunchURL(for: requestID, action: urlAction)
            self.statusText = message
        }
    }

    private func isAwaitingAcknowledgement(
        requestID: UUID,
        phase: KeyboardHandoffPhase
    ) -> Bool {
        guard let state = try? store.keyboardHandoffState() else { return false }
        if phase == .cancelRequested, pendingCancellationIDs.contains(requestID) {
            return state.requestID == requestID && ![.cancelled, .failed, .idle].contains(state.phase)
        }
        return state.requestID == requestID && state.phase == phase
    }

    private func makeLaunchURL(for request: DictationRequest) -> URL? {
        makeLaunchURL(for: request.id, action: MuesliAppConstants.startAction)
    }

    private func urlAction(for action: DictationCommandAction) -> String {
        switch action {
        case .start: MuesliAppConstants.startAction
        case .stop: MuesliAppConstants.stopAction
        case .cancel: MuesliAppConstants.cancelAction
        }
    }

    private func makeLaunchURL(for requestID: UUID, action: String) -> URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: requestID.uuidString),
            URLQueryItem(name: MuesliAppConstants.actionQueryItem, value: action)
        ]

        return components.url
    }

    /// Puts back the text the last rewrite replaced, if the field still ends with the rewrite.
    func undoLastRewrite() {
        guard let undo = lastRewrite else { return }
        lastRewrite = nil
        let current = textContextProvider?() ?? KeyboardTextContext()
        let rewritten = RewriteContext(target: .textBeforeCursor, original: undo.rewritten)
        guard case .replaceBeforeCursor(let deleteCount, let text) =
                RewritePlanner.plan(context: rewritten, current: current, rewritten: undo.original) else {
            statusText = "Text changed. Can't undo"
            return
        }
        deleteFromHost(deleteCount)
        insertDictatedText(text)
        statusText = "Undone"
    }

    static let staleRewriteMessage = "Text changed. Nothing replaced"

    /// Types the result into the field. A rewrite replaces the text it was made from, and only if the
    /// field still holds that text. Returns false when a rewrite was refused.
    private func deliver(_ result: DictationResult) -> Bool {
        guard let rewrite = result.rewrite else {
            lastRewrite = nil
            deliverDictation(result)
            return true
        }
        let current = textContextProvider?() ?? KeyboardTextContext()
        switch RewritePlanner.plan(context: rewrite, current: current, rewritten: result.text) {
        case .replaceSelection(let text):
            insertDictatedText(text)
            lastRewrite = RewriteUndo(original: rewrite.original, rewritten: text)
            return true
        case .replaceBeforeCursor(let deleteCount, let text):
            deleteFromHost(deleteCount)
            insertDictatedText(text)
            lastRewrite = RewriteUndo(original: rewrite.original, rewritten: text)
            return true
        case .stale:
            KeyboardDiagnosticsLog.record("rewrite.skipped", ["reason": "fieldChanged"])
            return false
        }
    }

    static let keptWordsMessage = "Kept what was typed. Full text is in Muesli"

    /// A dictation's text: it replaces the words typed live in place, or goes in at the cursor as it always did.
    private func deliverDictation(_ result: DictationResult) {
        switch liveTyper.final(result.text, requestID: result.requestID) {
        case .replacedInPlace:
            lastInsertedCharacterCount = result.text.count
            typing.engine.noteExternalInsertion()
        case .insertPlain(let text):
            insertDictatedText(text)
        case .withheld(let reason):
            deliveryNote = Self.keptWordsMessage
            KeyboardDiagnosticsLog.record("live_typing.final_withheld", ["reason": reason])
        }
    }

    /// Text Muesli writes itself (a transcript, a rewrite, an Undo edit): never autocorrected, and a pending
    /// autocorrect undo is retired.
    func insertDictatedText(_ text: String) {
        insertText(text)
        typing.engine.noteExternalInsertion()
    }

    /// Reads the typing settings the app published. Unreadable (Full Access off), never published or corrupted
    /// means the defaults: autocorrect and live typing on, the full layout.
    ///
    /// Autocorrect and live typing follow at once. The layout is applied only when the keyboard appears
    /// (`appliesLayout`), before its first frame, so a change in Settings never re-lays out a keyboard under
    /// the user's thumbs; it shows the next time the keyboard opens.
    func loadTypingSettings(appliesLayout: Bool = false) {
        let settings = ((try? store.keyboardTypingSettings()) ?? nil) ?? .default
        typing.autocorrectEnabled = settings.autocorrect
        liveTyper.isEnabled = settings.liveTyping
        showsDictatePanelWhileRecording = settings.showsDictatePanelWhileRecording
        if appliesLayout { layout = settings.layout }
    }

    private func insertText(_ text: String) {
        liveTyper.yield(.yielded)
        textInserter?(text)
        lastInsertedCharacterCount = text.count
    }

    /// Every deletion the keyboard makes goes through here, so words typed live never sit under an edit.
    private func deleteFromHost(_ count: Int) {
        liveTyper.yield(.yielded)
        textDeleter?(count)
    }
}

enum KeyboardPrimaryButtonRole {
    case blocked
    case openMuesliRecovery
    /// Dictation is not ready (the model is loading or missing, or the app was updated): the key opens Muesli to
    /// get ready instead of starting a request that would hang.
    case prepareMuesli
    case waitingForMuesli
    case openMuesliRequested
    case stop
    case transcribing
    case inserted
    case record
}

/// What a voice rewrite replaced: enough to put the original back.
struct RewriteUndo: Equatable {
    let original: String
    let rewritten: String
}
