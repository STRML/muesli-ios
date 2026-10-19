import XCTest
@testable import DictationPolicyKit

/// Drives a `LiveTypingSession` against a `ModelMarkedHost` the way the keyboard does: write what the session says,
/// let the host's callback reach the keyboard, and observe again until the session has nothing more to do.
private final class Harness {
    var session: LiveTypingSession
    let host: ModelMarkedHost
    let base: LiveTypingSnapshot

    init(
        before: String = "Hello ",
        after: String = "",
        behavior: ModelMarkedHost.Behavior = .full,
        chunkThreshold: Int = LiveTypingText.chunkThreshold,
        enabled: Bool = true,
        hasHost: Bool = true,
        isRewrite: Bool = false,
        configure: (ModelMarkedHost) -> Void = { _ in }
    ) {
        host = ModelMarkedHost(before: before, after: after, behavior: behavior)
        configure(host)
        host.flush()
        base = host.snapshot()
        session = LiveTypingSession(
            requestID: UUID(), base: base, isEnabled: enabled, hasHost: hasHost, isRewrite: isRewrite,
            chunkThreshold: chunkThreshold
        )
    }

    var logs: [String] { host.log.filter { $0.hasPrefix("live_typing.") } }

    @discardableResult
    func partial(_ text: String) -> [LiveTypingCommand] {
        let commands = session.partial(text)
        host.perform(commands)
        return commands
    }

    /// The host's change callbacks reach the keyboard until the session stops reacting.
    func settle(forced: Bool = false, settled: Bool = true) {
        for _ in 0..<8 {
            host.flush()
            let commands = session.observed(host.snapshot(), forced: forced, settled: settled)
            if commands.isEmpty { return }
            host.perform(commands)
        }
    }

    func reachLive(with text: String = "hello") {
        partial(text)
        settle()
        XCTAssertEqual(session.phase, .live, "never reached live")
    }
}

final class LiveTypingSessionTests: XCTestCase {
    // MARK: Supported host (P1)

    func testASupportedHostMarksProbesAndThenReplacesTheMarkedWords() {
        let h = Harness()
        h.partial("hello")
        XCTAssertEqual(h.host.document, "Hello hello")
        XCTAssertEqual(h.session.phase, .probingAppearance)
        h.settle()
        XCTAssertEqual(h.session.phase, .live)
        XCTAssertEqual(h.host.document, "Hello hello")
        XCTAssertEqual(h.host.markedLength, 5)

        h.partial("hello world")
        XCTAssertEqual(h.host.document, "Hello hello world")
        XCTAssertEqual(h.host.markedLength, 11)
    }

