import Foundation
import XCTest
@testable import KeyboardTypingKit

/// Process-wide language data, as `UITextChecker` behaves: any instance's lookups load it for every instance.
private final class FakeLanguageData: @unchecked Sendable {
    private let lock = NSLock()
    private var warm = false
    private var lookupsUntilWarm: Int
    private var created = 0

    init(lookupsUntilWarm: Int = 1) { self.lookupsUntilWarm = lookupsUntilWarm }

    var isWarm: Bool { lock.withLock { warm } }
    var instancesCreated: Int { lock.withLock { created } }
    func noteInstance() { lock.withLock { created += 1 } }
    func noteLookup() {
        lock.withLock {
            lookupsUntilWarm -= 1
            if lookupsUntilWarm <= 0 { warm = true }
        }
    }
}

/// The background checker. Not main-actor: the warm-up uses it off the main thread.
private final class FakeWarmer: TypingCheckerWarming {
    let data: FakeLanguageData
    init(data: FakeLanguageData) {
        self.data = data
        data.noteInstance()
    }
    var availableLanguages: [String] { ["en_US"] }
    func completions(forPartial partial: String, language: String) -> [String] {
        let answer = data.isWarm ? ["\(partial)ox"] : []
        data.noteLookup()
        return answer
    }
    func guesses(forWord word: String, language: String) -> [String] {
        data.noteLookup()
        return []
    }
}

/// The keyboard's checker: a cold one answers no completions, so autocorrect has no usage prior.
@MainActor
private final class ColdUntilWarmChecker: TypingSpellChecking {
    let data: FakeLanguageData
    init(data: FakeLanguageData) { self.data = data }
    var availableLanguages: [String] { ["en_US"] }
    func isMisspelled(_ word: String, language: String) -> Bool { word == "teh" }
    func completions(forPartial partial: String, language: String) -> [String] {
        guard data.isWarm else { return [] }
        return ["the", "that", "then"].filter { $0.hasPrefix(partial) }
    }
    func guesses(forWord word: String, language: String) -> [String] { word == "teh" ? ["the"] : [] }
    func ignore(_ word: String) {}
}

/// Holds the work in a queue the test drains by hand, and records which of it was for the main actor.
private final class ManualScheduler: TypingWarmupScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var background: [@Sendable () -> Void] = []
    private var main: [@MainActor @Sendable () -> Void] = []
    private var delays: [TimeInterval] = []
    private var onMainThread = false

    var scheduledDelays: [TimeInterval] { lock.withLock { delays } }
    var pendingBackground: Int { lock.withLock { background.count } }

    func runInBackground(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            delays.append(delay)
            background.append(work)
        }
    }

    func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { main.append(work) }
    }

    /// Runs the background work, then the main-actor hops it asked for, until nothing is left.
    /// `backgroundRanOnMainActor` is true when any background block ran on the main thread.
    @MainActor
    func drain(backgroundOffMain: Bool = false) async {
        while true {
            let next: (bg: (@Sendable () -> Void)?, ui: (@MainActor @Sendable () -> Void)?) = lock.withLock {
                if !background.isEmpty { return (background.removeFirst(), nil) }
                if !main.isEmpty { return (nil, main.removeFirst()) }
                return (nil, nil)
            }
            if let bg = next.bg {
                if backgroundOffMain {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().async {
                            bg()
                            done.resume()
                        }
                    }
                } else {
                    bg()
                }
            } else if let ui = next.ui {
                ui()
            } else {
                return
            }
        }
    }
}

@MainActor
final class TypingCheckerWarmupTests: XCTestCase {
    private var data = FakeLanguageData()
    private var scheduler = ManualScheduler()

    override func setUp() async throws {
        data = FakeLanguageData()
        scheduler = ManualScheduler()
    }

    private func makeWarmup(data: FakeLanguageData? = nil) -> TypingCheckerWarmup {
        let shared = data ?? self.data
        return TypingCheckerWarmup(makeWarmer: { FakeWarmer(data: shared) }, scheduler: scheduler)
    }

