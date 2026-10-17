import XCTest
@testable import DictationPolicyKit

final class LiveTypingThrottleTests: XCTestCase {
    private let interval = LiveTypingThrottle.minInterval

    func testTheFirstUpdateIsAppliedAtOnce() {
        var throttle = LiveTypingThrottle()
        XCTAssertEqual(throttle.offer("hello", now: 10), .applyNow("hello"))
    }

    func testAnUpdateInsideTheWindowWaitsForTheWindowToClose() {
        var throttle = LiveTypingThrottle()
        _ = throttle.offer("hello", now: 10)
        XCTAssertEqual(throttle.offer("hello there", now: 10.05), .waitUntil(10 + interval))
    }

    // U4: only the latest of a burst is written, and in order.
    func testABurstCoalescesToTheLatestText() {
        var throttle = LiveTypingThrottle()
        _ = throttle.offer("a", now: 10)
        _ = throttle.offer("ab", now: 10.02)
        _ = throttle.offer("abc", now: 10.04)
        _ = throttle.offer("abcd", now: 10.06)
        XCTAssertNil(throttle.takePending(now: 10.1), "taken before the window closed")
        XCTAssertEqual(throttle.takePending(now: 10 + interval), "abcd")
        XCTAssertNil(throttle.takePending(now: 10 + interval + 1), "the same text twice")
    }

    func testAnUpdateAfterTheWindowIsAppliedAtOnce() {
        var throttle = LiveTypingThrottle()
        _ = throttle.offer("a", now: 10)
        XCTAssertEqual(throttle.offer("ab", now: 10 + interval + 0.001), .applyNow("ab"))
    }

    // U3: unchanged text is never written again.
    func testTheSameTextIsNotWrittenAgain() {
        var throttle = LiveTypingThrottle()
        _ = throttle.offer("same", now: 10)
        XCTAssertEqual(throttle.offer("same", now: 11), .none)
    }

    // A change that reverts inside the window leaves nothing to write.
    func testATextThatChangesBackInsideTheWindowIsNotWritten() {
        var throttle = LiveTypingThrottle()
        _ = throttle.offer("first", now: 10)
        _ = throttle.offer("second", now: 10.05)
        XCTAssertEqual(throttle.offer("first", now: 10.1), .none)
        XCTAssertNil(throttle.takePending(now: 10 + interval))
    }

    func testResetForgetsEverything() {
        var throttle = LiveTypingThrottle()
        _ = throttle.offer("a", now: 10)
        _ = throttle.offer("ab", now: 10.01)
        throttle.reset()
        XCTAssertNil(throttle.takePending(now: 20))
        XCTAssertEqual(throttle.offer("a", now: 20.01), .applyNow("a"))
    }

    // Ten updates a second for ten seconds: at most about six writes a second.
    func testTenUpdatesASecondAreWrittenAtMostAboutSixTimesASecond() {
        var throttle = LiveTypingThrottle()
        var writes: [String] = []
        var now = 100.0
        var text = ""
        var nextWake: TimeInterval?
        for step in 0..<100 {
            now = 100 + Double(step) * 0.1
            if let wake = nextWake, now >= wake, let pending = throttle.takePending(now: now) {
                writes.append(pending)
                nextWake = nil
            }
            text += "w\(step) "
            switch throttle.offer(text, now: now) {
            case .applyNow(let applied): writes.append(applied)
            case .waitUntil(let wake): nextWake = nextWake ?? wake
            case .none: break
            }
        }
        XCTAssertLessThanOrEqual(writes.count, 62, "more than six writes a second")
        XCTAssertGreaterThan(writes.count, 40, "starved")
        XCTAssertEqual(writes, writes.sorted { $0.count < $1.count }, "reordered")
    }
}
