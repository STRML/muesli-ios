import XCTest
@testable import KeyboardTypingKit

/// Matrix rows L1-L9: what autocorrect remembers about the user's words, and that it survives a relaunch.
@MainActor
final class TypingLearnedWordsTests: XCTestCase {
    // L1
    func testARejectedWordIsRememberedIgnoringCase() {
        var words = TypingLearnedWords()
        words.reject("Teh")
        XCTAssertTrue(words.isRejected("teh"))
        XCTAssertFalse(words.isRejected("the"))
    }

    // L2: the list is capped, oldest dropped first.
    func testTheRejectedListIsCapped() {
        var words = TypingLearnedWords()
        for index in 0..<(TypingLearnedWords.maximumRejected + 25) { words.reject("word\(index)") }
        XCTAssertEqual(words.rejected.count, TypingLearnedWords.maximumRejected)
        XCTAssertFalse(words.isRejected("word0"))
        XCTAssertTrue(words.isRejected("word\(TypingLearnedWords.maximumRejected + 24)"))
    }

    func testRejectingAWordAgainMovesItToTheNewestEnd() {
        var words = TypingLearnedWords()
        words.reject("alpha")
        words.reject("beta")
        words.reject("alpha")
        XCTAssertEqual(words.rejected, ["beta", "alpha"])
    }

    // L3: the third time a flagged word is typed and left, it is learned.
    func testAWordTypedThreeTimesAsItIsGetsLearnedOnTheThird() {
        var words = TypingLearnedWords()
        XCTAssertFalse(words.noteLeftAsTyped("kubectl"))
        XCTAssertFalse(words.noteLeftAsTyped("Kubectl"))
        XCTAssertTrue(words.noteLeftAsTyped("kubectl"))
        XCTAssertTrue(words.isLearned("kubectl"))
    }

    func testDifferentWordsDoNotShareACount() {
        var words = TypingLearnedWords()
        XCTAssertFalse(words.noteLeftAsTyped("alpha"))
        XCTAssertFalse(words.noteLeftAsTyped("beta"))
        XCTAssertFalse(words.noteLeftAsTyped("alpha"))
        XCTAssertFalse(words.isLearned("alpha"))
    }

    // L4: a word the user took back is never learned from being left alone.
    func testARejectedWordIsNeverLearned() {
        var words = TypingLearnedWords()
        words.reject("teh")
        for _ in 0..<5 { XCTAssertFalse(words.noteLeftAsTyped("teh")) }
        XCTAssertFalse(words.isLearned("teh"))
    }

    // L5
    func testTheSeenListIsCapped() {
        var words = TypingLearnedWords()
        for index in 0..<(TypingLearnedWords.maximumSeen + 40) { _ = words.noteLeftAsTyped("w\(index)") }
        XCTAssertEqual(words.seen.count, TypingLearnedWords.maximumSeen)
    }

    // L6: relaunch. A new store object over the same defaults sees what the old one saved.
    func testWordsSurviveANewKeyboardLaunch() {
        let defaults = UserDefaults(suiteName: "TypingLearnedWordsTests-\(UUID().uuidString)")!
        var words = TypingLearnedWords()
        words.reject("teh")
        _ = words.noteLeftAsTyped("kubectl")
        TypingLearnedWordsDefaults(defaults: defaults).save(words)
        let reloaded = TypingLearnedWordsDefaults(defaults: defaults).load()
        XCTAssertEqual(reloaded, words)
        XCTAssertTrue(reloaded.isRejected("teh"))
        XCTAssertEqual(reloaded.seen, [TypingLearnedWords.Seen(word: "kubectl", count: 1)])
    }

    // L7
    func testNothingSavedLoadsEmptyAndGarbageLoadsEmpty() {
        let defaults = UserDefaults(suiteName: "TypingLearnedWordsTests-\(UUID().uuidString)")!
        XCTAssertEqual(TypingLearnedWordsDefaults(defaults: defaults).load(), TypingLearnedWords())
        defaults.set(Data("not json".utf8), forKey: "muesli.keyboard.learnedWords")
        XCTAssertEqual(TypingLearnedWordsDefaults(defaults: defaults).load(), TypingLearnedWords())
    }
}
