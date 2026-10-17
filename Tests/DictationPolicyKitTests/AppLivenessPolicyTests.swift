import XCTest
@testable import DictationPolicyKit

/// Whether an app heartbeat still proves the app is running. Rows R06 (the boundary), R07 (clocks that move) and
/// R28 (a record from another build). Time is always a `Date` the test supplies.
final class AppLivenessPolicyTests: XCTestCase {
    private typealias Policy = AppLivenessPolicy
    private typealias F = ReadinessFixtures

    // The bound is three missed beats, tied to the cadence and to the existing runtime-status freshness.
    func testTheBoundIsThreeBeatsOfTheCadence() {
        XCTAssertEqual(Policy.heartbeatInterval, 5)
        XCTAssertEqual(Policy.staleAfter, Policy.heartbeatInterval * 3)
    }

    // R06: just refreshed versus just expired.
    func testFreshnessAtTheBoundary() {
        let cases: [(age: TimeInterval, expected: Policy.Freshness)] = [
            (0, .fresh), (5, .fresh), (14.99, .fresh), (15, .fresh), (15.01, .stale), (60, .stale), (86_400, .stale),
        ]
        for (age, expected) in cases {
            XCTAssertEqual(Policy.freshness(heartbeatAt: F.t0.addingTimeInterval(-age), now: F.t0), expected, "age \(age)")
        }
    }

    // R07: the clock went backwards. A heartbeat from "the future" more than the tolerance ahead is not proof;
    // the live app rewrites it within one beat, so a wrong clock costs one flicker, never a lie.
    func testAHeartbeatFromTheFutureIsNotLive() {
        XCTAssertEqual(Policy.freshness(heartbeatAt: F.t0.addingTimeInterval(1), now: F.t0), .fresh)
        XCTAssertEqual(Policy.freshness(heartbeatAt: F.t0.addingTimeInterval(2), now: F.t0), .fresh)
        XCTAssertEqual(Policy.freshness(heartbeatAt: F.t0.addingTimeInterval(2.01), now: F.t0), .clockSkewed)
        XCTAssertEqual(Policy.freshness(heartbeatAt: F.t0.addingTimeInterval(3_600), now: F.t0), .clockSkewed)
    }

    // R07: the clock jumped forward an hour; the old heartbeat reads stale until the app's next beat.
    func testAClockJumpForwardReadsStale() {
        let beat = F.t0
        XCTAssertEqual(Policy.freshness(heartbeatAt: beat, now: beat.addingTimeInterval(3_600)), .stale)
    }

    func testNoRecordMeansNobodyIsLive() {
        XCTAssertEqual(F.liveness(nil), AppLiveness.none)
    }

    func testAFreshRecordOfThisBuildIsLive() {
        let liveness = F.liveness(F.record(heartbeatAge: 3))
        XCTAssertEqual(liveness.liveBootID, F.liveBoot)
        XCTAssertEqual(liveness.recordedBootID, F.liveBoot)
        XCTAssertEqual(liveness.heartbeatAge ?? -1, 3, accuracy: 0.001)
    }

    func testAStaleRecordNamesTheBootButIsNotLive() {
        let liveness = F.liveness(F.record(heartbeatAge: 20))
        XCTAssertNil(liveness.liveBootID)
        XCTAssertEqual(liveness.recordedBootID, F.liveBoot)
    }

    func testASkewedRecordIsNotLive() {
        let liveness = F.liveness(F.record(heartbeatAge: -3_600))
        XCTAssertNil(liveness.liveBootID)
        XCTAssertEqual(liveness.recordedBootID, F.liveBoot)
    }

    // R28: a fresh heartbeat from another app build cannot vouch for this keyboard's build.
    func testAFreshRecordFromAnotherBuildIsNotLive() {
        let record = F.record(stamp: F.updatedStamp, heartbeatAge: 1)
        let liveness = F.liveness(record)
        XCTAssertNil(liveness.liveBootID)
        XCTAssertEqual(liveness.recordedBootID, record.bootID)
    }

    // The OS can differ between the stamps without the app being another build; liveness is about the app.
    func testAnotherOSVersionAloneDoesNotMakeALiveAppDead() {
        XCTAssertEqual(F.liveness(F.record(stamp: F.newOSStamp, heartbeatAge: 1)).liveBootID, F.liveBoot)
    }
}
