import XCTest
@testable import DiagnosticsKit

final class DiagnosticsEnvelopeTests: XCTestCase {
    private func sample() -> DiagnosticsEnvelope {
        DiagnosticsEnvelope(
            batchID: "B1", seq: 7, sentAt: DiagnosticsLogFormat.timestamp(Fixture.t0),
            deviceID: Fixture.device.deviceID, appVersion: "0.1.7", appBuild: "9", iosVersion: "26.0",
            deviceModel: "iPhone18,1", thermalState: "nominal", trigger: .timer, droppedEvents: 2, droppedFields: 3, rejectedEvents: 4,
            events: [DiagnosticsEvent(id: "abc", time: "t", process: "Muesli", name: "intent.stop", fields: ["request": "04fcc3fc"])]
        )
    }

    func testTheWireFormatUsesSnakeCaseKeysTheStudioReceiverExpects() throws {
        let object = try JSONSerialization.jsonObject(with: sample().encoded()) as? [String: Any]
        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            ["schema", "batch_id", "seq", "sent_at", "device_id", "app_version", "app_build", "ios_version",
             "device_model", "thermal_state", "trigger", "dropped_events", "dropped_fields", "rejected_events", "events"]
        )
        let events = object?["events"] as? [[String: Any]]
        XCTAssertEqual(Set(events?.first?.keys.map { $0 } ?? []), ["id", "time", "process", "event", "fields"])
        XCTAssertEqual(object?["schema"] as? Int, 1)
        XCTAssertEqual(object?["trigger"] as? String, "timer")
    }

    func testEncodingIsDeterministic() {
        XCTAssertEqual(sample().encoded(), sample().encoded())
    }

    func testItRoundTrips() throws {
        let decoded = try JSONDecoder().decode(DiagnosticsEnvelope.self, from: sample().encoded())
        XCTAssertEqual(decoded, sample())
    }
}
