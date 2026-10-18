import UIKit
import XCTest
@testable import Muesli

/// Live typing through the real `KeyboardController` and `KeyboardLiveTyper`, with a fake host field that models
/// marked text, the ways hosts differ, and a proxy that answers late. Row ids match the PR's failure matrix.
@MainActor
final class KeyboardLiveTypingTests: XCTestCase {
    private var d: LiveDictationDriver!

    override func tearDown() async throws {
        d?.tearDown()
        d = nil
        try await super.tearDown()
    }

    private func make(
        before: String = "",
        after: String = "",
        behavior: ModelMarkedHost.Behavior = .full,
        attachHost: Bool = true
    ) throws {
        d = try LiveDictationDriver(before: before, after: after, behavior: behavior, attachHost: attachHost)
    }

    private var phase: LiveTypingPhase? { d.controller.liveTyper.session?.phase }

    // MARK: A: the full sequence

    // A1: start, partials, a revision, stop, final replaces: the text equals the final exactly once.
    func testFullSequenceStartPartialsRevisionStopFinal() throws {
        try make()
        try d.startRecording()
        try d.hear("hello wor")
        XCTAssertEqual(d.document, "hello wor")
        XCTAssertEqual(d.host.markedLength, 9, "the words are not marked")
        try d.hear("hello world")
        try d.hear("hello word how")
        XCTAssertEqual(d.document, "hello word how", "a revised earlier word was not replaced")
        XCTAssertEqual(phase, .live)

        try d.stopAndTranscribe()
        try d.hear("hello world how are you")
        try d.finish("Hello world, how are you?")

        XCTAssertEqual(d.document, "Hello world, how are you?")
        XCTAssertEqual(d.host.markedLength, 0)
        XCTAssertFalse(d.host.writes.contains { $0.hasPrefix("insert(") }, "the final was also inserted as plain text")
        XCTAssertEqual(d.controller.dictationPhase, .idle)
        XCTAssertEqual(try d.store.keyboardHandoffState().phase, .inserted)
        XCTAssertEqual(d.controller.statusText, "Latest ready")
    }

    // A1b: the words sit in the field, so the strip does not show them a second time.
    func testTheStripStaysOutOfTheWayWhileTheWordsAreInTheField() throws {
        try make()
        try d.startRecording()
        try d.hear("hello wor")
        XCTAssertEqual(phase, .live)
        XCTAssertNil(d.controller.livePreview, "the words were shown in the strip and in the field")
    }

    // A1c: a host that cannot take live words keeps the strip, the only place they show.
    func testTheStripShowsWhenTheHostIgnoresMarkedText() throws {
        try make(behavior: .ignoresMarked)
        try d.startRecording()
        try d.hear("hello wor", settle: false)
        d.settleHost(seconds: 0.8)
        XCTAssertEqual(phase, .stripOnly(.noChange))
        XCTAssertNotNil(d.controller.livePreview)
    }

    // A1d: a host that writes its own text back (React Native style) loses nothing: the final is inserted once,
    // and the next dictation in that field goes straight to the strip.
    func testAHostThatRewritesItsFieldStillGetsTheFinalAndTheNextDictationUsesTheStrip() throws {
        try make(before: "Hi ")
        try d.startRecording()
        try d.hear("hello wor")
        XCTAssertEqual(phase, .live)
        d.host.model.hostRewritesItsText()
        d.settleHost()
        XCTAssertEqual(d.document, "Hi ")
        try d.stopAndTranscribe()
        try d.finish("Hello world")
        XCTAssertEqual(d.document, "Hi Hello world", "the dictation was lost, or typed twice")

        try d.startRecording()
        try d.hear("second try")
        XCTAssertEqual(phase, .stripOnly(.settingOff), "words were typed into a field that rewrites them")
    }

    // A2: the final replaces in one operation, with no empty text in between.
    func testTheFinalReplacesTheMarkedWordsInOneOperation() throws {
        try make(before: "Dear ")
        try d.startRecording()
        try d.hear("sam how")
        try d.stopAndTranscribe()
        try d.finish("Sam, how are you?")
        XCTAssertEqual(Array(d.host.writes.suffix(2)), ["setMarked(Sam, how are you?)", "unmark"])
        XCTAssertEqual(d.document, "Dear Sam, how are you?")
    }

