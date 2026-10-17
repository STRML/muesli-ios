import Foundation

/// The closed vocabulary of the diagnostics log: which events may leave the phone, which keys they may carry, and
/// what a value for each key has to look like. Anything else is dropped and counted, never sent.
///
/// This is the privacy boundary of diagnostics shipping. The log is written by code that is careful never to
/// record content, and this table is the second lock: a free-text value that slipped into a log call (a localized
/// error message, a `String(describing:)` of something that holds text) fails the key's rule and is dropped here.
/// A new event or key has to be added to this file on purpose, and a test fails until it is.
enum DiagnosticsVocabulary {
    /// Every event name any process records. `DiagnosticsVocabularyScanTests` reads the source tree and fails when
    /// a `record("...")` literal is missing from here.
    static let events: Set<String> = [
        // Keyboard extension
        "ack.retry", "ack.timedOut", "handoff.observed", "insert.performed", "insert.skipped",
        "intent.start", "intent.stop", "intent.captureEntered", "intent.captureExited",
        "keyboard.appeared", "keyboard.disappeared", "keyboard.autoOff", "keyboard.persistencePreferenceChanged",
        "level.freshness", "model.select", "rewrite.skipped",
        "live_typing.unsupported", "live_typing.detached", "live_typing.yielded", "live_typing.final_withheld",
        // App: audio session and recorder
        "audioSession.activated", "audioSession.activateRequested", "audioSession.configureRequested",
        "audioSession.deactivated", "audioSession.deactivateRequested", "audioSession.deactivationFailed",
        "audioSession.failed", "audioSession.inputConfigured", "audioSession.interruption",
        "audioSession.interruptionHandling", "audioSession.mediaServicesReset", "audioSession.routeChanged",
        "audioSession.routeHandling",
        "keyboardMic.activityFailed", "keyboardMic.ioConfiguration", "keyboardMic.retryWithOutput",
        "keyboardMic.started", "keyboardMic.startFailed", "keyboardMic.startStep",
        "recorder.engineStarted", "recorder.ioConfiguration", "recorder.prepareCompleted",
        "recorder.prepareRequested", "recorder_start_failed",
        // App: recording and dictation
        "recording.audioEstablished", "recording.engineAttempt", "recording.inputReady",
        "recording.interruptedStop", "recording.recovery", "recording.recoveryRejected", "recording.started",
        "recording.startFailed", "recording.startRequested", "recording.startRetry",
        "dictation.delivery", "dictation.finalText", "preview.persistFailed",
        "startup.exited", "startup.permissionRequested", "startup.permissionResolved",
        // App: models, live activity, lifecycle
        "liveActivity.failed", "liveActivity.skipped", "liveActivity.started", "livePreview.memoryWarning",
        "model.prewarm.backingOff", "whisper.loaded",
        "scene.active", "scene.inactive", "scene.background",
        // Stop-to-save path (this PR)
        "handoff.saved", "stop.received", "stop.ignored", "recording.stopped", "transcription.started",
        "transcription.finished", "transcription.failed", "result.persisted", "delivery.outcome",
        "dictation.cancelled", "dictation.exit", "backgroundTask", "app.memoryWarning", "app.thermalState",
    ]

