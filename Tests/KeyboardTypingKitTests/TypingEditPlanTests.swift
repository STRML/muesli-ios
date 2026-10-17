import XCTest
@testable import KeyboardTypingKit

/// Matrix rows E1-E7: replacing the partial word with a suggestion.
final class TypingEditPlanTests: XCTestCase {
    // E1
    func testReplacingAPartialDeletesItAndTypesTheWordAndASpace() {
        let plan = TypingEditPlan.replaceWord(partial: "hel", with: "hello", contextAfter: nil)
        XCTAssertEqual(plan.deleteCount, 3)
        XCTAssertEqual(plan.insertText, "hello ")
        XCTAssertEqual(plan.expectedSuffix, "hel")
        XCTAssertNil(plan.undo)
    }

    // E2: no delete and retype when the suggestion is what is already there.
    func testASuggestionEqualToTheWordOnlyAddsTheSpace() {
        let plan = TypingEditPlan.replaceWord(partial: "hello", with: "hello", contextAfter: nil)
        XCTAssertEqual(plan.deleteCount, 0)
        XCTAssertEqual(plan.insertText, " ")
    }

    func testADifferentCaseIsStillAReplacement() {
        let plan = TypingEditPlan.replaceWord(partial: "i", with: "I", contextAfter: nil)
        XCTAssertEqual(plan.deleteCount, 1)
        XCTAssertEqual(plan.insertText, "I ")
    }

    // E3
    func testAPlanOnlyAppliesWhileTheDocumentStillEndsWithThePartial() {
        let plan = TypingEditPlan.replaceWord(partial: "hel", with: "hello", contextAfter: nil)
        XCTAssertTrue(plan.isApplicable(toContextBefore: "say hel"))
        XCTAssertFalse(plan.isApplicable(toContextBefore: "say help"))
        XCTAssertFalse(plan.isApplicable(toContextBefore: "say hel "))
        XCTAssertFalse(plan.isApplicable(toContextBefore: nil))
        XCTAssertFalse(plan.isApplicable(toContextBefore: ""))
    }

    // E5
    func testDeleteCountIsInCharactersNotUTF16Units() {
        let plan = TypingEditPlan.replaceWord(partial: "cafe\u{0301}", with: "caf\u{00E9}s", contextAfter: nil)
        XCTAssertEqual(plan.deleteCount, 4)
        let accented = TypingEditPlan.replaceWord(partial: "se\u{00F1}", with: "se\u{00F1}or", contextAfter: nil)
        XCTAssertEqual(accented.deleteCount, 3)
    }

    // E6: the phase 2 shape: a replacement that the next backspace takes back.
    func testAPlanCanCarryAnUndoThatRestoresTheTypedWord() {
        let undo = TypingReplacementUndo(replacedText: "teh", insertedText: "the ")
        let plan = TypingEditPlan(deleteCount: 3, insertText: "the ", expectedSuffix: "teh", undo: undo)
        XCTAssertEqual(plan.undo?.replacedText, "teh")
        XCTAssertEqual(plan.undo?.insertedText.count, 4)
    }

    // E7: text after the cursor that already starts with a space or punctuation needs no second space.
    func testNoSpaceIsAddedBeforeAnExistingSpaceOrPunctuation() {
        for after in [" world", ", world", ".", "!", "\nnext", ")", "?"] {
            let plan = TypingEditPlan.replaceWord(partial: "hel", with: "hello", contextAfter: after)
            XCTAssertEqual(plan.insertText, "hello", "after: \(after.debugDescription)")
        }
        XCTAssertEqual(TypingEditPlan.replaceWord(partial: "hel", with: "hello", contextAfter: "").insertText, "hello ")
        XCTAssertEqual(TypingEditPlan.replaceWord(partial: "hel", with: "hello", contextAfter: "x").insertText, "hello ")
    }
}
