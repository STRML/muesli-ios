import XCTest
@testable import Muesli

/// Voice rewrite: say what to fix and the keyboard rewrites the selection, or the text just
/// before the cursor. These are the pure pieces: what to capture, and whether a result may
/// still be applied to the field it was meant for.
final class VoiceRewriteCaptureTests: XCTestCase {
    private func capture(selected: String? = nil, before: String? = nil) -> Result<RewriteContext, RewriteCaptureError> {
        RewriteCapture.context(from: KeyboardTextContext(selectedText: selected, textBeforeCursor: before))
    }

    func testASelectionIsWhatGetsRewritten() throws {
        let context = try capture(selected: "Is this right?", before: "Hello. Is this right?").get()
        XCTAssertEqual(context, RewriteContext(target: .selection, original: "Is this right?"))
    }

    func testABlankSelectionFallsBackToTheTextBeforeTheCursor() throws {
        let context = try capture(selected: "  \n", before: "Hello there").get()
        XCTAssertEqual(context, RewriteContext(target: .textBeforeCursor, original: "Hello there"))
    }

    func testWithoutASelectionTheLastParagraphIsRewritten() throws {
        let context = try capture(before: "First paragraph.\n\nSecond one. Is this right?").get()
        XCTAssertEqual(context, RewriteContext(target: .textBeforeCursor, original: "Second one. Is this right?"))
    }

    func testTrailingSpacesStayInTheOriginalSoItStillMatchesTheField() throws {
        let context = try capture(before: "Is this right? ").get()
        XCTAssertEqual(context.original, "Is this right? ")
    }

    func testNothingToFixWhenThereIsNoTextAtAll() {
        XCTAssertEqual(capture(), .failure(.nothingToFix))
        XCTAssertEqual(capture(selected: "", before: ""), .failure(.nothingToFix))
    }

    func testNothingToFixWhenTheCursorSitsOnABlankLine() {
        XCTAssertEqual(capture(before: "Done.\n\n"), .failure(.nothingToFix))
        XCTAssertEqual(capture(before: "   "), .failure(.nothingToFix))
    }

    func testATooLongSelectionIsRefusedBeforeAnythingIsRecorded() {
        let long = String(repeating: "a", count: RewriteLimits.maximumSelectionCharacters + 1)
        XCTAssertEqual(capture(selected: long), .failure(.selectionTooLong(RewriteLimits.maximumSelectionCharacters)))
    }

    func testALongParagraphIsCutAtAWordBoundaryAndStaysASuffixOfTheField() throws {
        let words = Array(repeating: "word", count: 600).joined(separator: " ")
        let before = "Start. " + words
        let context = try capture(before: before).get()
        XCTAssertLessThanOrEqual(context.original.count, RewriteLimits.maximumBeforeCursorCharacters)
        XCTAssertTrue(before.hasSuffix(context.original))
        XCTAssertTrue(context.original.hasPrefix("word"), "cut mid-word: \(context.original.prefix(8))")
    }
}

final class VoiceRewritePlannerTests: XCTestCase {
    private func plan(
        _ context: RewriteContext,
        selected: String? = nil,
        before: String? = nil,
        text: String = "Fixed."
    ) -> RewriteEdit {
        RewritePlanner.plan(
            context: context,
            current: KeyboardTextContext(selectedText: selected, textBeforeCursor: before),
            rewritten: text
        )
    }

    func testAnUnchangedSelectionIsReplacedByInsertingOverIt() {
        let context = RewriteContext(target: .selection, original: "Is this right?")
        XCTAssertEqual(plan(context, selected: "Is this right?"), .replaceSelection("Fixed."))
    }

    func testAChangedOrClearedSelectionIsNeverReplaced() {
        let context = RewriteContext(target: .selection, original: "Is this right?")
        XCTAssertEqual(plan(context, selected: "Is this wrong?"), .stale)
        XCTAssertEqual(plan(context, selected: nil), .stale)
    }

