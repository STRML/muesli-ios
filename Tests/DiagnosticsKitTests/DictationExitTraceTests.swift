import XCTest
@testable import DiagnosticsKit

/// "A lost dictation always has a last event that says where it died."
final class DictationExitTraceTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        var records: [DiagnosticsRecord] = []
    }

    private func makeTrace() -> (DictationExitTrace, Sink) {
        let sink = Sink()
        return (DictationExitTrace(requestID: Fixture.request) { sink.records.append($0) }, sink)
    }

    func testSuccessEmitsOneSavedExitAtTheLastStage() {
        let (trace, sink) = makeTrace()
        trace.reach(.transcribing)
        trace.reach(.persisting)
        trace.finish(.saved)
        trace.closeIfOpen()
        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].name, "dictation.exit")
        XCTAssertEqual(sink.records[0].fields["outcome"], "saved")
        XCTAssertEqual(sink.records[0].fields["last_stage"], "persisting")
        XCTAssertEqual(sink.records[0].fields["request"], Fixture.request.uuidString)
    }

    func testFailureCarriesItsDetail() {
        let (trace, sink) = makeTrace()
        trace.reach(.transcribing)
        trace.finish(.failed, detail: ["failure": "timeout"])
        XCTAssertEqual(sink.records.first?.fields["outcome"], "failed")
        XCTAssertEqual(sink.records.first?.fields["failure"], "timeout")
    }

    func testCancelCarriesWhoCancelled() {
        let (trace, sink) = makeTrace()
        trace.reach(.transcribing)
        trace.finish(.cancelled, detail: ["cancel_by": "keyboardCommand"])
        XCTAssertEqual(sink.records.first?.fields["outcome"], "cancelled")
        XCTAssertEqual(sink.records.first?.fields["cancel_by"], "keyboardCommand")
    }

    func testASupersededRequestIsNotReportedAsFailure() {
        let (trace, sink) = makeTrace()
        trace.reach(.transcribing)
        trace.finish(.superseded)
        XCTAssertEqual(sink.records.first?.fields["outcome"], "superseded")
    }

    /// The real failure: `intent.stop` -> `transcribingStarted` -> the task returned through a guard that logged nothing.
    func testAnExitNobodyClassifiedStillLeavesALastEventNamingTheStage() {
        let (trace, sink) = makeTrace()
        trace.reach(.stopping)
        trace.reach(.transcribing)
        trace.closeIfOpen()
        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].fields["outcome"], "abandoned")
        XCTAssertEqual(sink.records[0].fields["last_stage"], "transcribing")
    }

    func testOnlyTheFirstExitIsRecorded() {
        let (trace, sink) = makeTrace()
        trace.finish(.failed)
        trace.finish(.saved)
        trace.closeIfOpen()
        XCTAssertEqual(sink.records.count, 1)
        XCTAssertEqual(sink.records[0].fields["outcome"], "failed")
        XCTAssertTrue(trace.isClosed)
    }

    func testStagesNeverMoveBackwards() {
        let (trace, sink) = makeTrace()
        trace.reach(.delivering)
        trace.reach(.recording)
        trace.finish(.failed)
        XCTAssertEqual(sink.records.first?.fields["last_stage"], "delivering")
    }

    func testAStageReachedAfterTheExitIsIgnored() {
        let (trace, _) = makeTrace()
        trace.finish(.cancelled)
        trace.reach(.completed)
        XCTAssertEqual(trace.lastStage, .requested)
    }

    func testTheExitEventSurvivesTheSanitizer() {
        let (trace, sink) = makeTrace()
        trace.reach(.delivering)
        trace.finish(.failed, detail: ["failure": "engineFailure", "domain": "NSURLErrorDomain", "code": "-1009"])
        let record = sink.records[0]
        let text = DiagnosticsLogFormat.line(date: Fixture.t0, process: "Muesli", event: record.name, detail: record.fields) + "\n"
        let result = DiagnosticsSanitizer.sanitize(DiagnosticsLogParser.parse(text).lines[0])
        XCTAssertEqual(result.droppedFields, 0)
        XCTAssertEqual(result.event?.fields, record.fields)
    }
}
