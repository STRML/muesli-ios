import UIKit
import XCTest
@testable import Muesli

/// A real `UITextView` as the host. UIKit's own marked-text rules cover what the fakes only model: emoji,
/// right-to-left text, combining marks, selections and what `insertText` and `deleteBackward` do to a marked range.
/// A custom keyboard's `UITextDocumentProxy` forwards to a field like this one across a process boundary, so this is
/// the closest a simulator test gets to the host side of the API.
@MainActor
private final class UITextViewHost: LiveTypingHost {
    let textView: UITextView

    init(text: String = "", selectedRange: NSRange? = nil) {
        textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.text = text
        textView.selectedRange = selectedRange ?? NSRange(location: (text as NSString).length, length: 0)
    }

    func setMarkedText(_ text: String) {
        textView.setMarkedText(text, selectedRange: LiveTypingText.markedSelection(for: text))
    }

    func unmarkText() { textView.unmarkText() }
    func deleteBackward() { textView.deleteBackward() }
    func insertText(_ text: String) { textView.insertText(text) }

    var isMarked: Bool { textView.markedTextRange != nil }
    var text: String { textView.text }

    func snapshot() -> LiveTypingSnapshot {
        let ns = textView.text as NSString
        let range = textView.selectedRange
        return LiveTypingSnapshot(
            before: ns.substring(to: range.location),
            after: ns.substring(from: range.location + range.length),
            selection: ns.substring(with: range),
            documentID: nil
        )
    }
}

@MainActor
final class LiveTypingUITextViewTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    }

    private func make(_ text: String = "", selectedRange: NSRange? = nil) -> UITextViewHost {
        let host = UITextViewHost(text: text, selectedRange: selectedRange)
        window.addSubview(host.textView)
        window.makeKeyAndVisible()
        _ = host.textView.becomeFirstResponder()
        return host
    }

    // MARK: What UIKit does with marked text

    func testSettingMarkedTextTwiceReplacesTheMarkedRange() {
        let host = make("Hello ")
        host.setMarkedText("hello")
        XCTAssertTrue(host.isMarked)
        XCTAssertEqual(host.text, "Hello hello")
        host.setMarkedText("hello world")
        XCTAssertEqual(host.text, "Hello hello world")
        XCTAssertEqual(host.snapshot().before, "Hello hello world", "the cursor is not at the end of the marked text")
    }

    func testClearingMarkedTextRemovesOnlyTheMarkedRange() {
        let host = make("Hello ")
        host.setMarkedText("hello")
        host.setMarkedText("")
        host.unmarkText()
        XCTAssertEqual(host.text, "Hello ")
        XCTAssertFalse(host.isMarked)
    }

    func testClearingWithNoMarkedTextChangesNothing() {
        let host = make("Hello ")
        host.setMarkedText("")
        host.unmarkText()
        XCTAssertEqual(host.text, "Hello ")
    }

    func testUnmarkingKeepsTheWordsAsPlainText() {
        let host = make("Hello ")
        host.setMarkedText("hello")
        host.unmarkText()
        XCTAssertFalse(host.isMarked)
        XCTAssertEqual(host.text, "Hello hello")
    }

    func testTheFinalReplacesTheMarkedWordsInOneStep() {
        let host = make("Hello ")
        host.setMarkedText("hello wor")
        host.setMarkedText("Hello world.")
        host.unmarkText()
        XCTAssertEqual(host.text, "Hello Hello world.")
        XCTAssertFalse(host.isMarked)
    }

    func testTextAfterTheCursorStaysAfterTheMarkedWords() {
        let host = make("Dear  regards", selectedRange: NSRange(location: 5, length: 0))
        host.setMarkedText("sam")
        XCTAssertEqual(host.text, "Dear sam regards")
        XCTAssertEqual(host.snapshot().after, " regards")
    }

    func testEmojiCombiningMarksAndRightToLeftTextKeepTheirUTF16Positions() {
        for words in ["ok 👩\u{200D}👩\u{200D}👧", "cafe\u{301} au lait", "שלום עולם", "مرحبا بالعالم"] {
            let host = make("Start ")
            host.setMarkedText(words)
            XCTAssertEqual(host.text, "Start " + words)
            XCTAssertEqual(host.snapshot().before, "Start " + words, words)
            host.setMarkedText("")
            host.unmarkText()
            XCTAssertEqual(host.text, "Start ", words)
        }
    }

    func testASelectionIsReplacedByTheFirstMarkedWords() {
        let host = make("Replace this", selectedRange: NSRange(location: 8, length: 4))
        XCTAssertEqual(host.snapshot().selection, "this")
        host.setMarkedText("that")
        XCTAssertEqual(host.text, "Replace that", "UIKit replaces the selection: live typing must stay off for one")
    }

    // MARK: A session against the real field

    func testASessionReachesLiveAndTheFinalLeavesTheTextOnceAndUnmarked() {
        let host = make("Hello ")
        var session = LiveTypingSession(
            requestID: UUID(), base: host.snapshot(), isEnabled: true, hasHost: true, isRewrite: false
        )
        func run(_ commands: [LiveTypingCommand]) {
            for command in commands {
                switch command {
                case .setMarked(let t): host.setMarkedText(t)
                case .unmark: host.unmarkText()
                case .clearMarked: host.setMarkedText(""); host.unmarkText()
                case .deleteBackward(let n): for _ in 0..<n { host.deleteBackward() }
                case .insert(let t): host.insertText(t)
                case .log: break
                }
            }
        }
        run(session.partial("hello wor"))
        for _ in 0..<4 { run(session.observed(host.snapshot(), forced: false, settled: true)) }
        XCTAssertEqual(session.phase, .live)
        run(session.partial("hello world"))
        XCTAssertEqual(host.text, "Hello hello world")
        let final = session.final("Hello world.", snapshot: host.snapshot())
        run(final.commands)
        XCTAssertEqual(final.outcome, .replacedInPlace)
        XCTAssertEqual(host.text, "Hello Hello world.")
        XCTAssertFalse(host.isMarked)
    }

    // Measured on the iOS 27 simulator: why the keyboard takes the marked words out before it edits the field.
    func testTypingOrDeletingOverMarkedWordsEatsThem() {
        let typed = make("Hello ")
        typed.setMarkedText("dictated")
        typed.insertText("x")
        XCTAssertEqual(typed.text, "Hello x", "insertText over marked text replaces the dictated words")

        let deleted = make("Hello ")
        deleted.setMarkedText("dictated")
        deleted.deleteBackward()
        XCTAssertEqual(deleted.text, "Hello ", "deleteBackward over marked text removes the whole marked range")
    }

    func testClearingFirstMeansTypingAfterwardsKeepsTheUsersText() {
        let host = make("Hello ")
        host.setMarkedText("dictated")
        host.setMarkedText("")
        host.unmarkText()
        host.insertText("x")
        XCTAssertEqual(host.text, "Hello x")
    }
}