    func testTextBeforeTheCursorIsDeletedThenReplaced() {
        let context = RewriteContext(target: .textBeforeCursor, original: "Is this right?")
        XCTAssertEqual(
            plan(context, before: "Hello. Is this right?"),
            .replaceBeforeCursor(deleteCount: 14, text: "Fixed.")
        )
    }

    func testAMovedCursorOrEditedTextIsNeverReplaced() {
        let context = RewriteContext(target: .textBeforeCursor, original: "Is this right?")
        XCTAssertEqual(plan(context, before: "Hello. Is this right? And more"), .stale)
        XCTAssertEqual(plan(context, before: "Hello."), .stale)
        XCTAssertEqual(plan(context, before: nil), .stale)
    }

    func testASelectionAppearingAfterwardsBlocksABeforeCursorReplacement() {
        let context = RewriteContext(target: .textBeforeCursor, original: "Is this right?")
        XCTAssertEqual(plan(context, selected: "right", before: "Is this right?"), .stale)
    }

    func testDeleteCountIsInCharactersNotUTF16Units() {
        let context = RewriteContext(target: .textBeforeCursor, original: "Great 👍🏽 job")
        XCTAssertEqual(
            plan(context, before: "Great 👍🏽 job"),
            .replaceBeforeCursor(deleteCount: "Great 👍🏽 job".count, text: "Fixed.")
        )
    }
}

/// Requests, results and the runtime status travel between two processes and sit in SQLite, so the new
/// fields must leave every payload an older build wrote decodable.
final class VoiceRewriteModelsTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    func testARequestCarriesItsRewriteTargetAcrossTheStore() throws {
        let context = RewriteContext(target: .textBeforeCursor, original: "Is this right?")
        let request = DictationRequest(rewrite: context)
        let decoded = try decoder.decode(DictationRequest.self, from: encoder.encode(request))
        XCTAssertEqual(decoded.rewrite, context)
    }

    func testARequestFromAnOlderBuildStillDecodesWithoutARewrite() throws {
        let json = #"{"id":"6F1D7C1E-0F4E-4E0B-9B0D-2A0A5B7C9D10","createdAt":1800000000}"#
        let request = try decoder.decode(DictationRequest.self, from: Data(json.utf8))
        XCTAssertNil(request.rewrite)
    }

    func testAResultCarriesTheRewriteItReplaces() throws {
        let context = RewriteContext(target: .selection, original: "teh cat")
        let result = DictationResult(requestID: UUID(), text: "the cat", engineIdentifier: "test", rewrite: context)
        let decoded = try decoder.decode(DictationResult.self, from: encoder.encode(result))
        XCTAssertEqual(decoded.rewrite, context)
        XCTAssertEqual(decoded.text, "the cat")
    }

    func testAResultFromAnOlderBuildStillDecodesWithoutARewrite() throws {
        let json = """
        {"id":"6F1D7C1E-0F4E-4E0B-9B0D-2A0A5B7C9D10","requestID":"1B2C3D4E-0F4E-4E0B-9B0D-2A0A5B7C9D10",
        "text":"hello","createdAt":1800000000,"engineIdentifier":"parakeet"}
        """
        let result = try decoder.decode(DictationResult.self, from: Data(json.utf8))
        XCTAssertNil(result.rewrite)
    }

    func testTheRuntimeStatusSaysWhetherRewriteIsAvailableAndDefaultsToNo() throws {
        let status = KeyboardRuntimeStatus(isActive: true, rewriteAvailable: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let decoded = try decoder.decode(KeyboardRuntimeStatus.self, from: encoder.encode(status))
        XCTAssertTrue(decoded.rewriteAvailable)

        let old = #"{"isActive":true,"phase":"idle","updatedAt":1800000000}"#
        XCTAssertFalse(try decoder.decode(KeyboardRuntimeStatus.self, from: Data(old.utf8)).rewriteAvailable)
    }
}
