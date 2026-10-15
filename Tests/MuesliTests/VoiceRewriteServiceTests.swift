import XCTest
@testable import Muesli

/// The model call behind voice rewrite: what it is asked, and what is allowed to come back.
final class VoiceRewriteServiceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [(system: String, user: String)] = []
        private var replies: [Result<String, Error>]

        init(_ replies: [Result<String, Error>]) { self.replies = replies }

        var calls: [(system: String, user: String)] { lock.withLock { prompts } }

        func complete(system: String, user: String) async throws -> String {
            try lock.withLock {
                prompts.append((system, user))
                guard !replies.isEmpty else { return "" }
                return try replies.removeFirst().get()
            }
        }
    }

    private func service(_ replies: [Result<String, Error>]) -> (VoiceRewriteService, Recorder) {
        let recorder = Recorder(replies)
        return (VoiceRewriteService(complete: recorder.complete), recorder)
    }

    func testThePromptCarriesTheOriginalAndTheSpokenInstructionAsData() async throws {
        let (service, recorder) = service([.success("Is this right.")])
        _ = try await service.rewrite(original: "Is this right?", instruction: "make that a period")
        let user = try XCTUnwrap(recorder.calls.first?.user)
        XCTAssertTrue(user.contains("Is this right?"))
        XCTAssertTrue(user.contains("make that a period"))
        XCTAssertTrue(recorder.calls.first?.system.contains("Return only the") == true)
    }

    func testAReplyIsTrimmedAndReturned() async throws {
        let (service, _) = service([.success("  \r\nIs this right.\n ")])
        let text = try await service.rewrite(original: "Is this right?", instruction: "period")
        XCTAssertEqual(text, "Is this right.")
    }

    func testAnEmptyInstructionNeverReachesTheModel() async {
        let (service, recorder) = service([.success("x")])
        do {
            _ = try await service.rewrite(original: "Hi", instruction: "  \n ")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceRewriteError, .emptyInstruction)
        }
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testCommentaryIsRetriedOnceAndAcceptedWhenTheRetryIsClean() async throws {
        let (service, recorder) = service([
            .success("Here is the rewritten text: Is this right."),
            .success("Is this right."),
        ])
        let text = try await service.rewrite(original: "Is this right?", instruction: "period")
        XCTAssertEqual(text, "Is this right.")
        XCTAssertEqual(recorder.calls.count, 2)
        XCTAssertTrue(recorder.calls[1].user.contains("previous response was invalid"))
    }

    func testCommentaryTwiceIsRefusedSoNothingGetsPasted() async {
        let (service, recorder) = service([
            .success("Here are a few options: 1. A 2. B"),
            .success("Option 1: A\nOption 2: B"),
        ])
        do {
            _ = try await service.rewrite(original: "Hi", instruction: "shorter")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceRewriteError, .nonReplacementResponse)
        }
        XCTAssertEqual(recorder.calls.count, 2)
    }

    func testAnEmptyReplyIsRefused() async {
        let (service, _) = service([.success("  \n ")])
        do {
            _ = try await service.rewrite(original: "Hi", instruction: "shorter")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceRewriteError, .emptyResponse)
        }
    }

    func testAReplyBeyondTheLimitIsRefused() async {
        let huge = String(repeating: "a", count: VoiceRewriteOutput.maximumCharacters + 1)
        let (service, _) = service([.success(huge)])
        do {
            _ = try await service.rewrite(original: "Hi", instruction: "expand")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceRewriteError, .responseTooLong(VoiceRewriteOutput.maximumCharacters))
        }
    }

    func testATransportFailureIsReportedAsTheStudioBeingUnreachable() async {
        struct Offline: Error {}
        let (service, recorder) = service([.failure(Offline())])
        do {
            _ = try await service.rewrite(original: "Hi", instruction: "shorter")
            XCTFail("expected an error")
        } catch {
            guard case .unreachable = error as? VoiceRewriteError else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(recorder.calls.count, 1, "a transport failure is not retried")
    }

    func testAPlainDictationIsDeliveredUntouchedWithoutCallingTheModel() async throws {
        let (service, recorder) = service([.success("never used")])
        let text = try await service.finalText(rewriteOriginal: nil, transcript: "hello world")
        XCTAssertEqual(text, "hello world")
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testARewriteRequestDeliversTheRewrittenText() async throws {
        let (service, _) = service([.success("Is this right.")])
        let text = try await service.finalText(rewriteOriginal: "Is this right?", transcript: "make that a period")
        XCTAssertEqual(text, "Is this right.")
    }

    func testARewriteThatFailsNeverFallsBackToInsertingTheSpokenInstruction() async {
        struct Offline: Error {}
        let (service, _) = service([.failure(Offline())])
        do {
            _ = try await service.finalText(rewriteOriginal: "Is this right?", transcript: "make that a period")
            XCTFail("the instruction must not be delivered as text")
        } catch {
            guard case .unreachable = error as? VoiceRewriteError else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