    // A3: the final pass failed, so the result is the streaming text: it is unmarked, once.
    func testWhenTheFinalPassFailsTheStreamingTextStaysOnceAndIsUnmarked() throws {
        try make(before: "Note: ")
        try d.startRecording()
        try d.hear("buy milk and eggs")
        try d.stopAndTranscribe()
        try d.finish("buy milk and eggs")
        XCTAssertEqual(d.document, "Note: buy milk and eggs")
        XCTAssertEqual(d.host.markedLength, 0)
        XCTAssertEqual(d.host.writes.last, "unmark")
    }

    // A4: a second dictation starts clean.
    func testASecondDictationAfterTheFirstTypesLiveAgain() throws {
        try make()
        try d.startRecording()
        try d.hear("first")
        try d.stopAndTranscribe()
        try d.finish("First.")
        XCTAssertEqual(d.document, "First.")
        try d.startRecording()
        try d.hear(" second")
        XCTAssertEqual(d.document, "First.second", "partials are trimmed; the final decides the spacing")
        XCTAssertEqual(d.host.markedLength, 6)
        try d.stopAndTranscribe()
        try d.finish(" Second.")
        XCTAssertEqual(d.document, "First. Second.")
    }

    // MARK: B: ending without a final

    // B1: the user cancels (the X): the field is as it was, and late partials add nothing.
    func testCancelRemovesTheMarkedWordsAndLatePartialsAddNothing() throws {
        try make(before: "Hello ", after: " bye")
        try d.startRecording()
        try d.hear("do not keep this")
        XCTAssertEqual(d.document, "Hello do not keep this bye")
        d.controller.cancelActiveDictation()
        XCTAssertEqual(d.document, "Hello  bye")
        XCTAssertEqual(d.host.markedLength, 0)
        try d.hear("late words arriving after the cancel")
        XCTAssertEqual(d.document, "Hello  bye")
        try d.store.clearPendingCommand()
        try d.appWrites(.cancelled)
        XCTAssertEqual(d.document, "Hello  bye")
        XCTAssertNil(d.controller.livePreview)
    }

