import XCTest
@testable import DictationPolicyKit

/// Two-pass dictation: which text is inserted once recording ends. One test per failure-matrix row.
final class FinalTextPolicyTests: XCTestCase {
    private struct StubFailure: Error {}
    private struct TimedOut: Error {}

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func resolve(
        streaming: String,
        isLongForm: Bool = false,
        calls: Calls = Calls(),
        finalPass: @escaping () async throws -> FinalTextPolicy.FinalPass?
    ) async throws -> FinalTextPolicy.Decision {
        try await FinalTextPolicy.resolve(
            streamingText: streaming,
            isLongForm: isLongForm,
            timeoutError: TimedOut()
        ) {
            calls.increment()
            return try await finalPass()
        }
    }

    // Row: the final pass arrives in its budget, so its text is inserted, not the streaming text.
    func testFinalPassTextIsInsertedInsteadOfTheStreamingText() async throws {
        let calls = Calls()
        let decision = try await resolve(streaming: "hello world how are you", calls: calls) {
            .init(text: "Hello, world. How are you?", isRemote: false)
        }
        XCTAssertEqual(decision, .init(text: "Hello, world. How are you?", source: .finalPass(isRemote: false)))
        XCTAssertEqual(calls.value, 1)
    }

    // Row: the final pass throws, so the streaming text is inserted and no words are lost.
    func testFinalPassFailureFallsBackToTheStreamingText() async throws {
        let decision = try await resolve(streaming: "keep these words") { throw StubFailure() }
        XCTAssertEqual(decision, .init(text: "keep these words", source: .streaming))
    }

    // Row: the final pass exceeds its budget (watchdog fired), so the streaming text is inserted.
    func testFinalPassTimeoutFallsBackToTheStreamingText() async throws {
        let decision = try await resolve(streaming: "keep these words") { nil }
        XCTAssertEqual(decision, .init(text: "keep these words", source: .streaming))
    }

    // Row: the final pass comes back empty but the stream heard something: insert the stream.
    func testEmptyFinalPassFallsBackToTheStreamingText() async throws {
        let decision = try await resolve(streaming: "the stream heard this") {
            .init(text: "  \n", isRemote: true)
        }
        XCTAssertEqual(decision, .init(text: "the stream heard this", source: .streaming))
    }

    // Row: both are empty: nothing is inserted and the existing empty-result state applies.
    func testBothEmptyInsertNothing() async throws {
        let decision = try await resolve(streaming: "") { .init(text: "", isRemote: false) }
        XCTAssertEqual(decision.text, "")
    }

    // Row: the user cancels while the final pass runs. Cancellation is never turned into a streaming insert.
    func testCancellationDuringTheFinalPassNeverFallsBackToTheStream() async throws {
        do {
            _ = try await resolve(streaming: "must not be inserted") { throw CancellationError() }
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
        }
    }

    // Row: the remote endpoint beats on-device inside its budget, and the transcript records it as remote.
    func testRemoteFinalPassIsReportedAsRemote() async throws {
        let decision = try await resolve(streaming: "local stream") {
            .init(text: "Remote text.", isRemote: true)
        }
        XCTAssertEqual(decision, .init(text: "Remote text.", source: .finalPass(isRemote: true)))
    }

    // Row: a long recording that became a voice note keeps today's path: its streaming text, no second pass.
    func testLongVoiceNoteKeepsItsStreamingTextWithoutAFinalPass() async throws {
        let calls = Calls()
        let decision = try await resolve(streaming: "long note text", isLongForm: true, calls: calls) {
            .init(text: "should not run", isRemote: false)
        }
        XCTAssertEqual(decision, .init(text: "long note text", source: .streaming))
        XCTAssertEqual(calls.value, 0)
    }

    // Row: without streaming text (any non-streaming model) the final pass is the only pass, as today.
    func testWithoutStreamingTextTheFinalPassRunsAndItsErrorsStillFailTheDictation() async throws {
        let ok = try await resolve(streaming: "") { .init(text: "Only pass.", isRemote: false) }
        XCTAssertEqual(ok, .init(text: "Only pass.", source: .finalPass(isRemote: false)))
        do {
            _ = try await resolve(streaming: "") { throw StubFailure() }
            XCTFail("an error with nothing to fall back to must fail the dictation")
        } catch is StubFailure {
        }
        do {
            _ = try await resolve(streaming: "") { nil }
            XCTFail("a timeout with nothing to fall back to must fail the dictation")
        } catch is TimedOut {
        }
    }

    // Row: a long voice note without streaming text still runs its one pass (unchanged path).
    func testLongVoiceNoteWithoutStreamingTextRunsItsOnePass() async throws {
        let decision = try await resolve(streaming: "", isLongForm: true) { .init(text: "Note.", isRemote: false) }
        XCTAssertEqual(decision, .init(text: "Note.", source: .finalPass(isRemote: false)))
    }
}
