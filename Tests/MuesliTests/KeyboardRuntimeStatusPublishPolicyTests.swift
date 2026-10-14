import XCTest
@testable import Muesli

/// The idle keyboard session proves it is alive on every input buffer. Each proof used to be a
/// database write and a cross-process event, twice a second, for as long as the session was armed.
final class KeyboardRuntimeStatusPublishPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ready(message: String = "Keyboard session ready", at date: Date) -> KeyboardRuntimeStatus {
        KeyboardRuntimeStatus(
            isActive: true,
            phase: .idle,
            message: message,
            supportsBackgroundStart: true,
            updatedAt: date
        )
    }

    func testFirstStatusIsAlwaysPublished() {
        let policy = KeyboardRuntimeStatusPublishPolicy()
        XCTAssertTrue(policy.shouldPublish(ready(at: t0), now: t0))
    }

    func testUnchangedStatusInsideTheRefreshWindowIsSkipped() {
        var policy = KeyboardRuntimeStatusPublishPolicy()
        policy.notePublished(ready(at: t0), now: t0)
        // Same content, newer timestamp: the only difference is `updatedAt`.
        XCTAssertFalse(policy.shouldPublish(ready(at: t0.addingTimeInterval(0.5)), now: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(policy.shouldPublish(ready(at: t0.addingTimeInterval(4)), now: t0.addingTimeInterval(4)))
    }

    func testUnchangedStatusIsRepublishedBeforeTheKeyboardTreatsItAsStale() {
        var policy = KeyboardRuntimeStatusPublishPolicy()
        policy.notePublished(ready(at: t0), now: t0)
        let refresh = KeyboardRuntimeStatusPublishPolicy.refreshInterval
        let staleAfter = KeyboardHandoffRecoveryPolicy.keyboardDefaults.runtimeFreshnessInterval
        XCTAssertLessThan(refresh, staleAfter)
        XCTAssertTrue(policy.shouldPublish(ready(at: t0.addingTimeInterval(refresh)), now: t0.addingTimeInterval(refresh)))
    }

    func testAnyChangeTheKeyboardReadsIsPublishedImmediately() {
        var policy = KeyboardRuntimeStatusPublishPolicy()
        policy.notePublished(ready(at: t0), now: t0)
        let later = t0.addingTimeInterval(0.5)
        XCTAssertTrue(policy.shouldPublish(ready(message: "Mic session warming up", at: later), now: later))
        let recording = KeyboardRuntimeStatus(
            isActive: true, activeRequestID: UUID(), phase: .recording, message: "Listening", updatedAt: later
        )
        XCTAssertTrue(policy.shouldPublish(recording, now: later))
        let notActive = KeyboardRuntimeStatus(
            isActive: false, phase: .idle, message: "Keyboard session ready", updatedAt: later
        )
        XCTAssertTrue(policy.shouldPublish(notActive, now: later))
    }

    func testSkippedStatusesDoNotMoveTheRefreshClock() {
        var policy = KeyboardRuntimeStatusPublishPolicy()
        policy.notePublished(ready(at: t0), now: t0)
        let refresh = KeyboardRuntimeStatusPublishPolicy.refreshInterval
        for tick in stride(from: 0.5, to: refresh, by: 0.5) {
            let now = t0.addingTimeInterval(tick)
            XCTAssertFalse(policy.shouldPublish(ready(at: now), now: now))
        }
        let due = t0.addingTimeInterval(refresh)
        XCTAssertTrue(policy.shouldPublish(ready(at: due), now: due))
    }

    func testInvalidatingForgetsTheLastStatusSoTheNextWriteIsNeverSkipped() {
        var policy = KeyboardRuntimeStatusPublishPolicy()
        policy.notePublished(ready(at: t0), now: t0)
        // Another writer (the waveform level) replaced the stored status in between.
        policy.invalidate()
        XCTAssertTrue(policy.shouldPublish(ready(at: t0.addingTimeInterval(0.5)), now: t0.addingTimeInterval(0.5)))
    }
}
