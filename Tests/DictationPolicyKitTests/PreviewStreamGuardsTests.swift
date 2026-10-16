import XCTest
@testable import DictationPolicyKit

final class PreviewStreamGuardsTests: XCTestCase {
    func testTokenIsStaleOnceANewStreamStarts() {
        var generation = StreamGeneration()
        let first = generation.advance()
        XCTAssertTrue(generation.isCurrent(first))
        let second = generation.advance()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testTokenIsStaleOnceTheStreamIsInvalidated() {
        var generation = StreamGeneration()
        let token = generation.advance()
        generation.invalidate()
        XCTAssertFalse(generation.isCurrent(token))
    }

    func testBoundedWaitReturnsTheValueOfAFastTask() async {
        let task = Task { 42 }
        let value = await BoundedWait.value(of: task, within: .seconds(5))
        XCTAssertEqual(value, 42)
    }

    func testBoundedWaitGivesUpOnASlowTask() async {
        let task = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        defer { task.cancel() }
        let started = ContinuousClock.now
        let value = await BoundedWait.value(of: task, within: .milliseconds(100))
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }
}
