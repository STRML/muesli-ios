import XCTest
@testable import DiagnosticsKit

final class DiagnosticsEnvelopeTests: XCTestCase {
    private func sample() -> DiagnosticsEnvelope {
        DiagnosticsEnvelope(
            batchID: "B1", seq: 7, sentAt: DiagnosticsLogFormat.timestamp(Fixture.t0),
            deviceID: Fixture.device.deviceID, appVersion: "0.1.7", appBuild: "9", os: "iOS 26.0",
            model: "iPhone18,1", thermal: "nominal", trigger: .timer, droppedEvents: 2, droppedFields: 3, rejectedEvents: 4,
            events: [DiagnosticsEvent(id: "abc", time: "t", process: "Muesli", name: "intent.stop", fields: ["request": "04fcc3fc"])]
        )
    }

    func testTheWireFormatUsesSnakeCaseKeysTheStudioReceiverExpects() throws {
        let object = try JSONSerialization.jsonObject(with: sample().encoded()) as? [String: Any]
        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            ["schema", "batch_id", "seq", "sent_at", "device_id", "app", "os", "model", "thermal", "trigger", "dropped",
             "dropped_events", "dropped_fields", "rejected_events", "events"]
        )
        let events = object?["events"] as? [[String: Any]]
        XCTAssertEqual(Set(events?.first?.keys.map { $0 } ?? []), ["id", "t", "proc", "name", "attrs"])
        XCTAssertEqual((object?["app"] as? [String: Any])?.keys.sorted(), ["build", "version"])
        XCTAssertEqual(object?["dropped"] as? Int, 6, "the receiver's one counter is dropped events plus refused ones")
        XCTAssertEqual(object?["schema"] as? Int, 1)
        XCTAssertEqual(object?["trigger"] as? String, "timer")
    }

    func testIntegersAndFlagsGoOutAsJSONNumbersAndBoolsNeverFloats() throws {
        let event = DiagnosticsEvent(id: "a", time: "t", process: "Muesli", name: "recording.stopped", fields: [
            "request": "04fcc3fc", "duration_ms": "4200", "file_written": "yes", "other_audio": "false",
            "phase": "123", "elapsed_ms": "-5",
        ])
        var envelope = sample()
        envelope.events = [event]
        let object = try JSONSerialization.jsonObject(with: envelope.encoded()) as? [String: Any]
        let attrs = try XCTUnwrap(((object?["events"] as? [[String: Any]])?.first)?["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["duration_ms"] as? Int, 4200)
        XCTAssertEqual(attrs["elapsed_ms"] as? Int, -5)
        XCTAssertEqual(attrs["file_written"] as? Bool, true)
        XCTAssertEqual(attrs["other_audio"] as? Bool, false)
        XCTAssertEqual(attrs["request"] as? String, "04fcc3fc")
        XCTAssertEqual(attrs["phase"] as? String, "123", "a string key stays a string even when it looks like a number")
    }

    func testEncodingIsDeterministic() {
        XCTAssertEqual(sample().encoded(), sample().encoded())
    }

    func testItRoundTrips() throws {
        let decoded = try JSONDecoder().decode(DiagnosticsEnvelope.self, from: sample().encoded())
        XCTAssertEqual(decoded, sample())
    }
}