    func testTheFinalTextReplacesTheMarkedWordsInOneOperationAndUnmarks() {
        let h = Harness()
        h.reachLive()
        h.partial("hello world")
        h.host.perform([])
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.commands, [.setMarked("Hello world."), .unmark], "an empty flash between the two")
        XCTAssertEqual(result.outcome, .replacedInPlace)
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, "Hello Hello world.")
        XCTAssertEqual(h.host.markedLength, 0)
        XCTAssertEqual(h.session.phase, .finished)
    }

    func testAFinalThatEqualsTheMarkedTextOnlyUnmarks() {
        let h = Harness()
        h.reachLive(with: "hello world")
        let result = h.session.final("hello world", snapshot: h.host.snapshot())
        XCTAssertEqual(result.commands, [.unmark])
        XCTAssertEqual(result.outcome, .replacedInPlace)
    }

    func testAFinalKeepsItsTrailingNewlineAndSpacesExactly() {
        let h = Harness()
        h.reachLive()
        let result = h.session.final(" Hello there.\n", snapshot: h.host.snapshot())
        XCTAssertEqual(result.commands, [.setMarked(" Hello there.\n"), .unmark])
    }

    // MARK: Hosts that cannot do it (P2-P5)

    func testAHostThatIgnoresMarkedTextIsFoundOutAndLeftUntouched() {
        let h = Harness(behavior: .ignoresMarked)
        h.partial("hello")
        h.settle()
        XCTAssertEqual(h.session.phase, .probingAppearance, "decided before the host had time to answer")
        h.settle(forced: true)
        XCTAssertEqual(h.session.phase, .stripOnly(.noChange))
        XCTAssertEqual(h.host.document, "Hello ")
        XCTAssertTrue(h.logs.contains("live_typing.unsupported noChange"), "\(h.logs)")
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain("Hello world."))
        XCTAssertTrue(result.commands.isEmpty)
    }

    func testAHostThatInsertsPlainTextForMarkedTextIsCaughtAndCleanedUp() {
        let h = Harness(behavior: .appendsAsPlain)
        h.partial("hi")
        XCTAssertEqual(h.host.document, "Hello hi")
        h.settle()
        XCTAssertEqual(h.session.phase, .stripOnly(.appended))
        XCTAssertEqual(h.host.document, "Hello ", "duplicated text left behind")
        XCTAssertTrue(h.logs.contains("live_typing.unsupported appended"), "\(h.logs)")
    }

    func testAHostThatMarksButHidesItFromTheContextIsClearedWithoutDeleting() {
        let h = Harness(before: "Hello ", behavior: .hidesMarkedFromContext)
        h.partial("hello")
        XCTAssertEqual(h.host.markedLength, 5)
        h.settle(forced: true)
        XCTAssertEqual(h.session.phase, .stripOnly(.noChange))
        XCTAssertEqual(h.host.markedLength, 0)
        XCTAssertEqual(h.host.document, "Hello ", "the hidden marked text is still in the field")
        XCTAssertFalse(h.host.log.contains("deleteBackward"), "removed with deleteBackward, which would eat the user's text on another host")
    }

    func testAHostThatPutsTheTextAfterTheCursorIsClearedAtOnce() {
        let h = Harness(before: "Hello ", after: "there", behavior: .landsAfterCursor)
        h.partial("hello")
        XCTAssertEqual(h.host.after, "hellothere")
        h.settle()
        XCTAssertEqual(h.session.phase, .stripOnly(.notAtCursor))
        XCTAssertEqual(h.host.document, "Hello there")
        XCTAssertTrue(h.logs.contains("live_typing.unsupported notAtCursor"), "\(h.logs)")
    }

    // MARK: A proxy that answers late (P6)

    func testAProxyThatAnswersLateIsWaitedFor() {
        let h = Harness { $0.lags = true }
        h.partial("hello")
        // The host has the words; the proxy has not reported them yet.
        XCTAssertEqual(h.session.observed(h.host.snapshot(), forced: false, settled: true), [])
        XCTAssertEqual(h.session.phase, .probingAppearance)
        h.settle()
        XCTAssertEqual(h.session.phase, .live)
    }

    func testAProxyThatNeverAnswersIsUnsupportedWhenTheTimeoutFires() {
        let h = Harness { $0.lags = true }
        h.partial("hello")
        _ = h.session.observed(h.host.snapshot(), forced: true, settled: true)
        XCTAssertEqual(h.session.phase, .stripOnly(.noChange))
    }

    func testUpdatesThatArriveWhileTheProbeRunsAreHeldAndThenWritten() {
        let h = Harness { $0.lags = true }
        h.partial("hello")
        XCTAssertTrue(h.partial("hello wor").isEmpty)
        XCTAssertTrue(h.partial("hello world").isEmpty)
        h.settle()
        XCTAssertEqual(h.session.phase, .live)
        XCTAssertEqual(h.host.document, "Hello hello world")
    }

    func testALaggingProxyShowingTheLastTextIsNotADisturbance() {
        let h = Harness()
        h.reachLive(with: "hello")
        h.host.lags = true
        h.host.flush()
        h.partial("hello there")
        // The proxy still reports "hello" for a moment.
        XCTAssertEqual(h.session.observed(h.host.snapshot(), forced: false, settled: true), [])
        XCTAssertEqual(h.session.phase, .live)
    }

    // MARK: What hosts do to the words (P7-P9)

    func testAHostThatCapitalizesTheFirstLetterStillCountsAsShowingTheWords() {
        let h = Harness(before: "") { $0.capitalizesFirstLetter = true }
        h.partial("hello")
        h.settle()
        XCTAssertEqual(h.session.phase, .live)
        XCTAssertEqual(h.host.document, "Hello")
    }

    func testSmartQuotesInTheContextStillMatch() {
        let h = Harness(before: "") { $0.smartQuotes = true }
        h.partial("don't")
        h.settle()
        XCTAssertEqual(h.session.phase, .live)
    }

    func testRightToLeftEmojiAndCombiningMarksReachLive() {
        for text in ["שלום עולם", "مرحبا بالعالم", "ok 👩\u{200D}👩\u{200D}👧 and cafe\u{301}"] {
            let h = Harness(before: "")
            h.partial(text)
            h.settle()
            XCTAssertEqual(h.session.phase, .live, text)
            XCTAssertEqual(h.host.document, text)
        }
    }

    // MARK: Where it starts (L1-L6)

    func testAnEmptyFieldWorks() {
        let h = Harness(before: "", after: "")
        h.reachLive()
        XCTAssertEqual(h.host.document, "hello")
    }

    func testTextAfterTheCursorIsLeftAloneAndTheWordsGoBeforeIt() {
        let h = Harness(before: "Dear ", after: " regards")
        h.reachLive(with: "sam")
        h.partial("sam how are")
        XCTAssertEqual(h.host.document, "Dear sam how are regards")
        let result = h.session.final("Sam, how are you?", snapshot: h.host.snapshot())
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, "Dear Sam, how are you? regards")
        XCTAssertEqual(h.host.after, " regards")
    }

    func testASelectionAtTheStartKeepsLiveTypingOffAndTheFinalAsToday() {
        let h = Harness(before: "Replace this", after: "") { $0.userSelects(4) }
        XCTAssertEqual(h.base.selection, "this")
        XCTAssertEqual(h.session.phase, .stripOnly(.selection))
        XCTAssertTrue(h.partial("hello").isEmpty)
        XCTAssertEqual(h.host.document, "Replace this", "the selection was touched")
        let result = h.session.final("Hello.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain("Hello."))
    }

    func testTheSettingOffNoHostAndARewriteNeverTypeLive() {
        let cases: [(Harness, LiveTypingOff)] = [
            (Harness(enabled: false), .settingOff),
            (Harness(hasHost: false), .noHost),
            (Harness(isRewrite: true), .rewrite),
        ]
        for (h, reason) in cases {
            XCTAssertEqual(h.session.phase, .stripOnly(reason))
            XCTAssertTrue(h.partial("hello").isEmpty, "\(reason)")
            XCTAssertEqual(h.host.document, "Hello ")
            XCTAssertEqual(h.session.final("Hi.", snapshot: h.host.snapshot()).outcome, .insertPlain("Hi."))
        }
    }

    func testADictationThatNeverProducedPartialsInsertsTheFinalAsToday() {
        let h = Harness()
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain("Hello world."))
        XCTAssertTrue(result.commands.isEmpty)
    }

    // MARK: Updates (U1-U3)

    func testAShorterOrRevisedPartialReplacesTheWholeMarkedRange() {
        let h = Harness()
        h.reachLive(with: "the quick brown")
        h.partial("a quick")
        XCTAssertEqual(h.host.document, "Hello a quick")
        h.partial("a quick brown fox")
        XCTAssertEqual(h.host.document, "Hello a quick brown fox")
        h.partial("The quick brown fox")
        XCTAssertEqual(h.host.document, "Hello The quick brown fox")
        XCTAssertEqual(h.host.markedLength, "The quick brown fox".count)
    }

    func testAnEmptyPartialNeverErasesTheWords() {
        let h = Harness()
        h.reachLive(with: "hello there")
        XCTAssertTrue(h.partial("").isEmpty)
        XCTAssertTrue(h.partial(" \n ").isEmpty)
        XCTAssertEqual(h.host.document, "Hello hello there")
        XCTAssertEqual(h.session.marked, "hello there")
    }

    func testAnUnchangedPartialWritesNothing() {
        let h = Harness()
        h.reachLive(with: "hello there")
        XCTAssertTrue(h.partial("hello there").isEmpty)
        XCTAssertTrue(h.partial("  hello there  ").isEmpty)
    }

    func testAnEmptyFirstPartialDoesNotStartTheProbe() {
        let h = Harness()
        XCTAssertTrue(h.partial("  ").isEmpty)
        XCTAssertEqual(h.session.phase, .awaitingFirstPartial)
    }

    // MARK: Ending without a final (F4-F7)

    func testEndingWithoutAResultKeepsTheWordsAsPlainText() {
        let h = Harness()
        h.reachLive(with: "keep these words")
        let commands = h.session.endWithoutResult()
        XCTAssertEqual(commands, [.unmark])
        h.host.perform(commands)
        XCTAssertEqual(h.host.document, "Hello keep these words")
        XCTAssertEqual(h.host.markedLength, 0)
        XCTAssertEqual(h.session.phase, .finished)
    }

    func testCancelRemovesTheMarkedWordsAndLeavesTheFieldAsItWas() {
        let h = Harness(before: "Hello ", after: " bye")
        h.reachLive(with: "do not keep this")
        let commands = h.session.cancel(snapshot: h.host.snapshot())
        XCTAssertEqual(commands, [.clearMarked])
        h.host.perform(commands)
        XCTAssertEqual(h.host.document, "Hello  bye")
        XCTAssertEqual(h.session.phase, .cancelled)
    }

    func testAPartialAfterCancelIsIgnored() {
        let h = Harness()
        h.reachLive()
        h.host.perform(h.session.cancel(snapshot: h.host.snapshot()))
        XCTAssertTrue(h.partial("late words").isEmpty)
        XCTAssertEqual(h.host.document, "Hello ")
    }

    func testCancelDuringTheProbeAlsoClears() {
        let h = Harness()
        h.partial("hello")
        h.host.perform(h.session.cancel(snapshot: h.host.snapshot()))
        XCTAssertEqual(h.host.document, "Hello ")
    }

    func testCancelBeforeAnyPartialDoesNothing() {
        let h = Harness()
        XCTAssertTrue(h.session.cancel(snapshot: h.host.snapshot()).isEmpty)
        XCTAssertEqual(h.session.phase, .cancelled)
    }

    // MARK: Disturbance from outside (D1-D3)

    func testTheUserTappingElsewhereKeepsTheWordsAndWithholdsTheFinal() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.userMovesCursor(toOffsetFromEnd: 6)
        h.settle()
        XCTAssertEqual(h.session.phase, .kept(.cursorMoved))
        XCTAssertEqual(h.host.markedLength, 0)
        let before = h.host.document
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .withheld(.detached))
        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertEqual(h.host.document, before, "a second copy of the words")
        XCTAssertTrue(h.logs.contains("live_typing.detached cursorMoved"), "\(h.logs)")
    }

    func testADisturbanceInsideTheSettlingWindowWaits() {
        let h = Harness()
        h.reachLive()
        h.host.userMovesCursor(toOffsetFromEnd: 3)
        XCTAssertTrue(h.session.observed(h.host.snapshot(), forced: false, settled: false).isEmpty)
        XCTAssertEqual(h.session.phase, .live)
    }

    func testAnotherFieldKeepsTheWordsAndWithholdsTheFinal() {
        let h = Harness()
        h.reachLive()
        h.host.userSwitchesField()
        h.settle()
        XCTAssertEqual(h.session.phase, .kept(.fieldChanged))
        XCTAssertEqual(h.session.final("Hi.", snapshot: h.host.snapshot()).outcome, .withheld(.detached))
    }

    func testAHostThatWritesItsOwnTextBackFallsBackToThePlainFinal() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.hostRewritesItsText()
        h.settle()
        XCTAssertEqual(h.session.phase, .stripOnly(.hostRewrote))
        XCTAssertTrue(h.logs.contains("live_typing.detached textChanged"), "\(h.logs)")
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain("Hello world."), "the words were silently lost")
    }

    func testAFinalThatArrivesBeforeTheRecheckStillInsertsWhenTheHostDroppedTheWords() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.hostRewritesItsText()
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain("Hello world."))
        XCTAssertEqual(h.session.documentID, h.base.documentID)
    }

    func testWordsGoneBecauseTheCursorMovedAreStillWithheld() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.userMovesCursor(toOffsetFromEnd: 6)
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .withheld(.detached))
    }

    func testTheHostChangingTheWordsDetaches() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.deleteBackward()
        h.host.insert("zzz")
        h.host.flush()
        h.settle()
        XCTAssertEqual(h.session.phase, .kept(.textChanged))
    }

    func testASelectionMadeInTheFieldDetaches() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.userSelects(3)
        h.settle()
        XCTAssertEqual(h.session.phase, .kept(.cursorMoved))
    }

    // MARK: The user edits the field themselves (D4-D7)

    func testTypingAKeyRemovesTheWordsAndTheFinalComesAtTheCursorAfterIt() {
        let h = Harness()
        h.reachLive(with: "hello world")
        let commands = h.session.yield(.yielded)
        XCTAssertEqual(commands.first, .clearMarked)
        XCTAssertTrue(h.logs.isEmpty)
        h.host.perform(commands)
        XCTAssertTrue(h.logs.contains("live_typing.yielded yielded"), "\(h.logs)")
        h.host.insert("x")
        XCTAssertEqual(h.host.document, "Hello x")
        XCTAssertEqual(h.session.phase, .stripOnly(.yielded))
        let result = h.session.final("Hello world.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain("Hello world."))
        h.host.insert("Hello world.")
        XCTAssertEqual(h.host.document, "Hello xHello world.")
    }

    func testYieldingBeforeAnyWordsDoesNothingAndTurnsLiveTypingOff() {
        let h = Harness()
        XCTAssertTrue(h.session.yield(.yielded).isEmpty)
        XCTAssertTrue(h.partial("late").isEmpty)
        XCTAssertEqual(h.host.document, "Hello ")
    }

    func testHidingTheKeyboardRemovesTheWords() {
        let h = Harness()
        h.reachLive()
        h.host.perform(h.session.yield(.hidden))
        XCTAssertEqual(h.host.document, "Hello ")
        XCTAssertEqual(h.host.markedLength, 0)
        XCTAssertEqual(h.session.phase, .stripOnly(.hidden))
    }

    func testYieldingDuringTheProbeClearsTheWords() {
        let h = Harness()
        h.partial("hello")
        h.host.perform(h.session.yield(.yielded))
        XCTAssertEqual(h.host.document, "Hello ")
    }

    // MARK: Very long dictations (C1-C7)

    private func sentences(_ count: Int) -> [String] {
        (1...count).map { "This is sentence number \($0)." }
    }

    func testALongDictationCommitsFinishedSentencesAsPlainTextAndKeepsTheRestMarked() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        let commands = h.partial(long)
        XCTAssertEqual(commands.count, 3, "\(commands)")
        XCTAssertEqual(commands.dropFirst().first, .unmark)
        XCTAssertEqual(h.host.document, "Hello " + long)
        XCTAssertLessThan(h.host.markedLength, 120, "the marked range is still huge")
        XCTAssertEqual(h.session.mirroredText, long)
        XCTAssertFalse(h.session.committed.isEmpty)
    }

    func testADictationUnderTheThresholdNeverChunks() {
        let h = Harness(chunkThreshold: 400)
        h.reachLive(with: "This is sentence number 1.")
        let commands = h.partial(sentences(6).joined(separator: " "))
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(h.session.committed.isEmpty)
    }

    func testAFinalThatExtendsTheCommittedTextReplacesOnlyTheMarkedTail() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        let final = long + " thing."
        let result = h.session.final(final, snapshot: h.host.snapshot())
        h.host.perform(result.commands)
        XCTAssertFalse(result.commands.contains { if case .deleteBackward = $0 { true } else { false } })
        XCTAssertEqual(h.host.document, "Hello " + final)
        XCTAssertEqual(h.host.markedLength, 0)
    }

    func testAFinalThatRevisesCommittedTextRewritesItWhenTheFieldStillEndsWithIt() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        let final = "Revised: " + long
        let result = h.session.final(final, snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .replacedInPlace)
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, "Hello " + final)
    }

    func testARewriteIsRefusedWhenTheFieldNoLongerEndsWithTheCommittedText() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        h.host.userMovesCursor(toOffsetFromEnd: 5)
        let before = h.host.document
        let result = h.session.final("Revised: " + long, snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .withheld(.detached))
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, before)
    }

    // MARK: Backspace edits the dictation

    private func backspace(_ h: Harness) -> Bool {
        guard let commands = h.session.deleteLastWord() else { return false }
        h.host.perform(commands)
        return true
    }

    func testBackspaceTakesBackTheLastWordAndTheDictationCarriesOn() {
        let h = Harness()
        h.reachLive(with: "hello world how")
        XCTAssertTrue(backspace(h))
        XCTAssertEqual(h.host.document, "Hello hello world")
        XCTAssertEqual(h.session.phase, .live)
        h.partial("hello world how are")
        XCTAssertEqual(h.host.document, "Hello hello world are", "the deleted word came back")
        h.settle()
        XCTAssertEqual(h.session.phase, .live, "the edit read as the host disturbing the words")
    }

    func testARevisionOfTheDeletedWordDoesNotBringItBack() {
        let h = Harness()
        h.reachLive(with: "hello wor")
        XCTAssertTrue(backspace(h))
        h.partial("hello world how")
        XCTAssertEqual(h.host.document, "Hello hello how")
    }

    func testBackspaceTwiceTakesTwoWords() {
        let h = Harness()
        h.reachLive(with: "one two three")
        XCTAssertTrue(backspace(h))
        XCTAssertTrue(backspace(h))
        XCTAssertEqual(h.host.document, "Hello one")
        h.partial("one two three four")
        XCTAssertEqual(h.host.document, "Hello one four")
    }

    func testTheFinalKeepsTheEditAndTakesTheModelsWordsAfterIt() {
        let h = Harness()
        h.reachLive(with: "hello world how")
        XCTAssertTrue(backspace(h))
        h.partial("hello world how are")
        let result = h.session.final("Hello world, how are you?", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .replacedInPlace)
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, "Hello hello world are you?")
        XCTAssertEqual(h.host.markedLength, 0)
    }

    func testAFinalThatChangesTheWordCountALotKeepsWhatIsInTheField() {
        let h = Harness()
        h.reachLive(with: "a b c d")
        XCTAssertTrue(backspace(h))
        let result = h.session.final("Completely different long sentence that changes everything", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .replacedInPlace)
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, "Hello a b c")
    }

    func testBackspaceOnASpacelessScriptTakesOneWordNotTheWholeUtterance() {
        let h = Harness()
        h.reachLive(with: "今日はいい天気です")
        XCTAssertTrue(backspace(h))
        XCTAssertTrue(h.host.document.hasPrefix("Hello 今日"), h.host.document)
        XCTAssertFalse(h.host.document.contains("です"), h.host.document)
        h.partial("今日はいい天気です。明日も")
        XCTAssertTrue(h.host.document.contains("明日も"), h.host.document)
        XCTAssertFalse(h.host.document.contains("です"), "the deleted word came back: \(h.host.document)")
    }

    func testARevisionThatAddsAWordBeforeTheDeletedOneDoesNotBringItBack() {
        let h = Harness()
        h.reachLive(with: "we can leave")
        XCTAssertTrue(backspace(h))
        XCTAssertEqual(h.host.document, "Hello we can")
        h.partial("we really can leave now")
        XCTAssertEqual(h.host.document, "Hello we can now", "the deleted word came back")
    }

    func testARevisionThatReplacesTheDeletedWordDoesNotKeepTheReplacement() {
        let h = Harness()
        h.reachLive(with: "we can leave")
        XCTAssertTrue(backspace(h))
        h.partial("we really can go now")
        XCTAssertEqual(h.host.document, "Hello we can now", "the word in the deleted slot came back")
    }

    func testARevisionThatLosesTheWordsBeforeTheDeletedOneDefersToTheEngine() {
        let h = Harness()
        h.reachLive(with: "we can leave")
        XCTAssertTrue(backspace(h))
        h.partial("we really might go now")
        XCTAssertEqual(h.host.document, "Hello we really might go now", "dictated words were lost")
        XCTAssertFalse(h.host.document.contains("leave"))
    }

    func testAnUnmatchedRevisionStillDropsTheDeletedWordWhenItIsThere() {
        let h = Harness()
        h.reachLive(with: "we can leave")
        XCTAssertTrue(backspace(h))
        h.partial("we kan leave now")
        XCTAssertEqual(h.host.document, "Hello we kan now", "the deleted word came back")
    }

    func testDeletingTheFirstWordThenARevisionThatPutsAWordBeforeItDoesNotBringItBack() {
        let h = Harness()
        h.reachLive(with: "leave")
        XCTAssertTrue(backspace(h))
        h.partial("we leave now")
        XCTAssertEqual(h.host.document, "Hello we now", "the deleted word came back, or a word was dropped")
    }

    func testAnUnmatchedRevisionKeepsALaterOccurrenceOfTheDeletedWord() {
        let h = Harness()
        h.reachLive(with: "we can leave")
        XCTAssertTrue(backspace(h))
        h.partial("we really might go and then we will all leave now")
        XCTAssertTrue(h.host.document.contains("all leave now"), "a new word was lost: \(h.host.document)")
    }

    func testAnUnmatchedFinalDefersToTheEngineToo() {
        let h = Harness()
        h.reachLive(with: "we can leave")
        XCTAssertTrue(backspace(h))
        let result = h.session.final("We really might go now", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .replacedInPlace)
        h.host.perform(result.commands)
        XCTAssertEqual(h.host.document, "Hello We really might go now")
    }

    func testBackspaceKeepsThePunctuationThatEndsThePreviousSentence() {
        let h = Harness()
        h.reachLive(with: "we left. tomorrow")
        XCTAssertTrue(backspace(h))
        XCTAssertEqual(h.host.document, "Hello we left.")
        h.partial("we left. tomorrow we go")
        XCTAssertEqual(h.host.document, "Hello we left. we go")
    }

    func testBackspaceOnPunctuationOnlyIsTakenAndChangesNothing() {
        let h = Harness()
        h.reachLive(with: ".")
        let commands = h.session.deleteLastWord()
        XCTAssertEqual(commands, [], "the key was passed to the host text")
        XCTAssertEqual(h.host.document, "Hello .")
    }

    func testBackspaceTakesTheOnlyWordLeftAfterCommittedSentences() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        h.partial(sentences(6).joined(separator: " ") + " next")
        XCTAssertFalse(h.session.committed.isEmpty, "the sentences were not committed")
        XCTAssertEqual(LiveTypingText.wordCount(h.session.marked), 1, h.session.marked)
        XCTAssertTrue(backspace(h), "the one marked word could not be deleted")
        XCTAssertEqual(h.session.marked, "")
        XCTAssertTrue(h.host.document.hasSuffix(h.session.committed), h.host.document)
    }

    func testBackspaceBeforeAnyWordsLeavesTheKeyToTheField() {
        let h = Harness()
        XCTAssertNil(h.session.deleteLastWord())
    }

    func testBackspaceWithNoMarkedWordLeftLeavesTheKeyToTheField() {
        let h = Harness()
        h.reachLive(with: "hello")
        XCTAssertTrue(backspace(h))
        XCTAssertEqual(h.host.document, "Hello ")
        XCTAssertNil(h.session.deleteLastWord(), "a second backspace should edit the user's own text")
    }

    func testAHostRewriteAfterChunkingStillInsertsTheRestWhenTheHostChangedTheCase() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        h.host.hostRewritesItsText()
        let first = long.prefix(1)
        let flipped = (first == first.uppercased() ? first.lowercased() : first.uppercased()) + long.dropFirst()
        let result = h.session.final(flipped + " words.", snapshot: h.host.snapshot())
        guard case .insertPlain(let rest) = result.outcome else {
            return XCTFail("the final was withheld: \(result.outcome)")
        }
        XCTAssertFalse(rest.isEmpty)
        XCTAssertTrue(h.session.fieldCannotTakeLiveWords)
    }

    func testAProbeThatNeverSawTheWordsRemembersTheField() {
        let h = Harness(behavior: .ignoresMarked)
        h.partial("hello")
        h.settle(forced: true)
        XCTAssertEqual(h.session.phase, .stripOnly(.noChange))
        XCTAssertTrue(h.session.fieldCannotTakeLiveWords)
    }

    func testAMovedCursorDoesNotCondemnTheField() {
        let h = Harness()
        h.reachLive(with: "hello world")
        h.host.userMovesCursor(toOffsetFromEnd: 6)
        h.settle()
        XCTAssertFalse(h.session.fieldCannotTakeLiveWords)
    }

    func testARewriteIsRefusedBeyondTheDeleteCap() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        var long = ""
        while long.count <= LiveTypingText.maxRewriteDelete + 200 {
            long += sentences(8).joined(separator: " ") + " "
            h.partial(long + "tail words")
        }
        let result = h.session.final("Revised: " + long + "tail words", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .withheld(.rewrite))
    }

    func testCancelAlsoRemovesCommittedChunksWhenTheFieldStillEndsWithThem() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        h.partial(sentences(6).joined(separator: " ") + " And one more")
        h.host.perform(h.session.cancel(snapshot: h.host.snapshot()))
        XCTAssertEqual(h.host.document, "Hello ")
    }

    func testAPartialThatRevisesCommittedWordsIsNotWrittenUntilTheFinal() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        let before = h.host.document
        XCTAssertTrue(h.partial("Changed words at the very start. " + long).isEmpty)
        XCTAssertEqual(h.host.document, before)
    }

    func testYieldingAfterChunksLeavesTheCommittedTextAndTheFinalAddsOnlyTheRest() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        let committed = h.session.committed
        h.host.perform(h.session.yield(.yielded))
        XCTAssertEqual(h.host.document, "Hello " + committed)
        let final = long + " thing."
        let result = h.session.final(final, snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .insertPlain(String(final.dropFirst(committed.count))))
        h.host.insert(String(final.dropFirst(committed.count)))
        XCTAssertEqual(h.host.document, "Hello " + final)
    }

    func testYieldingAfterChunksWithADivergingFinalWithholdsIt() {
        let h = Harness(chunkThreshold: 120)
        h.reachLive(with: "This is sentence number 1.")
        let long = sentences(6).joined(separator: " ") + " And one more"
        h.partial(long)
        h.host.perform(h.session.yield(.yielded))
        let result = h.session.final("Totally different text.", snapshot: h.host.snapshot())
        XCTAssertEqual(result.outcome, .withheld(.committed))
    }
}
