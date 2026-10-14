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