    static let keyRules: [String: DiagnosticsValueRule] = {
        var rules: [String: DiagnosticsValueRule] = [:]
        func add(_ rule: DiagnosticsValueRule, _ keys: String...) { for key in keys { rules[key] = rule } }

        add(.uuid, "capture_request", "intent_invocation", "history_id")
        add(.requestID, "request")
        add(.optionalID, "active", "active_request", "session", "mic_generation")
        add(.int, "type", "attempt", "elapsed_ms", "duration_ms", "samples", "bytes", "characters", "code",
            "options", "options_before", "channels", "app_state", "audio_ms", "heartbeat_age_ms", "bg_remaining_ms")
        add(.codeOrInt, "reason")
        add(.flag, "should_resume", "enabled", "startup", "recording", "protected_data", "persistent", "loaded",
            "input_enabled", "output_enabled", "input_available", "other_audio", "file_written", "empty", "fresh",
            "inserted", "matchesActive", "canUseRuntimeStart")
        add(.decimal, "sample_rate", "input_sample_rate")
        add(.duration, "total_s", "wall_s", "encoder_load_s", "encoder_specialization_s", "decoder_load_s",
            "decoder_specialization_s", "age", "appSeenAt")
        add(.identifier, "model", "variant", "source", "trigger", "kind", "error", "stage", "step", "caller",
            "file", "category", "category_before", "mode", "mode_before", "preference", "phase", "localPhase",
            "appPhase")
        add(.identifierList, "input_ports", "output_ports")
        add(.errorDomain, "domain")
        add(.oneOf(values(DictationExitOutcome.self, extra: ["missingAudio", "noRecoverableRecording"])), "outcome")
        add(.oneOf(values(DictationStage.self)), "last_stage", "cancel_stage")
        add(.oneOf(values(DictationCancelSource.self)), "cancel_by")
        add(.oneOf(values(StopIgnoredReason.self)), "ignored_reason")
        add(.oneOf(values(TextSource.self)), "text_source")
        add(.oneOf(values(FailureCode.self)), "failure")
        add(.oneOf(values(KeyboardDeliveryRoute.self)), "route")
        add(.oneOf(values(KeyboardDeliveryReason.self)), "route_reason")
        add(.oneOf(values(BackgroundTaskState.self)), "bg_state")
        add(.oneOf(values(ThermalLevel.self)), "thermal")
        add(.oneOf(["clipboard", "foregroundCopyRequired"]), "destination")
        return rules
    }()

    private static func values<E: CaseIterable & RawRepresentable>(
        _ type: E.Type,
        extra: [String] = []
    ) -> Set<String> where E.RawValue == String {
        Set(type.allCases.map(\.rawValue) + extra)
    }
}

// MARK: - Closed value sets for the stop-to-save events

/// How a dictation request ended, as far as the app can tell. Exactly one `dictation.exit` event carries it.
enum DictationExitOutcome: String, CaseIterable, Sendable {
    /// Transcribed, saved to history and handed to the keyboard.
    case saved
    /// An error ended it. The `failure` and `domain`/`code` fields say which.
    case failed
    /// Someone or something cancelled it. `cancel_by` says who.
    case cancelled
    /// A newer request or lifecycle took over, so this one stopped without writing a result.
    case superseded
    /// The work ended and nothing classified how. Seeing this is a bug in the instrumentation: it means a code
    /// path left the stop-to-save task without saying why, and `last_stage` is where it was.
    case abandoned
}

/// The last step a request reached, in the order the stop-to-save path takes them.
enum DictationStage: String, CaseIterable, Sendable {
    case requested, startup, recording, stopping, finalizingAudio, transcribing, persisting, delivering, completed
}

enum DictationCancelSource: String, CaseIterable, Sendable {
    /// The keyboard's X button, sent as a cancel command.
    case keyboardCommand
    /// Cancel from the app's own UI or its Live Activity.
    case appUser
    /// Swift task cancellation reached the transcription task without a recorded cause.
    case taskCancelled
    case unknown
}

enum StopIgnoredReason: String, CaseIterable, Sendable {
    case conflictingCommand
    case notRecording
    case lifecycleRejected
    case noActiveRequest
    case recoveredFromStorage
}

enum TextSource: String, CaseIterable, Sendable {
    case onDevice, remote, streaming
}

/// Mirrors `VoiceNoteTranscriptionFailureReason`; kept as its own list because this target cannot see app types.
enum FailureCode: String, CaseIterable, Sendable {
    case timeout, interrupted, engineFailure, audioUnavailable, checkpointFailure, unknown
}

enum BackgroundTaskState: String, CaseIterable, Sendable {
    case begin, denied, end, expired
}

enum ThermalLevel: String, CaseIterable, Sendable {
    case nominal, fair, serious, critical
}