    private func firstWordCorrectsToThe(with warmup: TypingCheckerWarmup?, drain: Bool) async -> String {
        let document = FakeDocument()
        let checker = ColdUntilWarmChecker(data: data)
        let engine = TypingEngine(document: document, suggestionSource: FakeSuggestionSource(), now: { 0 })
        engine.completionHandler = TypingAutocorrector(
            checker: { checker },
            languageCandidates: { ["en-US"] },
            traits: { engine.state.traits },
            isEnabled: { true }
        )
        warmup?.start(languages: ["en-US"])
        if drain { await scheduler.drain() }
        "teh".forEach { engine.type(String($0)) }
        engine.tapSpace()
        return document.before
    }

    // The failure being guarded: a cold checker leaves the first typo alone.
    func testFirstTypoIsLeftAloneWhenNothingWarmedTheChecker() async {
        let result = await firstWordCorrectsToThe(with: nil, drain: false)
        XCTAssertEqual(result, "teh ")
    }

    func testFirstTypoCorrectsAfterTheAppearHookRan() async {
        let warmup = makeWarmup()
        let result = await firstWordCorrectsToThe(with: warmup, drain: true)
        XCTAssertEqual(result, "the ")
        XCTAssertEqual(warmup.state, .warm)
    }

    func testAppearingDoesNotWarmOnTheCallingThread() async {
        let warmup = makeWarmup()
        warmup.start(languages: ["en-US"])
        // Nothing has run yet: the work is queued for the scheduler, not done inline.
        XCTAssertEqual(data.instancesCreated, 0)
        XCTAssertFalse(data.isWarm)
        XCTAssertEqual(scheduler.pendingBackground, 1)
        XCTAssertEqual(warmup.state, .warming)
    }

    func testBackgroundWorkNeverRunsOnTheMainThread() async {
        let observed = ThreadProbe()
        let data = self.data
        let warmup = TypingCheckerWarmup(
            makeWarmer: { observed.note(); return FakeWarmer(data: data) },
            scheduler: scheduler
        )
        warmup.start(languages: ["en-US"])
        await scheduler.drain(backgroundOffMain: true)
        XCTAssertEqual(observed.mainThreadHits, 0)
        XCTAssertGreaterThan(observed.hits, 0)
    }

    func testDisappearingBeforeTheWorkRunsDoesNoLookups() async {
        let warmup = makeWarmup()
        warmup.start(languages: ["en-US"])
        warmup.cancel()
        await scheduler.drain()
        XCTAssertFalse(data.isWarm)
        XCTAssertEqual(data.instancesCreated, 0)
        XCTAssertEqual(warmup.state, .idle)
    }

    func testCancelDuringTheLookupsStopsThem() async {
        let warmer = CancellingWarmer()
        let warmup = TypingCheckerWarmup(makeWarmer: { warmer }, scheduler: scheduler)
        warmer.onFirstLookup = { MainActor.assumeIsolated { warmup.cancel() } }
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        XCTAssertEqual(warmer.lookups, 1, "the lookup in flight finishes, none after it")
        XCTAssertEqual(warmup.state, .idle)
    }

    func testMemoryReleaseCancelsAndForgetsAWarmChecker() async {
        let warmup = makeWarmup()
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        XCTAssertEqual(warmup.state, .warm)
        warmup.releaseMemory()
        XCTAssertEqual(warmup.state, .idle)
        warmup.start(languages: ["en-US"])
        XCTAssertEqual(warmup.state, .warming, "after a memory release the next appearance warms again")
    }

    func testAWarmCheckerIsKeptAcrossAppearances() async {
        let warmup = makeWarmup()
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        let created = data.instancesCreated
        warmup.cancel()
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        XCTAssertEqual(data.instancesCreated, created)
        XCTAssertEqual(warmup.state, .warm)
    }

    func testAppearingTwiceWhileWarmingQueuesOneJob() async {
        let warmup = makeWarmup()
        warmup.start(languages: ["en-US"])
        warmup.start(languages: ["en-US"])
        XCTAssertEqual(scheduler.pendingBackground, 1)
    }

