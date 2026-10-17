import Foundation
#if canImport(KeyboardTypingKit)
@testable import KeyboardTypingKit
#else
@testable import Muesli
#endif

/// A host text field for the corpus run: just text before the cursor.
@MainActor
final class CorpusDocument: TypingDocument {
    var before = ""
    var identifier: UUID? = UUID()
    var documentIdentifier: UUID? { identifier }
    var contextBefore: String? { before.isEmpty ? nil : before }
    var contextAfter: String? { nil }
    var selectedText: String? { nil }
    func insert(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
}

/// Times each `wordCompleted` call, which is the whole cost of deciding on a finished word.
@MainActor
final class TimedCompletionHandler: TypingWordCompletionHandling {
    private let inner: TypingWordCompletionHandling
    private(set) var seconds: [Double] = []

    init(_ inner: TypingWordCompletionHandling) { self.inner = inner }

    func wordCompleted(_ event: TypingWordCompletedEvent) -> TypingEditPlan? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { seconds.append(ProcessInfo.processInfo.systemUptime - start) }
        return inner.wordCompleted(event)
    }

    func replacementWasRejected(_ undo: TypingReplacementUndo) { inner.replacementWasRejected(undo) }
}

/// Runs text through the real stack: a `TypingEngine` fed one key at a time and the real `TypingAutocorrector`,
/// with whatever checker the caller supplies (the real `UITextChecker` in the simulator, a fake on the host).
@MainActor
final class CorpusRunner {
    let builder: TypingSuggestionBuilder
    let autocorrector: TypingAutocorrector
    let timer: TimedCompletionHandler
    let language: String
    private var engine: TypingEngine?
    /// What the next `run` uses as the document identifier; nil is the path a host with no document gives.
    var documentIdentifier: UUID? = UUID()

    init(
        language: String = "en-US",
        tuning: TypingAutocorrectTuning = .standard,
        poolOptions: TypingCandidatePool.Options = .init(),
        learnedWords: TypingLearnedWordsStoring? = nil,
        learnWord: @escaping (String) -> Void = { _ in },
        makeChecker: @escaping () -> TypingSpellChecking
    ) {
        self.language = language
        let builder = TypingSuggestionBuilder(makeChecker: makeChecker, languageCandidates: { [language] in [language] })
        self.builder = builder
        let corrector = TypingAutocorrector(
            checker: { builder.currentChecker() },
            languageCandidates: { [language] in [language] },
            traits: { TypingTraits() },
            isEnabled: { true },
            ignoreWord: { builder.ignore($0) },
            tuning: tuning,
            poolOptions: poolOptions,
            learnedWords: learnedWords,
            learnWord: learnWord
        )
        autocorrector = corrector
        timer = TimedCompletionHandler(corrector)
    }

    /// Types `token` after `prefix`, one key at a time, then the boundary. Returns what the field holds from the
    /// end of `prefix` on.
    func run(prefix: String, token: String, boundary: String) -> String {
        let document = CorpusDocument()
        document.identifier = documentIdentifier
        document.before = prefix
        let engine = TypingEngine(document: document, suggestionSource: builder, now: { 0 })
        engine.completionHandler = timer
        engine.documentDidChange()
        self.engine = engine
        for character in token {
            // The space and return keys have their own taps, as on the keyboard.
            switch character {
            case " ": engine.tapSpace()
            case "\n": engine.tapReturn()
            default: engine.type(String(character))
            }
        }
        switch boundary {
        case " ": engine.tapSpace()
        case "\n": engine.tapReturn()
        default: engine.type(boundary)
        }
        return String(document.before.dropFirst(prefix.count))
    }

    /// The checker the autocorrector is using, for questions about it that the field cannot answer.
    var checker: TypingSpellChecking { builder.currentChecker() }
}

// MARK: Trials and the report

enum CorpusVerdict: String, Sendable {
    case corrected, wrong, unchanged
}

/// How far a miss got, so each change can be tied to the stage it fixes.
enum CorpusMissStage: String, CaseIterable, Sendable {
    /// The checker's guesses do not contain the intended word at all.
    case notInGuesses = "intended word not in guesses"
    /// It is in the guesses, but not first.
    case rankedLower = "in guesses, not first"
    /// It is the checker's first guess and the rule still did not take it.
    case declined = "first guess, rule declined"
}

