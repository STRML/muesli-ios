import UIKit
import XCTest
@testable import Muesli

/// A host text field for the corpus run: just text before the cursor.
@MainActor
private final class CorpusDocument: TypingDocument {
    var before = ""
    let documentIdentifier: UUID? = UUID()
    var contextBefore: String? { before.isEmpty ? nil : before }
    var contextAfter: String? { nil }
    var selectedText: String? { nil }
    func insert(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
}

/// Runs the corpus through the real stack: a `TypingEngine` fed one key at a time, the real
/// `TypingAutocorrector`, and the real `UITextChecker`. `UITextChecker` needs a UIKit runtime, so this is the
/// only layer that can measure the engine; the logic around it has a host layer with a fake checker.
@MainActor
final class AutocorrectCorpusTests: XCTestCase {
    private struct Trial {
        let typed: String
        let expected: String
        let result: String
        let boundary: String
        var isCorrect: Bool { result == expected }
        var isUnchanged: Bool { result == typed + " " }
    }

    private var builder: TypingSuggestionBuilder!
    private var autocorrector: TypingAutocorrector!
    private var engine: TypingEngine!

    override func setUp() async throws {
        let builder = TypingSuggestionBuilder(
            makeChecker: { UITextCheckerAdapter() },
            languageCandidates: { ["en-US"] }
        )
        self.builder = builder
        autocorrector = TypingAutocorrector(
            checker: { builder.currentChecker() },
            languageCandidates: { ["en-US"] },
            traits: { TypingTraits() },
            isEnabled: { true },
            ignoreWord: { builder.ignore($0) }
        )
    }

    /// Types `token` after `prefix`, one key at a time, then the boundary. Returns what the field holds from
    /// the end of `prefix` on.
    private func run(prefix: String, token: String, boundary: String) -> String {
        let document = CorpusDocument()
        document.before = prefix
        engine = TypingEngine(document: document, suggestionSource: builder, now: { 0 })
        engine.completionHandler = autocorrector
        engine.documentDidChange()
        for character in token { engine.type(String(character)) }
        switch boundary {
        case " ": engine.tapSpace()
        case "\n": engine.tapReturn()
        default: engine.type(boundary)
        }
        return String(document.before.dropFirst(prefix.count))
    }

    private let midSentence = "I think "
    private let sentenceStart = "Thanks. "

    private func typoTrials(_ pairs: [(typed: String, expected: String)], prefix: String) -> [Trial] {
        pairs.map { Trial(typed: $0.typed, expected: $0.expected + " ", result: run(prefix: prefix, token: $0.typed, boundary: " "), boundary: " ") }
    }

    private func neverTrials() -> [Trial] {
        var trials: [Trial] = []
        for token in AutocorrectCorpus.neverChange {
            for boundary in [" ", "."] {
                trials.append(Trial(typed: token + boundary, expected: token + boundary,
                                    result: run(prefix: midSentence, token: token, boundary: boundary), boundary: boundary))
            }
            if token.first?.isUppercase == true {
                trials.append(Trial(typed: token + " ", expected: token + " ",
                                    result: run(prefix: sentenceStart, token: token, boundary: " "), boundary: "sentence start"))
            }
        }
        return trials
    }

    // Matrix rows Q1 (correction rate on typos) and Q2 (false-correction rate on words that must not change).
    func testCorpusCorrectionAndFalseCorrectionRates() throws {
        var report = ["OS \(UIDevice.current.systemVersion), dictionaries: \(UITextChecker.availableLanguages.filter { $0.hasPrefix("en") })"]

        let typos = typoTrials(AutocorrectCorpus.typos, prefix: midSentence)
        let startTypos = typoTrials(AutocorrectCorpus.sentenceStartTypos, prefix: sentenceStart)
        let never = neverTrials()

        let corrected = typos.filter(\.isCorrect).count
        let wrongFix = typos.filter { !$0.isCorrect && !$0.isUnchanged }
        let startCorrected = startTypos.filter(\.isCorrect).count
        let falseCorrections = never.filter { $0.result != $0.expected }

        let rate = Double(corrected) / Double(typos.count)
        let startRate = Double(startCorrected) / Double(startTypos.count)
        let falseRate = Double(falseCorrections.count) / Double(never.count)
        report.append(String(format: "(a) typos corrected: %d/%d = %.1f%%", corrected, typos.count, rate * 100))
        report.append(String(format: "(a2) sentence-start typos corrected: %d/%d = %.1f%%", startCorrected, startTypos.count, startRate * 100))
        report.append(String(format: "(b) false corrections: %d/%d trials = %.2f%% (%d distinct tokens, each typed before a space and a period)",
                             falseCorrections.count, never.count, falseRate * 100, AutocorrectCorpus.neverChange.count))
        report.append("wrong fixes among (a): " + wrongFix.map { "\($0.typed) -> \($0.result)" }.joined(separator: ", "))
        report.append("missed (a): " + typos.filter { !$0.isCorrect }.map { "\($0.typed) -> \($0.result)" }.joined(separator: ", "))
        report.append("missed (a2): " + startTypos.filter { !$0.isCorrect }.map { "\($0.typed) -> \($0.result)" }.joined(separator: ", "))
        report.append("FALSE CORRECTIONS (b): " + falseCorrections.map { "\($0.typed) [\($0.boundary)] -> \($0.result)" }.joined(separator: ", "))

        let text = report.joined(separator: "\n")
        print("AUTOCORRECT CORPUS REPORT\n\(text)")
        let path = NSTemporaryDirectory() + "autocorrect-corpus-report.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(AutocorrectCorpus.typos.count, 60)
        XCTAssertGreaterThanOrEqual(AutocorrectCorpus.neverChange.count, 80)
        // Thresholds sit below what was measured on this runtime (OS 27.0 simulator: 81.8% corrected, 0.5% false,
        // 1 wrong fix), with room for a different dictionary on CI. The false-correction limit is the hard
        // 2% cap and is never loosened to fit a result: tighten the rule instead.
        XCTAssertLessThanOrEqual(falseRate, 0.02, "false corrections: \(falseCorrections.map(\.typed))")
        XCTAssertGreaterThanOrEqual(rate, 0.75, text)
        XCTAssertGreaterThanOrEqual(startRate, 0.6, text)
        XCTAssertLessThanOrEqual(wrongFix.count, 3, "a wrong fix is worse than a missed one: \(wrongFix)")
    }
}
