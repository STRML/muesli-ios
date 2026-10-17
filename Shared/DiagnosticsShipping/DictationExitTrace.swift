import Foundation

/// A value that goes to `KeyboardDiagnosticsLog.record`.
struct DiagnosticsRecord: Equatable, Sendable {
    var name: String
    var fields: [String: String]
}

/// Guarantees a request leaves one last event saying where it died.
///
/// The stop-to-save task has many exits: success, a thrown error, a cancel, a lifecycle that moved on, and several
/// early returns. Each calls ``finish(_:detail:)`` with what it knows, and a `defer` calls ``closeIfOpen()`` so an
/// exit nobody classified still reports as `abandoned` with the last stage reached. Only the first call emits.
final class DictationExitTrace {
    let requestID: UUID
    private(set) var lastStage: DictationStage = .requested
    private(set) var isClosed = false
    private let sink: (DiagnosticsRecord) -> Void

    init(requestID: UUID, sink: @escaping (DiagnosticsRecord) -> Void) {
        self.requestID = requestID
        self.sink = sink
    }

    /// Notes progress. A stage never moves backwards, and a stage reached after the exit is ignored.
    func reach(_ stage: DictationStage) {
        guard !isClosed, Self.order(stage) > Self.order(lastStage) else { return }
        lastStage = stage
    }

    /// Emits the one `dictation.exit` event. Later calls do nothing.
    func finish(_ outcome: DictationExitOutcome, detail: [String: String] = [:]) {
        guard !isClosed else { return }
        isClosed = true
        var fields = detail
        fields["request"] = requestID.uuidString
        fields["outcome"] = outcome.rawValue
        fields["last_stage"] = lastStage.rawValue
        sink(DiagnosticsRecord(name: "dictation.exit", fields: fields))
    }

    /// For a `defer`: any exit that did not classify itself reports as `abandoned` at the last stage reached.
    func closeIfOpen() {
        finish(.abandoned)
    }

    private static func order(_ stage: DictationStage) -> Int {
        DictationStage.allCases.firstIndex(of: stage) ?? 0
    }
}

/// Builders for the stop-to-save events, so the field names live in one place and a test can run every one of
/// them through the sanitizer.
enum DiagnosticsEvents {
    static func stopReceived(request: UUID, source: String) -> DiagnosticsRecord {
        record("stop.received", request, ["source": source])
    }

    static func stopIgnored(request: UUID, reason: StopIgnoredReason) -> DiagnosticsRecord {
        record("stop.ignored", request, ["ignored_reason": reason.rawValue])
    }

    static func recordingStopped(request: UUID, durationMs: Int, samples: Int, bytes: Int, fileWritten: Bool) -> DiagnosticsRecord {
        record("recording.stopped", request, [
            "duration_ms": String(durationMs), "samples": String(samples), "bytes": String(bytes),
            "file_written": String(fileWritten),
        ])
    }

    static func transcriptionStarted(request: UUID, model: String, audioMs: Int?) -> DiagnosticsRecord {
        record("transcription.started", request, ["model": model, "audio_ms": audioMs.map(String.init)])
    }

    static func transcriptionFinished(request: UUID, model: String, durationMs: Int, source: TextSource, characters: Int) -> DiagnosticsRecord {
        record("transcription.finished", request, [
            "model": model, "duration_ms": String(durationMs), "text_source": source.rawValue,
            "characters": String(characters),
        ])
    }

    static func transcriptionFailed(
        request: UUID,
        model: String,
        durationMs: Int,
        failure: FailureCode,
        domain: String?,
        code: Int?
    ) -> DiagnosticsRecord {
        record("transcription.failed", request, [
            "model": model, "duration_ms": String(durationMs), "failure": failure.rawValue,
            "domain": domain, "code": code.map(String.init),
        ])
    }

    static func resultPersisted(request: UUID, historyID: UUID?, characters: Int) -> DiagnosticsRecord {
        record("result.persisted", request, ["history_id": historyID?.uuidString, "characters": String(characters)])
    }

    static func deliveryOutcome(
        request: UUID,
        route: KeyboardDeliveryRoute,
        reason: KeyboardDeliveryReason,
        heartbeatAge: TimeInterval?
    ) -> DiagnosticsRecord {
        record("delivery.outcome", request, [
            "route": route.rawValue, "route_reason": reason.rawValue,
            "heartbeat_age_ms": heartbeatAge.map(milliseconds),
        ])
    }

    static func cancelled(request: UUID, by source: DictationCancelSource, stage: DictationStage) -> DiagnosticsRecord {
        record("dictation.cancelled", request, ["cancel_by": source.rawValue, "cancel_stage": stage.rawValue])
    }

    static func handoffSaved(request: UUID, phase: String) -> DiagnosticsRecord {
        record("handoff.saved", request, ["phase": phase])
    }

    /// `remaining` is `UIApplication.backgroundTimeRemaining`, which is `greatestFiniteMagnitude` in the foreground.
    /// `bg_remaining_ms` is left out when the OS reports no limit.
    static func backgroundTask(request: UUID?, state: BackgroundTaskState, remaining: TimeInterval?) -> DiagnosticsRecord {
        var extra: [String: String?] = ["bg_state": state.rawValue]
        if let remaining, remaining < 1_000_000 { extra["bg_remaining_ms"] = milliseconds(remaining) }
        return record("backgroundTask", request, extra)
    }

    static func memoryWarning() -> DiagnosticsRecord {
        DiagnosticsRecord(name: "app.memoryWarning", fields: [:])
    }

    static func thermalState(_ level: ThermalLevel) -> DiagnosticsRecord {
        DiagnosticsRecord(name: "app.thermalState", fields: ["thermal": level.rawValue])
    }

    /// Durations go out as whole milliseconds: the receiver drops an event that carries a float.
    private static func milliseconds(_ value: TimeInterval) -> String {
        String(Int((value * 1_000).rounded()))
    }

    private static func record(_ name: String, _ request: UUID?, _ extra: [String: String?]) -> DiagnosticsRecord {
        var fields = extra.compactMapValues { $0 }
        if let request { fields["request"] = request.uuidString }
        return DiagnosticsRecord(name: name, fields: fields)
    }
}
