import XCTest
@testable import RemoteTranscriptionKit

/// Matrix rows 3 and 13 as far as the Settings status row goes.
final class ProbeOutcomeTests: XCTestCase {
    func testRow03MissingRouteStatusesReadAsNoTranscriptionRoute() {
        for status in [404, 405, 401, 403] {
            let outcome = RemoteProbeOutcome.classify(statusCode: status, latency: 0.1)
            XCTAssertEqual(outcome, .noRoute, "HTTP \(status)")
            XCTAssertEqual(outcome.statusRowText, "No transcription route")
            XCTAssertFalse(outcome.isFast(threshold: 0.4))
        }
    }

    func testAnsweringStatusesCountAsReachableAndShowTheRoundTrip() {
        for status in [200, 400, 415, 422] {
            XCTAssertEqual(
                RemoteProbeOutcome.classify(statusCode: status, latency: 0.18),
                .reachable(latency: 0.18),
                "HTTP \(status)"
            )
        }
        XCTAssertEqual(RemoteProbeOutcome.reachable(latency: 0.18).statusRowText, "Reachable, 180 ms")
        XCTAssertEqual(RemoteProbeOutcome.reachable(latency: 0.1804).statusRowText, "Reachable, 180 ms")
    }

    func testRow13ServerFailuresAndTimeoutsReadAsUnreachable() {
        for status in [500, 502, 503, 429] {
            XCTAssertEqual(RemoteProbeOutcome.classify(statusCode: status, latency: 0.1), .unreachable, "HTTP \(status)")
        }
        XCTAssertEqual(RemoteProbeOutcome.unreachable.statusRowText, "Unreachable")
        XCTAssertEqual(RemoteProbeOutcome.timedOut.statusRowText, "Unreachable")
        XCTAssertFalse(RemoteProbeOutcome.unreachable.isFast(threshold: 0.4))
        XCTAssertFalse(RemoteProbeOutcome.timedOut.isFast(threshold: 0.4))
    }

    func testRow04ASlowProbeIsNotFastButStillShowsItsLatencyVerbatim() {
        let slow = RemoteProbeOutcome.reachable(latency: 0.52)
        XCTAssertFalse(slow.isFast(threshold: 0.4))
        XCTAssertEqual(slow.statusRowText, "Reachable, 520 ms")
        XCTAssertTrue(RemoteProbeOutcome.reachable(latency: 0.18).isFast(threshold: 0.4))
        XCTAssertTrue(RemoteProbeOutcome.reachable(latency: 0.4).isFast(threshold: 0.4))
    }
}
