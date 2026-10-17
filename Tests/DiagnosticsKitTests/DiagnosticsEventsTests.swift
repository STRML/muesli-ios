import XCTest
@testable import DiagnosticsKit

/// Every stop-to-save event builder must produce a record that survives the sanitizer whole. A typo in a field name
/// or a value outside its closed set would silently drop the evidence, so each builder is run through the same path
/// the uploader uses.
final class DiagnosticsEventsTests: XCTestCase {
    private let request = Fixture.request

    private func survives(_ record: DiagnosticsRecord, file: StaticString = #filePath, line: UInt = #line) -> DiagnosticsEvent? {
        let text = DiagnosticsLogFormat.line(date: Fixture.t0, process: "Muesli", event: record.name, detail: record.fields) + "\n"
        guard let parsed = DiagnosticsLogParser.parse(text).lines.first else {
            XCTFail("unparseable", file: file, line: line)
            return nil
        }
        let result = DiagnosticsSanitizer.sanitize(parsed)
        XCTAssertNotNil(result.event, "\(record.name) was dropped", file: file, line: line)
        XCTAssertEqual(result.droppedFields, 0, "\(record.name) lost fields: \(record.fields)", file: file, line: line)
        XCTAssertEqual(result.event?.fields, record.fields, file: file, line: line)
        return result.event
    }

    func testEveryBuilderSurvivesTheSanitizerWithAllItsFields() {
        let records: [DiagnosticsRecord] = [
            DiagnosticsEvents.stopReceived(request: request, source: "keyboard"),
            DiagnosticsEvents.stopIgnored(request: request, reason: .notRecording),
            DiagnosticsEvents.recordingStopped(request: request, durationMs: 4200, samples: 201_600, bytes: 403_200, fileWritten: true),
            DiagnosticsEvents.transcriptionStarted(request: request, model: "parakeet-tdt-v3", audioMs: 4200),
            DiagnosticsEvents.transcriptionStarted(request: request, model: "remote-custom-llm", audioMs: nil),
            DiagnosticsEvents.transcriptionFinished(request: request, model: "parakeet-tdt-v3", durationMs: 810, source: .onDevice, characters: 120),
            DiagnosticsEvents.transcriptionFailed(request: request, model: "parakeet-tdt-v3", durationMs: 18_000, failure: .timeout, domain: nil, code: nil),
            DiagnosticsEvents.transcriptionFailed(request: request, model: "m", durationMs: 1, failure: .engineFailure, domain: "NSURLErrorDomain", code: -1009),
            DiagnosticsEvents.resultPersisted(request: request, historyID: UUID(), characters: 120),
            DiagnosticsEvents.resultPersisted(request: request, historyID: nil, characters: 0),
            DiagnosticsEvents.deliveryOutcome(request: request, route: .copyRequired, reason: .heartbeatStale, heartbeatAge: 4.2),
            DiagnosticsEvents.deliveryOutcome(request: request, route: .insertDirect, reason: .ok, heartbeatAge: nil),
            DiagnosticsEvents.cancelled(request: request, by: .keyboardCommand, stage: .transcribing),
            DiagnosticsEvents.handoffSaved(request: request, phase: "copyRequired"),
            DiagnosticsEvents.backgroundTask(request: request, state: .expired, remaining: 0.4),
            DiagnosticsEvents.backgroundTask(request: nil, state: .begin, remaining: .infinity),
            DiagnosticsEvents.memoryWarning(),
            DiagnosticsEvents.thermalState(.serious),
        ]
        for record in records { _ = survives(record) }
    }

    func testEveryClosedValueOfEveryVocabularyEnumPassesItsKeyRule() {
        func check<E: CaseIterable & RawRepresentable>(_ type: E.Type, key: String) where E.RawValue == String {
            for value in type.allCases {
                XCTAssertTrue(DiagnosticsVocabulary.keyRules[key]?.accepts(value.rawValue) == true, "\(key)=\(value.rawValue)")
            }
        }
        check(DictationExitOutcome.self, key: "outcome")
        check(DictationStage.self, key: "last_stage")
        check(DictationStage.self, key: "cancel_stage")
        check(DictationCancelSource.self, key: "cancel_by")
        check(StopIgnoredReason.self, key: "ignored_reason")
        check(TextSource.self, key: "text_source")
        check(FailureCode.self, key: "failure")
        check(KeyboardDeliveryRoute.self, key: "route")
        check(KeyboardDeliveryReason.self, key: "route_reason")
        check(BackgroundTaskState.self, key: "bg_state")
        check(ThermalLevel.self, key: "thermal")
    }

    func testEveryNewEventCarriesTheRequestIDWhenItHasOne() {
        let withRequest: [DiagnosticsRecord] = [
            DiagnosticsEvents.stopReceived(request: request, source: "keyboard"),
            DiagnosticsEvents.stopIgnored(request: request, reason: .noActiveRequest),
            DiagnosticsEvents.recordingStopped(request: request, durationMs: 1, samples: 1, bytes: 1, fileWritten: false),
            DiagnosticsEvents.transcriptionStarted(request: request, model: "m", audioMs: 1),
            DiagnosticsEvents.transcriptionFinished(request: request, model: "m", durationMs: 1, source: .remote, characters: 1),
            DiagnosticsEvents.transcriptionFailed(request: request, model: "m", durationMs: 1, failure: .unknown, domain: nil, code: nil),
            DiagnosticsEvents.resultPersisted(request: request, historyID: nil, characters: 1),
            DiagnosticsEvents.deliveryOutcome(request: request, route: .copied, reason: .notVisible, heartbeatAge: nil),
            DiagnosticsEvents.cancelled(request: request, by: .appUser, stage: .recording),
            DiagnosticsEvents.handoffSaved(request: request, phase: "failed"),
            DiagnosticsEvents.backgroundTask(request: request, state: .begin, remaining: nil),
        ]
        for record in withRequest {
            XCTAssertEqual(record.fields["request"], request.uuidString, record.name)
        }
    }

    func testNoBuilderAcceptsFreeTextFromItsCaller() {
        // The only String parameters are source/model/phase. A caller that passes a sentence gets the field dropped,
        // not sent: the sanitizer, not the builder, is the guard.
        let record = DiagnosticsEvents.stopReceived(request: request, source: "Please remind me to call Dr. Okafor")
        let text = DiagnosticsLogFormat.line(date: Fixture.t0, process: "Muesli", event: record.name, detail: record.fields) + "\n"
        let result = DiagnosticsSanitizer.sanitize(DiagnosticsLogParser.parse(text).lines[0])
        XCTAssertNil(result.event?.fields["source"])
        XCTAssertEqual(result.droppedFields, 1)
    }
}