struct CorpusTrial: Sendable {
    let typed: String
    let intended: String
    let kind: String
    let length: Int
    let isTuning: Bool
    var isTail = false
    /// What the field held after the space.
    let result: String
    /// Position of the intended word in the checker's guesses, or nil.
    let guessPosition: Int?

    var verdict: CorpusVerdict {
        if result == intended + " " { return .corrected }
        return result == typed + " " ? .unchanged : .wrong
    }

    var missStage: CorpusMissStage? {
        guard verdict != .corrected else { return nil }
        guard let guessPosition else { return .notInGuesses }
        return guessPosition == 0 ? .declined : .rankedLower
    }
}

enum CorpusLength {
    static let buckets: [(name: String, range: ClosedRange<Int>)] = [
        ("3", 3...3), ("4", 4...4), ("5-6", 5...6), ("7-8", 7...8), ("9+", 9...99),
    ]
}

struct CorpusRate: Sendable {
    let corrected: Int
    let wrong: Int
    let unchanged: Int
    var total: Int { corrected + wrong + unchanged }
    var correctedRate: Double { total == 0 ? 0 : Double(corrected) / Double(total) }
    var wrongRate: Double { total == 0 ? 0 : Double(wrong) / Double(total) }

    init(_ trials: [CorpusTrial]) {
        corrected = trials.filter { $0.verdict == .corrected }.count
        wrong = trials.filter { $0.verdict == .wrong }.count
        unchanged = trials.filter { $0.verdict == .unchanged }.count
    }

    var text: String {
        String(format: "%5d  corrected %5.1f%%  wrong %4.1f%%  left %5.1f%%", total, correctedRate * 100, wrongRate * 100,
               total == 0 ? 0 : Double(unchanged) / Double(total) * 100)
    }
}

enum CorpusReport {
    /// The classes the 90 percent target covers: a single slip of the thumb.
    static let singleSlipClasses: Set<String> = ["neighbour", "drop", "double", "transposition"]

    static func byClassAndLength(_ trials: [CorpusTrial]) -> [String] {
        var lines: [String] = []
        let kinds = Array(Set(trials.map(\.kind))).sorted()
        for kind in kinds {
            let ofKind = trials.filter { $0.kind == kind }
            lines.append("  \(kind.padding(toLength: 14, withPad: " ", startingAt: 0)) all  " + CorpusRate(ofKind).text)
            for bucket in CorpusLength.buckets {
                let inBucket = ofKind.filter { bucket.range.contains($0.length) }
                guard !inBucket.isEmpty else { continue }
                lines.append("  \("".padding(toLength: 14, withPad: " ", startingAt: 0)) \(bucket.name.padding(toLength: 3, withPad: " ", startingAt: 0))  " + CorpusRate(inBucket).text)
            }
        }
        return lines
    }

    static func missStages(_ trials: [CorpusTrial]) -> [String] {
        let misses = trials.filter { $0.verdict != .corrected }
        return CorpusMissStage.allCases.map { stage in
            let count = misses.filter { $0.missStage == stage }.count
            return "  \(stage.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0)) \(count)"
        }
    }

    /// The single numbers the PR states.
    static func headline(_ trials: [CorpusTrial]) -> [String] {
        let singleLong = trials.filter { singleSlipClasses.contains($0.kind) && $0.length >= 4 }
        return [
            "  single-slip classes, words of 4+ letters: " + CorpusRate(singleLong).text,
            "  all generated typos:                      " + CorpusRate(trials).text,
        ]
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    static func latencyLine(_ seconds: [Double]) -> String {
        String(format: "  completion decisions: %d, p50 %.2f ms, p95 %.2f ms, max %.2f ms", seconds.count,
               percentile(seconds, 0.5) * 1000, percentile(seconds, 0.95) * 1000, (seconds.max() ?? 0) * 1000)
    }
}

// MARK: Running a corpus

struct NeverChangeTrial: Sendable {
    let category: String
    let token: String
    let boundary: String
    let result: String
    var expected: String { token + (boundary == "sentence start" ? " " : boundary) }
    var wasChanged: Bool { result != expected }
}

struct GeneratedRun: Sendable {
    var trials: [CorpusTrial] = []
    /// Typos that are themselves words, by class. No spell checker can fix them without context.
    var excludedAsWords: [String: Int] = [:]
}

extension CorpusRunner {
    static let midSentence = "I think "
    static let sentenceStart = "Thanks. "