    // B2: the app cancels (Island, Stop-all): same.
    func testACancelFromTheAppRemovesTheWordsToo() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("gone soon")
        XCTAssertEqual(d.document, "Hello gone soon")
        try d.appWrites(.cancelled)
        XCTAssertEqual(d.document, "Hello ")
        XCTAssertEqual(d.host.markedLength, 0)
    }

    // B3: the dictation failed with no result: the words stay, as plain text.
    func testAFailedDictationKeepsTheWordsAsPlainText() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("keep these words")
        try d.appWrites(.failed)
        XCTAssertEqual(d.document, "Hello keep these words")
        XCTAssertEqual(d.host.markedLength, 0)
    }

    // B4: the result went to the clipboard (copy required): the words stay, nothing is inserted.
    func testACopyRequiredResultLeavesTheWordsAndInsertsNothing() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("on the clipboard")
        try d.store.saveResult(.init(requestID: d.requestID, text: "On the clipboard.", engineIdentifier: "test"))
        try d.appWrites(.copyRequired)
        XCTAssertEqual(d.document, "Hello on the clipboard")
        XCTAssertEqual(d.host.markedLength, 0)
        XCTAssertFalse(d.host.writes.contains { $0.hasPrefix("insert(") })
    }

    // B5: recovery (the app has to be opened to finish): the words come out so the later result is inserted as usual.
    func testARecoveryTakesTheWordsOutSoTheLaterResultIsInsertedOnce() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("not yet")
        XCTAssertEqual(d.document, "Hello not yet")
        try d.appWrites(.recoveryRequested)
        XCTAssertEqual(d.document, "Hello ")
        try d.store.saveResult(.init(requestID: d.requestID, text: "Finished later.", engineIdentifier: "test"))
        try d.store.saveKeyboardHandoffState(.init(requestID: d.requestID, phase: .resultReady))
        d.controller.prepareInitialPresentationState()
        XCTAssertEqual(d.document, "Hello Finished later.")
    }

    // MARK: C: hosts that cannot do it

    // C1 (P2): a host that ignores marked text: strip-only, final inserted once.
    func testAHostThatIgnoresMarkedTextFallsBackToTheStripAndInsertsTheFinalOnce() throws {
        try make(before: "Hello ", behavior: .ignoresMarked)
        try d.startRecording()
        try d.hear("hello")
        d.settleHost(seconds: 0.6)
        XCTAssertEqual(phase, .stripOnly(.noChange))
        XCTAssertEqual(d.document, "Hello ")
        XCTAssertNotNil(d.controller.livePreview, "the strip lost the words")
        try d.hear("hello world")
        XCTAssertEqual(d.document, "Hello ")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.document, "Hello Hello world.")
    }

    // C2 (P3): a host that inserts plain text for marked text is caught, cleaned up, and gets the final once.
    func testAHostThatAppendsMarkedTextAsPlainIsCleanedUp() throws {
        try make(before: "Hello ", behavior: .appendsAsPlain)
        try d.startRecording()
        try d.hear("hi", settle: false)
        d.settleHost(seconds: 0.6)
        XCTAssertEqual(phase, .stripOnly(.appended))
        XCTAssertEqual(d.document, "Hello ", "duplicated text left behind")
        try d.stopAndTranscribe()
        try d.finish("Hi there.")
        XCTAssertEqual(d.document, "Hello Hi there.")
    }

    // C3 (P4): a host that marks text but never shows it in the context.
    func testAHostThatHidesMarkedTextFromTheContextIsClearedAndGetsTheFinalOnce() throws {
        try make(before: "Hello ", behavior: .hidesMarkedFromContext)
        try d.startRecording()
        try d.hear("hello")
        d.settleHost(seconds: 0.6)
        XCTAssertEqual(phase, .stripOnly(.noChange))
        XCTAssertEqual(d.document, "Hello ", "the hidden marked text is still in the field")
        XCTAssertEqual(d.host.markedLength, 0)
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.document, "Hello Hello world.")
    }

    // C4 (P5): a host that moves the cursor.
    func testAHostThatPutsTheTextAfterTheCursorIsCleared() throws {
        try make(before: "Hello ", after: "there", behavior: .landsAfterCursor)
        try d.startRecording()
        try d.hear("hello")
        d.settleHost(seconds: 0.6)
        XCTAssertEqual(phase, .stripOnly(.notAtCursor))
        XCTAssertEqual(d.document, "Hello there")
        try d.stopAndTranscribe()
        try d.finish("Hi.")
        XCTAssertEqual(d.document, "Hello Hi.there")
    }

    // C5 (P6): a proxy that answers late is waited for, not given up on.
    func testAProxyThatAnswersLateStillGoesLive() throws {
        try make(before: "Hello ")
        d.host.model.lags = true
        d.host.model.flush()
        try d.startRecording()
        try d.hear("hello")
        XCTAssertEqual(phase, .live)
        try d.hear("hello world")
        XCTAssertEqual(d.document, "Hello hello world")
    }

    // C6 (P7, P8): a host that capitalizes or curls what it marks is still live.
    func testCapitalizationAndSmartQuotesByTheHostStillGoLive() throws {
        try make(before: "") // shown "Hello" for "hello"
        d.host.model.capitalizesFirstLetter = true
        d.host.model.smartQuotes = true
        try d.startRecording()
        try d.hear("don't stop")
        XCTAssertEqual(phase, .live)
        try d.stopAndTranscribe()
        try d.finish("Don't stop.")
        // The host curls the apostrophe in the final as well; the words are the same.
        XCTAssertEqual(LiveTypingText.folded(d.document), LiveTypingText.folded("Don't stop."))
        XCTAssertEqual(d.host.markedLength, 0)
    }

    // MARK: D: where the dictation starts

    // D1: a field with text after the cursor.
    func testTextAfterTheCursorStaysPutAndTheFinalGoesBeforeIt() throws {
        try make(before: "Dear ", after: " regards")
        try d.startRecording()
        try d.hear("sam")
        XCTAssertEqual(d.document, "Dear sam regards")
        try d.stopAndTranscribe()
        try d.finish("Sam,")
        XCTAssertEqual(d.document, "Dear Sam, regards")
        XCTAssertEqual(d.host.model.after, " regards")
    }

    // D2 (L3): a selection at the start: live typing stays off, the final replaces the selection as today.
    func testASelectionAtTheStartKeepsLiveTypingOffAndTheFinalReplacesIt() throws {
        try make(before: "Replace this")
        d.host.model.userSelects(4)
        try d.startRecording()
        try d.hear("that")
        XCTAssertEqual(phase, .stripOnly(.selection))
        XCTAssertEqual(d.document, "Replace this", "the selection was replaced before the final")
        try d.stopAndTranscribe()
        try d.finish("that.")
        XCTAssertEqual(d.document, "Replace that.")
    }

    // D3 (P9): right-to-left text, emoji and combining marks.
    func testRightToLeftEmojiAndCombiningMarksGoThroughTheWholeSequence() throws {
        for words in ["שלום עולם", "مرحبا بالعالم", "ok 👩\u{200D}👩\u{200D}👧 cafe\u{301}"] {
            try make(before: "")
            try d.startRecording()
            try d.hear(words)
            XCTAssertEqual(d.document, words)
            XCTAssertEqual(phase, .live, words)
            try d.stopAndTranscribe()
            try d.finish(words + ".")
            XCTAssertEqual(d.document, words + ".", words)
            d.tearDown()
        }
    }

    // D4: a partial that gets shorter.
    func testAPartialThatGetsShorterReplacesTheWholeRange() throws {
        try make(before: "Hi ")
        try d.startRecording()
        try d.hear("the quick brown fox")
        try d.hear("a quick")
        XCTAssertEqual(d.document, "Hi a quick")
        try d.hear("")
        XCTAssertEqual(d.document, "Hi a quick", "an empty partial erased the words")
    }

    // MARK: E: the user and the host act during a dictation

    // E1 (D1 in the PR): the user taps elsewhere: the words stay as text and the final is not typed a second time.
    func testTappingElsewhereKeepsTheWordsAndNeverDuplicatesTheFinal() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("hello world")
        d.host.model.userMovesCursor(toOffsetFromEnd: 5)
        d.settleHost(seconds: 0.6)
        guard case .kept = phase else { return XCTFail("still live: \(String(describing: phase))") }
        XCTAssertEqual(d.host.markedLength, 0)
        let kept = d.document
        try d.hear("hello world and more")
        XCTAssertEqual(d.document, kept)
        try d.stopAndTranscribe()
        try d.finish("Hello world and more.")
        XCTAssertEqual(d.document, kept, "the final was inserted at the new cursor next to the kept words")
        XCTAssertEqual(d.controller.statusText, KeyboardController.keptWordsMessage)
        XCTAssertEqual(try d.store.keyboardHandoffState().phase, .inserted)
        XCTAssertEqual(d.controller.dictationPhase, .idle)
    }

    // E2: another field gets focus.
    func testAnotherFieldKeepsTheWordsAndWithholdsTheFinal() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("first field")
        d.host.model.userSwitchesField()
        d.settleHost(seconds: 0.6)
        guard case .kept(.fieldChanged) = phase else { return XCTFail("\(String(describing: phase))") }
        try d.stopAndTranscribe()
        try d.finish("First field.")
        XCTAssertEqual(d.document, "", "the final was typed into the other field")
    }

    // E3: the user types a key during the dictation: the words come out, the key stays, the final comes after it.
    func testTypingAKeyDuringTheDictationNeverEatsEitherText() throws {
        try make(before: "")
        try d.startRecording()
        try d.hear("hello wor")
        d.controller.typing.perform(.character("x"))
        XCTAssertEqual(d.document, "x", "the typed key or the dictated words were eaten")
        XCTAssertEqual(phase, .stripOnly(.yielded))
        try d.hear("hello world")
        XCTAssertEqual(d.document, "x")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.document, "xHello world.")
    }

    // E4: space and return behave the same way. Backspace does not end the dictation (E4b).
    func testSpaceAndReturnDuringTheDictationAlsoYield() throws {
        let keys: [(String, TypingKeyAction, String)] = [
            ("space", .space, "Note "),
            ("return", .returnKey, "Note\n"),
        ]
        for (name, key, expected) in keys {
            try make(before: "Note")
            try d.startRecording()
            try d.hear("dictated words")
            XCTAssertEqual(d.document, "Note" + "dictated words", name)
            d.controller.typing.perform(key)
            XCTAssertEqual(d.document, expected, name)
            try d.stopAndTranscribe()
            try d.finish("Final.")
            XCTAssertEqual(d.document, expected + "Final.", name)
            d.tearDown()
        }
    }

    // E4b: backspace takes back the last dictated word and the dictation goes on, like iOS dictation.
    func testBackspaceDuringTheDictationTakesBackTheLastWordAndKeepsDictating() throws {
        try make(before: "Note: ")
        try d.startRecording()
        try d.hear("buy milk and eggs")
        d.controller.typing.perform(.backspace)
        XCTAssertEqual(d.document, "Note: buy milk and")
        XCTAssertEqual(phase, .live)
        try d.hear("buy milk and eggs or bread")
        XCTAssertEqual(d.document, "Note: buy milk and or bread", "the deleted word came back")
        try d.stopAndTranscribe()
        try d.finish("Buy milk and eggs or bread.")
        XCTAssertEqual(d.document, "Note: buy milk and or bread.")
        XCTAssertEqual(d.host.markedLength, 0)
    }

    // E4c: with no dictated word left to take back, backspace edits the field as it always did.
    func testBackspaceWithNoDictatedWordLeftEditsTheField() throws {
        try make(before: "Note: ")
        try d.startRecording()
        try d.hear("buy")
        d.controller.typing.perform(.backspace)
        XCTAssertEqual(d.document, "Note: ")
        d.controller.typing.perform(.backspace)
        XCTAssertEqual(d.document, "Note:")
    }

    // E5: the keyboard's other edits (a Quill undo, an explicit clear) yield too.
    func testClearingTheLastInsertionDuringALiveDictationKeepsTheDictatedWordsOut() throws {
        try make(before: "Keep")
        try d.startRecording()
        try d.hear("dictated")
        d.controller.clearInsertedText()
        XCTAssertEqual(d.document, "Kee")
        XCTAssertEqual(phase, .stripOnly(.yielded))
    }

    // E6: an older result is delivered while a newer dictation is live: its words come out first, then it goes in.
    func testAnOlderQueuedDeliveryYieldsTheLiveWords() throws {
        try make(before: "")
        let old = DictationRequest()
        try d.store.claimRequest(old)
        try d.store.saveKeyboardHandoffState(.init(requestID: old.id, phase: .recordingStarted))
        try d.store.saveResult(.init(requestID: old.id, text: "Old speech", engineIdentifier: "test"))
        try d.store.saveKeyboardHandoffState(.init(requestID: old.id, phase: .resultReady))
        let next = DictationRequest(sourceBundleIdentifier: "muesli.keyboard")
        try d.store.claimRequest(next)
        try d.store.saveKeyboardHandoffState(.init(requestID: next.id, phase: .recordingStarted))
        try d.store.saveKeyboardRuntimeStatus(.init(
            isActive: true, activeRequestID: next.id, phase: .recording, supportsBackgroundStart: true, inputLevel: 0.3
        ))
        try d.store.saveKeyboardLiveTranscript(.init(requestID: next.id, text: "newer words", isFinal: false))
        d.controller.prepareInitialPresentationState()
        XCTAssertEqual(d.document, "Old speech", "the live words and the older result were not both handled")
        XCTAssertEqual(d.host.markedLength, 0)
        XCTAssertEqual(phase, .stripOnly(.yielded))
    }

    // E7: the keyboard goes away mid-dictation: the words come out; a recreated keyboard inserts the result once.
    func testHidingTheKeyboardRemovesTheMarkedWordsAndARecreatedKeyboardInsertsOnce() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("half a sentence")
        XCTAssertEqual(d.document, "Hello half a sentence")
        XCTAssertGreaterThan(d.host.markedLength, 0)
        d.controller.stopObservingSharedState()
        XCTAssertEqual(d.document, "Hello ")
        XCTAssertEqual(d.host.markedLength, 0, "marked text left dangling")

        try d.stopAndTranscribe()
        try d.store.saveResult(.init(requestID: d.requestID, text: "Half a sentence.", engineIdentifier: "test"))
        try d.store.saveKeyboardHandoffState(.init(requestID: d.requestID, phase: .resultReady))
        let rebuilt = KeyboardController(store: d.store, eventBus: d.bus, liveTypingScheduler: d.clock.scheduler)
        d.host.attach(to: rebuilt)
        rebuilt.prepareInitialPresentationState()
        rebuilt.prepareInitialPresentationState()
        XCTAssertEqual(d.document, "Hello Half a sentence.")
    }

    // MARK: F: switches

    // F1 (S5): the setting off is today's behavior exactly.
    func testWithTheSettingOffThePreviewIsOnlyInTheStripAndTheFinalIsInsertedOnce() throws {
        try make(before: "Hello ")
        try d.store.saveKeyboardTypingSettings(KeyboardTypingSettings(autocorrect: true, liveTyping: false))
        d.controller.loadTypingSettings()
        try d.startRecording()
        try d.hear("hello wor")
        try d.hear("hello world")
        XCTAssertEqual(d.document, "Hello ")
        XCTAssertEqual(d.controller.livePreview?.text, "hello world")
        XCTAssertTrue(d.host.writes.isEmpty, "\(d.host.writes)")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.document, "Hello Hello world.")
        XCTAssertEqual(d.host.writes, ["insert(Hello world.)"])
    }

    // F2: no live host at all (nil closures) is the same.
    func testWithoutALiveHostTheBehaviorIsToday() throws {
        try make(before: "Hello ", attachHost: false)
        var inserted: [String] = []
        d.controller.textInserter = { inserted.append($0) }
        try d.startRecording()
        try d.hear("hello world")
        XCTAssertNil(d.controller.liveTyper.session)
        XCTAssertEqual(d.controller.livePreview?.text, "hello world")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(inserted, ["Hello world."])
    }

    // F3: a voice edit (Quill) is not typed live.
    func testAVoiceEditIsNotTypedLive() throws {
        try make(before: "Fix this sentence please")
        d.host.model.userSelects(8)
        d.controller.prepareInitialPresentationState()
        let status = KeyboardRuntimeStatus(isActive: true, supportsBackgroundStart: true, rewriteAvailable: true)
        try d.store.saveKeyboardRuntimeStatus(status)
        d.controller.prepareInitialPresentationState()
        d.controller.startRewrite()
        d.requestID = try XCTUnwrap(try d.store.pendingCommand()?.requestID)
        try d.appWrites(.recordingStarted)
        try d.hear("make it formal")
        XCTAssertEqual(phase, .stripOnly(.rewrite))
        XCTAssertEqual(d.document, "Fix this sentence please")
        XCTAssertEqual(d.host.markedLength, 0)
    }

    // F4 (S4): the switch travels through the shared store.
    func testTheSwitchTravelsThroughTheSharedStore() throws {
        try make()
        XCTAssertTrue(d.controller.liveTyper.isEnabled)
        try d.store.saveKeyboardTypingSettings(KeyboardTypingSettings(autocorrect: true, liveTyping: false))
        XCTAssertEqual(try d.store.keyboardTypingSettings()?.liveTyping, false)
        d.controller.loadTypingSettings()
        XCTAssertFalse(d.controller.liveTyper.isEnabled)
        try d.store.saveKeyboardTypingSettings(KeyboardTypingSettings(autocorrect: true, liveTyping: true))
        d.controller.loadTypingSettings()
        XCTAssertTrue(d.controller.liveTyper.isEnabled)
    }

    // MARK: G: updates

    // G1 (U4): ten updates a second are written at most about six times a second, latest last, in order.
    func testBurstsOfPartialsAreCoalescedAndNeverReordered() throws {
        try make()
        try d.startRecording()
        try d.hear("one", settle: true)
        let before = d.host.markedWrites.count
        var spoken = "one"
        for word in ["two", "three", "four", "five", "six", "seven", "eight"] {
            spoken += " " + word
            try d.hear(spoken, settle: false)
            d.clock.advance(0.03)
        }
        XCTAssertLessThanOrEqual(d.host.markedWrites.count - before, 3, "\(d.host.markedWrites)")
        d.settleHost()
        XCTAssertEqual(d.document, spoken)
        let lengths = d.host.markedWrites.map(\.count)
        XCTAssertEqual(lengths, lengths.sorted(), "an older partial overwrote a newer one")
    }

    // G2 (U5): an update older than one already applied is ignored.
    func testAnOlderUpdateIsIgnored() throws {
        try make()
        try d.startRecording()
        let now = Date()
        try d.store.saveKeyboardLiveTranscript(.init(requestID: d.requestID, text: "newer words", isFinal: false, updatedAt: now))
        d.controller.prepareInitialPresentationState()
        d.settleHost()
        try d.store.saveKeyboardLiveTranscript(.init(requestID: d.requestID, text: "old", isFinal: false, updatedAt: now.addingTimeInterval(-1)))
        d.controller.prepareInitialPresentationState()
        d.settleHost()
        XCTAssertEqual(d.document, "newer words")
    }

    // MARK: H: a very long dictation

    func testAVeryLongDictationCommitsSentencesAndKeepsTheMarkedRangeShort() throws {
        try make(before: "")
        try d.startRecording()
        var spoken = ""
        var number = 1
        while spoken.count < LiveTypingText.chunkThreshold + 600 {
            spoken += (spoken.isEmpty ? "" : " ") + "This is sentence number \(number) of a long dictation."
            number += 1
            try d.hear(spoken)
        }
        XCTAssertEqual(phase, .live)
        XCTAssertEqual(d.document, spoken)
        XCTAssertLessThan(d.host.markedLength, LiveTypingText.chunkThreshold, "the marked range kept growing")
        try d.stopAndTranscribe()
        let final = spoken + " And that is all."
        try d.finish(final)
        XCTAssertEqual(d.document, final)
        XCTAssertEqual(d.host.markedLength, 0)
    }

    // MARK: I: bookkeeping and the typing engine

    // I1: Clear after a live-typed dictation removes exactly what was dictated; one backspace removes one character.
    func testUndoBookkeepingAfterALiveFinalMatchesAPlainInsert() throws {
        try make(before: "Hello ")
        try d.startRecording()
        try d.hear("hello world")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        XCTAssertEqual(d.document, "Hello Hello world.")
        d.controller.clearInsertedText()
        XCTAssertEqual(d.document, "Hello ", "clear removed a different number of characters than the dictation added")
    }

    func testOneBackspaceAfterALiveFinalRemovesOneCharacter() throws {
        try make(before: "")
        try d.startRecording()
        try d.hear("hello world")
        try d.stopAndTranscribe()
        try d.finish("Hello world.")
        d.controller.typing.perform(.backspace)
        XCTAssertEqual(d.document, "Hello world")
    }

    // I2 (B3, B4): a misspelling in dictated text is not corrected by the next space, live or committed.
    func testDictatedTextIsNeverAutocorrectedByTheNextKey() throws {
        try make(before: "")
        try d.startRecording()
        try d.hear("recieve teh adn")
        try d.stopAndTranscribe()
        try d.finish("Recieve teh adn")
        d.controller.typing.perform(.space)
        XCTAssertEqual(d.document, "Recieve teh adn ")
        d.controller.typing.perform(.character("."))
        XCTAssertEqual(d.document, "Recieve teh adn .")
    }

    // MARK: J: the proxy adapter

    func testTheProxyAdapterForwardsMarkedTextWithAUTF16Range() {
        final class Proxy: NSObject, UITextDocumentProxy {
            var marked: [(String, NSRange)] = []
            var unmarked = 0
            var documentContextBeforeInput: String? = "before"
            var documentContextAfterInput: String? = nil
            var selectedText: String? = nil
            var documentInputMode: UITextInputMode? { nil }
            var documentIdentifier: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000042")! }
            var hasText: Bool { true }
            func adjustTextPosition(byCharacterOffset offset: Int) {}
            func setMarkedText(_ markedText: String, selectedRange: NSRange) { marked.append((markedText, selectedRange)) }
            func unmarkText() { unmarked += 1 }
            func insertText(_ text: String) {}
            func deleteBackward() {}
        }
        let proxy = Proxy()
        let host = ProxyLiveTypingHost { proxy }
        host.setMarkedText("👩\u{200D}👩\u{200D}👧")
        host.unmarkText()
        XCTAssertEqual(proxy.marked.first?.1, NSRange(location: 8, length: 0))
        XCTAssertEqual(proxy.unmarked, 1)
        let snapshot = host.snapshot()
        XCTAssertEqual(snapshot.before, "before")
        XCTAssertEqual(snapshot.after, "")
        XCTAssertEqual(snapshot.documentID, UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
    }
}
