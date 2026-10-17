import Darwin
import UIKit
import XCTest
@testable import Muesli

/// Runs the autocorrect corpus through the real stack: a `TypingEngine` fed one key at a time, the real
/// `TypingAutocorrector`, and the real `UITextChecker`. `UITextChecker` needs a UIKit runtime, so this is the
/// only layer that can measure the engine; the logic around it has a host layer with a fake checker.
///
/// Three sets, because the engine is judged on all of them: the hand-made typos from PR 13, the generated
/// fat-finger corpus (`Tests/KeyboardTypingKitTests/Corpus`), and the tokens that must never change.
@MainActor
final class AutocorrectCorpusTests: XCTestCase {
    private func makeRunner() -> CorpusRunner {
        CorpusRunner { UITextCheckerAdapter() }
    }

    /// The process's physical footprint, the number the system's jetsam limit looks at. A proxy for the keyboard
    /// extension's footprint: this is the test host, not the extension.
    private func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private func publish(_ report: [String], named name: String) {
        let text = report.joined(separator: "\n")
        print("AUTOCORRECT CORPUS REPORT \(name)\n\(text)")
        try? text.write(toFile: NSTemporaryDirectory() + "autocorrect-corpus-\(name).txt", atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Matrix rows Q1 (correction rate on the hand-made typos) and Q2 (false corrections on words that must not change).
    func testHandMadeTyposAndNeverChangeSet() throws {
        let runner = makeRunner()
        let typos = runner.run(pairs: AutocorrectCorpus.typos, kind: "hand-made")
        let startTypos = runner.run(pairs: AutocorrectCorpus.sentenceStartTypos, kind: "sentence start", prefix: CorpusRunner.sentenceStart)
        let never = runner.runNeverChange(groups: AutocorrectCorpus.neverChangeGroups)

        let rate = CorpusRate(typos), startRate = CorpusRate(startTypos)
        let changed = never.filter(\.wasChanged)
        let falseRate = Double(changed.count) / Double(never.count)
        var report = ["OS \(UIDevice.current.systemVersion)"]
        report.append("(a) hand-made typos: " + rate.text)
        report.append("(a2) sentence-start typos: " + startRate.text)
        report.append("(b) never-change set, \(AutocorrectCorpus.neverChange.count) tokens:")
        report += CorpusReport.neverChange(never)
        report.append("wrong fixes among (a): " + typos.filter { $0.verdict == .wrong }.map { "\($0.typed) -> \($0.result)" }.joined(separator: ", "))
        report.append("missed (a): " + typos.filter { $0.verdict != .corrected }.map { "\($0.typed) -> \($0.result)" }.joined(separator: ", "))
        report.append("missed (a2): " + startTypos.filter { $0.verdict != .corrected }.map { "\($0.typed) -> \($0.result)" }.joined(separator: ", "))
        publish(report, named: "hand-made")

        XCTAssertGreaterThanOrEqual(AutocorrectCorpus.typos.count, 60)
        XCTAssertGreaterThanOrEqual(AutocorrectCorpus.neverChange.count, 300)
        // The false-correction limit is the hard 2% cap and is never loosened to fit a result: tighten the rule.
        XCTAssertLessThanOrEqual(falseRate, 0.02, "false corrections: \(changed.map(\.token))")
        XCTAssertGreaterThanOrEqual(rate.correctedRate, 0.75, report.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(startRate.correctedRate, 0.6, report.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(rate.wrong, 3, "a wrong fix is worse than a missed one")
    }

    // Matrix row Q3: the generated fat-finger corpus, by typo class and word length, tuning half and held-out half.
    func testGeneratedCorpusReport() throws {
        let runner = makeRunner()
        let footprintBefore = footprintBytes()
        let commonTypos = TypoGenerator.generate(from: CommonWords.all)
        let tailTypos = TypoGenerator.generateTail()
        let run = runner.run(generated: commonTypos + tailTypos)
        let common = run.trials.filter { !$0.isTail }, tail = run.trials.filter(\.isTail)
        let held = common.filter { !$0.isTuning }

        var report = ["OS \(UIDevice.current.systemVersion), generated \(commonTypos.count) typos from \(CommonWords.all.count) common words and " +
            "\(tailTypos.count) from \(TailWords.all.count) tail words, \(run.trials.count) typed (\(run.excludedAsWords.values.reduce(0, +)) " +
            "excluded because the dictionary accepts them as words: " +
            run.excludedAsWords.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"]
        for (name, trials) in [("COMMON WORDS, held-out half", held), ("COMMON WORDS, tuning half", common.filter(\.isTuning)),
                               ("COMMON WORDS, all", common), ("TAIL WORDS, all", tail)] {
            report.append("\n\(name)")
            report += CorpusReport.headline(trials)
            report += CorpusReport.byClassAndLength(trials)
            report.append("  misses by stage:")
            report += CorpusReport.missStages(trials)
        }
        report.append("\nlatency")
        report.append(CorpusReport.latencyLine(runner.timer.seconds))
        report.append("footprint: before \(footprintBefore / 1024) KB, after \(footprintBytes() / 1024) KB")
        let wrong = held.filter { $0.verdict == .wrong }.prefix(60)
        report.append("\nwrong fixes (held-out, first 60): " + wrong.map { "\($0.typed)->\($0.result.trimmingCharacters(in: .whitespaces)) [\($0.intended)]" }.joined(separator: ", "))
        publish(report, named: "generated")
        XCTAssertGreaterThan(common.count, 5000)

        // The targets. Single slips (neighbour key, drop, double, transposition) of words of four letters or more.
        let slips = held.filter { CorpusReport.singleSlipClasses.contains($0.kind) && $0.length >= 4 }
        XCTAssertGreaterThanOrEqual(CorpusRate(slips).correctedRate, 0.90, report.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(CorpusRate(common).correctedRate, 0.85, "all generated typos, common words")
        XCTAssertLessThanOrEqual(CorpusRate(common).wrongRate, 0.03, "corrected to a word other than the intended one")
    }
}