    /// Types each generated typo after "I think " and a space, skipping the ones the checker accepts as words.
    func run(generated typos: [GeneratedTypo], prefix: String = CorpusRunner.midSentence) -> GeneratedRun {
        var outcome = GeneratedRun()
        let checker = self.checker
        guard let resolved = TypingLanguageResolver.resolve(candidates: [language], available: checker.availableLanguages)
        else { return outcome }
        for typo in typos {
            if !checker.isMisspelled(typo.typed, language: resolved) {
                outcome.excludedAsWords[typo.kind.rawValue, default: 0] += 1
                continue
            }
            let guesses = checker.guesses(forWord: typo.typed, language: resolved)
            let position = guesses.firstIndex { $0.lowercased() == typo.intended.lowercased() }
            outcome.trials.append(CorpusTrial(
                typed: typo.typed, intended: typo.intended, kind: typo.kind.rawValue, length: typo.length,
                isTuning: TypoGenerator.isTuningWord(typo.intended.lowercased()), isTail: typo.isTail,
                result: run(prefix: prefix, token: typo.typed, boundary: " "), guessPosition: position
            ))
        }
        return outcome
    }

    /// Hand-made typos (typed, expected), typed after `prefix`.
    func run(pairs: [(typed: String, expected: String)], kind: String, prefix: String = CorpusRunner.midSentence) -> [CorpusTrial] {
        pairs.map { pair in
            let resolved = TypingLanguageResolver.resolve(candidates: [language], available: checker.availableLanguages) ?? language
            let guesses = checker.guesses(forWord: pair.typed, language: resolved)
            return CorpusTrial(
                typed: pair.typed, intended: pair.expected, kind: kind, length: pair.expected.filter(\.isLetter).count,
                isTuning: false, result: run(prefix: prefix, token: pair.typed, boundary: " "),
                guessPosition: guesses.firstIndex { $0.lowercased() == pair.expected.lowercased() }
            )
        }
    }

    /// Each never-change token before a space and before a period, and at the start of a sentence when it is
    /// capitalized.
    func runNeverChange(groups: [(category: String, tokens: [String])]) -> [NeverChangeTrial] {
        var trials: [NeverChangeTrial] = []
        for group in groups {
            for token in group.tokens {
                for boundary in [" ", "."] {
                    trials.append(NeverChangeTrial(
                        category: group.category, token: token, boundary: boundary,
                        result: run(prefix: Self.midSentence, token: token, boundary: boundary)
                    ))
                }
                if token.first?.isUppercase == true {
                    trials.append(NeverChangeTrial(
                        category: group.category, token: token, boundary: "sentence start",
                        result: run(prefix: Self.sentenceStart, token: token, boundary: " ")
                    ))
                }
            }
        }
        return trials
    }
}

extension CorpusReport {
    static func neverChange(_ trials: [NeverChangeTrial]) -> [String] {
        let changed = trials.filter(\.wasChanged)
        var lines = [String(format: "  false corrections: %d of %d trials = %.2f%%", changed.count, trials.count,
                            trials.isEmpty ? 0 : Double(changed.count) / Double(trials.count) * 100)]
        let categories = Array(Set(trials.map(\.category))).sorted()
        for category in categories {
            let ofCategory = trials.filter { $0.category == category }
            let wrong = ofCategory.filter(\.wasChanged)
            lines.append("  \(category.padding(toLength: 46, withPad: " ", startingAt: 0)) \(wrong.count)/\(ofCategory.count)")
        }
        lines.append("  changed: " + changed.map { "\($0.token)[\($0.boundary)]->\($0.result)" }.joined(separator: ", "))
        return lines
    }
}