    // The empty guard: retry once with a fresh checker, then stop.
    func testEmptyCompletionsRetryOnceThenStop() async {
        let stuckCold = FakeLanguageData(lookupsUntilWarm: Int.max)
        let warmup = makeWarmup(data: stuckCold)
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        XCTAssertEqual(warmup.state, .cold)
        XCTAssertEqual(stuckCold.instancesCreated, 2, "one first try and one retry with a fresh checker")
        XCTAssertEqual(scheduler.scheduledDelays.count, 2)
        XCTAssertEqual(scheduler.scheduledDelays.first, 0)
        XCTAssertGreaterThan(scheduler.scheduledDelays.last ?? 0, 0)
        XCTAssertEqual(scheduler.pendingBackground, 0, "it does not loop")
    }

    func testARetryThatFindsCompletionsEndsWarm() async {
        // Cold for the first pass over the 26 letters, warm by the retry.
        let warmsAfterOnePass = FakeLanguageData(lookupsUntilWarm: TypingCheckerWarmup.probeLetters.count)
        let warmup = makeWarmup(data: warmsAfterOnePass)
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        XCTAssertEqual(warmup.state, .warm)
        XCTAssertEqual(warmsAfterOnePass.instancesCreated, 2)
    }

    func testAnotherAppearanceAfterGivingUpMayTryAgain() async {
        let stuckCold = FakeLanguageData(lookupsUntilWarm: Int.max)
        let warmup = makeWarmup(data: stuckCold)
        warmup.start(languages: ["en-US"])
        await scheduler.drain()
        XCTAssertEqual(warmup.state, .cold)
        warmup.start(languages: ["en-US"])
        XCTAssertEqual(warmup.state, .warming)
    }

    func testNonEnglishIsWarmedButNeverCalledCold() async {
        let warmup = TypingCheckerWarmup(makeWarmer: { FakeWarmer(data: FakeLanguageData(lookupsUntilWarm: Int.max)) }, scheduler: scheduler)
        warmup.start(languages: ["fr-FR"])
        await scheduler.drain()
        XCTAssertEqual(warmup.state, .warm)
    }
}

final class TypingColdCheckerPolicyTests: XCTestCase {
    func testNoEmptyLettersIsWarm() {
        var policy = TypingColdCheckerPolicy()
        XCTAssertEqual(policy.verdict(emptyLetters: []), .warm)
    }

    func testFirstEmptyAnswerRetriesAndTheSecondGivesUp() {
        var policy = TypingColdCheckerPolicy(retryDelay: 0.5)
        XCTAssertEqual(policy.verdict(emptyLetters: ["a"]), .retry(after: 0.5))
        XCTAssertEqual(policy.verdict(emptyLetters: ["a"]), .cold)
        XCTAssertEqual(policy.verdict(emptyLetters: ["a"]), .cold, "never retries again")
    }

    func testARetryThatFindsEveryLetterIsWarm() {
        var policy = TypingColdCheckerPolicy()
        _ = policy.verdict(emptyLetters: ["a", "b"])
        XCTAssertEqual(policy.verdict(emptyLetters: []), .warm)
    }
}

private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var all = 0, main = 0
    var hits: Int { lock.withLock { all } }
    var mainThreadHits: Int { lock.withLock { main } }
    func note() {
        lock.withLock {
            all += 1
            if Thread.isMainThread { main += 1 }
        }
    }
}

private final class CancellingWarmer: TypingCheckerWarming, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var onFirstLookup: (@Sendable () -> Void)?
    var lookups: Int { lock.withLock { count } }
    var availableLanguages: [String] { ["en_US"] }
    func completions(forPartial partial: String, language: String) -> [String] {
        let first = lock.withLock { () -> Bool in count += 1; return count == 1 }
        if first { onFirstLookup?() }
        return ["x"]
    }
    func guesses(forWord word: String, language: String) -> [String] {
        lock.withLock { count += 1 }
        return []
    }
}
