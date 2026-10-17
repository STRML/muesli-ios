import Foundation

/// The slice of `UITextChecker` the warm-up uses. Not main-actor: the warm-up runs on a background queue, with a
/// checker of its own that no other thread touches. `UITextChecker` loads its language data once per process, so
/// lookups through this instance warm the checker the keyboard types with.
protocol TypingCheckerWarming: AnyObject {
    var availableLanguages: [String] { get }
    func completions(forPartial partial: String, language: String) -> [String]
    func guesses(forWord word: String, language: String) -> [String]
}

/// Where the warm-up runs. The keyboard uses a utility-priority queue; tests drain a queue by hand.
protocol TypingWarmupScheduler: Sendable {
    /// Run `work` off the main thread, after `delay` seconds.
    func runInBackground(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
    /// Hop back to the main actor.
    func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void)
}

final class DispatchWarmupScheduler: TypingWarmupScheduler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "muesli.keyboard.checker-warmup", qos: .utility)

    func runInBackground(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        if delay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func runOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

/// What to make of the first-letter completions a warm-up got back. A warm English checker has completions for
/// every letter; none for a letter means the language data is not loaded yet, and autocorrect (which needs
/// completions for its usage prior) would leave every typo alone. Pure, so the policy is tested on the Mac.
struct TypingColdCheckerPolicy: Equatable {
    enum Verdict: Equatable {
        case warm
        /// Make a fresh checker and look again after this many seconds.
        case retry(after: TimeInterval)
        /// Gave up. Nothing retries again until the keyboard next appears.
        case cold
    }

    let retryDelay: TimeInterval
    let maximumRetries: Int
    private(set) var retries = 0

    init(retryDelay: TimeInterval = 0.5, maximumRetries: Int = 1) {
        self.retryDelay = retryDelay
        self.maximumRetries = maximumRetries
    }

    mutating func verdict(emptyLetters: [String]) -> Verdict {
        guard !emptyLetters.isEmpty else { return .warm }
        guard retries < maximumRetries else { return .cold }
        retries += 1
        return .retry(after: retryDelay)
    }
}

/// Loads the spell checker's language data in the background when the keyboard appears, so the first words typed
/// are corrected as the later ones are. The keyboard is a new process on each appearance and a cold `UITextChecker`
/// answers no completions for the first few lookups, which is all the autocorrect rule needs to decline.
///
/// It does no more than it must: 26 single-letter completions and a short list of common typos through `guesses`,
/// once per process. It never blocks the main actor, stops at the next lookup when cancelled, and a result that
/// arrives after a cancel is dropped.
@MainActor
final class TypingCheckerWarmup {
    enum State: Equatable {
        case idle
        case warming
        case warm
        /// The completions stayed empty after the one retry.
        case cold
    }

    nonisolated static let probeLetters: [String] = "abcdefghijklmnopqrstuvwxyz".map(String.init)
    /// Common short typos: the words a first message is most likely to contain.
    nonisolated static let probeTypos = [
        "teh", "adn", "wiht", "thier", "wich", "hte", "taht", "yuo", "dont", "cant", "recieve", "becuase"
    ]

    private(set) var state = State.idle
    private let makeWarmer: @Sendable () -> TypingCheckerWarming
    private let scheduler: TypingWarmupScheduler
    private var policy: TypingColdCheckerPolicy
    private var token = CancelToken()

    init(
        makeWarmer: @escaping @Sendable () -> TypingCheckerWarming,
        scheduler: TypingWarmupScheduler,
        policy: TypingColdCheckerPolicy = TypingColdCheckerPolicy()
    ) {
        self.makeWarmer = makeWarmer
        self.scheduler = scheduler
        self.policy = policy
    }

    /// The keyboard appeared. A warm checker and a warm-up already under way are left alone.
    func start(languages: [String]) {
        guard state == .idle || state == .cold else { return }
        state = .warming
        policy = TypingColdCheckerPolicy(retryDelay: policy.retryDelay, maximumRetries: policy.maximumRetries)
        token = CancelToken()
        schedule(languages: languages, token: token, delay: 0)
    }

    /// The keyboard went away. Work in flight stops at its next lookup; a warm checker stays warm.
    func cancel() {
        token.cancel()
        if state == .warming { state = .idle }
    }

    /// Memory is tight: stop, and warm again on the next appearance.
    func releaseMemory() {
        token.cancel()
        state = .idle
    }

    private func schedule(languages: [String], token: CancelToken, delay: TimeInterval) {
        let makeWarmer = makeWarmer
        let scheduler = scheduler
        scheduler.runInBackground(after: delay) {
            guard !token.isCancelled else { return }
            let emptyLetters = TypingCheckerWarmup.lookups(using: makeWarmer(), languages: languages, token: token)
            scheduler.runOnMain { [weak self] in
                self?.finish(emptyLetters: emptyLetters, languages: languages, token: token)
            }
        }
    }

    /// The first-letter completions that came back empty, or nil when cancelled part way.
    nonisolated private static func lookups(
        using warmer: TypingCheckerWarming, languages: [String], token: CancelToken
    ) -> [String]? {
        guard let language = TypingLanguageResolver.resolve(candidates: languages, available: warmer.availableLanguages)
        else { return [] }
        // Only English is known to have completions for every letter.
        let guarded = TypingLanguageResolver.baseCode(of: language) == "en"
        var empty: [String] = []
        for letter in probeLetters {
            guard !token.isCancelled else { return nil }
            if warmer.completions(forPartial: letter, language: language).isEmpty, guarded { empty.append(letter) }
        }
        for word in probeTypos {
            guard !token.isCancelled else { return nil }
            _ = warmer.guesses(forWord: word, language: language)
        }
        return empty
    }

    private func finish(emptyLetters: [String]?, languages: [String], token: CancelToken) {
        guard !token.isCancelled, token === self.token, let emptyLetters else { return }
        switch policy.verdict(emptyLetters: emptyLetters) {
        case .warm: state = .warm
        case .cold: state = .cold
        case .retry(let delay): schedule(languages: languages, token: token, delay: delay)
        }
    }
}

private final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
