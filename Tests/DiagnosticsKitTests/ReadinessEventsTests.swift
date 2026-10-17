import XCTest
@testable import DiagnosticsKit

/// The readiness events the keyboard and the app record must pass the allowlist whole, or the evidence for a stuck
/// "listening" never leaves the phone. These are the field sets the call sites build.
final class ReadinessEventsTests: XCTestCase {
    private func survives(_ event: String, _ detail: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        let text = DiagnosticsLogFormat.line(date: Fixture.t0, process: "MuesliKeyboard", event: event, detail: detail) + "\n"
        guard let parsed = DiagnosticsLogParser.parse(text).lines.first else { return XCTFail("unparseable", file: file, line: line) }
        let result = DiagnosticsSanitizer.sanitize(parsed)
        XCTAssertNotNil(result.event, "\(event) was dropped", file: file, line: line)
        XCTAssertEqual(result.droppedFields, 0, "\(event) lost fields: \(detail)", file: file, line: line)
        XCTAssertEqual(result.event?.fields, detail, file: file, line: line)
    }

    func testEveryReadinessCodeSurvives() {
        let codes = [
            "checking", "ready", "starting", "recording", "transcribing", "loading.preparing", "loading.downloading",
            "needsApp.fullAccessOff", "needsApp.neverOpened", "needsApp.appUpdated", "needsApp.appNotRunning",
            "needsApp.loadInterrupted", "needsApp.modelMissing", "needsApp.modelNotLoaded", "needsApp.recovery",
            "failed.downloadFailed", "failed.loadFailed", "failed.loadInterrupted", "failed.unknown",
        ]
        for code in codes {
            survives("keyboard.readiness", [
                "readiness": code, "action": "openAppToPrepare", "model_state": "deferredByBackoff",
                "boot": "11111111-1111-1111-1111-111111111111", "heartbeat_age_ms": "15100",
            ])
        }
    }

    func testAbandonedRequestsSurvive() {
        for reason in ["app_restarted", "owner_lost"] {
            survives("request.abandoned", [
                "request": "a53153f7", "reason": reason, "phase": "recordingStarted",
                "boot": "22222222-2222-2222-2222-222222222222", "heartbeat_age_ms": "40000", "trigger": "launch",
            ])
        }
    }

    func testThePrepareTripSurvives() {
        survives("intent.prepare", ["readiness": "needsApp.appUpdated", "action": "openAppToPrepare"])
        survives("prepare.started", ["model_state": "notLoaded"])
        for outcome in ["ready", "failed", "needsDownload", "working"] {
            survives("prepare.finished", ["trip_outcome": outcome, "elapsed_ms": "935000"])
        }
        survives("model.loadInterrupted", ["model": "whisper-small-en"])
    }
}
