import Foundation
import XCTest
@testable import KeyboardTypingKit

/// Tunes `TypingAutocorrectTuning` on a Mac from the candidate pools the simulator recorded
/// (`AutocorrectPoolRecorderTests` in MuesliTests). Skipped unless `MUESLI_POOL_RECORDING` names that file, so
/// a normal `swift test` never needs the simulator. The weights are searched on the tuning half of the words
/// and reported on the other half; the hand-made list is never used for tuning.
final class TuningHarnessTests: XCTestCase {
    struct Row {
        let id: Int
        let typed: String
        let intended: String?
        let kind: String
        let length: Int
        let tuning: Bool
        let capitalized: Bool
        let tail: Bool
        let candidates: [TypingCandidate]
    }

    struct Tally {
        var corrected = 0, wrong = 0, left = 0, falseCorrections = 0, neverTrials = 0
        var total: Int { corrected + wrong + left }
        var correctedRate: Double { total == 0 ? 0 : Double(corrected) / Double(total) }
        var wrongRate: Double { total == 0 ? 0 : Double(wrong) / Double(total) }
        var falseRate: Double { neverTrials == 0 ? 0 : Double(falseCorrections) / Double(neverTrials) }
        var text: String {
            String(format: "n=%5d corrected %5.1f%% wrong %4.1f%% | never-change (flagged only) false %d/%d = %.2f%%",
                   total, correctedRate * 100, wrongRate * 100, falseCorrections, neverTrials, falseRate * 100)
        }
    }

    private func load(_ path: String) throws -> [Row] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(separator: "\n").enumerated().map { id, line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let candidates = (object["candidates"] as! [[Any]]).map { entry in
                TypingCandidate(word: entry[0] as! String, guessPosition: (entry[1] as! Int) < 0 ? nil : entry[1] as? Int,
                                usage: entry[2] as! [Int])
            }
            return Row(id: id, typed: object["typed"] as! String, intended: object["intended"] as? String, kind: object["kind"] as! String,
                       length: object["length"] as! Int, tuning: object["tuning"] as! Bool,
                       capitalized: object["capitalized"] as! Bool, tail: object["tail"] as? Bool ?? false, candidates: candidates)
        }
    }

    /// Costs depend only on the weights, so they are kept while the other knobs move.
    private final class CostCache {
        var weights: TypingEditWeights?
        var costs: [Int: [Double]] = [:]

        func costs(forRow index: Int, _ row: Row, weights current: TypingEditWeights) -> [Double] {
            if weights != current {
                weights = current
                costs = [:]
            }
            if let known = costs[index] { return known }
            let computed = TypingAutocorrectRule.costs(for: row.typed, candidates: row.candidates, weights: current)
            costs[index] = computed
            return computed
        }
    }

    private let cache = CostCache()

    private func decide(_ row: Row, strict: Bool, _ tuning: TypingAutocorrectTuning) -> String? {
        let typed = row.typed.lowercased()
        let ranked = TypingAutocorrectRule.scored(
            for: typed, candidates: row.candidates,
            costs: cache.costs(forRow: row.id, row, weights: tuning.weights), tuning: tuning
        )
        return TypingAutocorrectRule.correction(for: typed, scored: ranked, strict: strict, tuning: tuning)
    }

    private var details: [String] = []


    private func evaluate(_ rows: [Row], _ tuning: TypingAutocorrectTuning, tuningHalf: Bool?, kinds: Set<String>? = nil, tail: Bool? = nil, collect: Bool = false) -> Tally {
        var tally = Tally()
        for row in rows {
            if let half = tuningHalf, row.tuning != half { continue }
            if let kinds, !kinds.contains(row.kind) { continue }
            if let tail, row.tail != tail { continue }
            if TypingContractions.correction(for: row.typed.lowercased()) != nil { continue }
            if row.kind.hasPrefix("never:") {
                for strict in (row.capitalized ? [false] : [false, true]) {
                    tally.neverTrials += 1
                    if let fixed = decide(row, strict: strict, tuning) {
                        tally.falseCorrections += 1
                        if collect { details.append("false: \(row.typed)\(strict ? "." : " ") -> \(fixed)") }
                    }
                }
                continue
            }
            let fixed = decide(row, strict: false, tuning)
            if fixed == nil {
                tally.left += 1
                if collect, row.kind == "hand-made" { details.append("missed: \(row.typed) -> \(row.intended ?? "")") }
            } else if fixed == row.intended?.lowercased() {
                tally.corrected += 1
            } else {
                tally.wrong += 1
                if collect { details.append("wrong: \(row.typed) -> \(fixed ?? "") [\(row.intended ?? "")]") }
            }
        }
        return tally
    }

    private func objective(_ rows: [Row], _ tuning: TypingAutocorrectTuning) -> Double {
        let slips: Set<String> = ["neighbour", "drop", "double", "transposition"]
        let common = evaluate(rows, tuning, tuningHalf: true, kinds: slips, tail: false)
        let tail = evaluate(rows, tuning, tuningHalf: true, kinds: slips, tail: true)
        let never = evaluate(rows, tuning, tuningHalf: true, kinds: Set(rows.map(\.kind).filter { $0.hasPrefix("never:") }))
        let hand = evaluate(rows.filter { TypoGenerator.isTuningWord($0.typed.lowercased()) }, tuning, tuningHalf: nil, kinds: ["hand-made"])
        // Common words are most of what people type; the tail is a fifth as heavy so it checks the usage prior
        // without taking over.
        return common.correctedRate - 4 * common.wrongRate + 0.3 * (tail.correctedRate - 4 * tail.wrongRate)
            - (Double(ProcessInfo.processInfo.environment["MUESLI_FALSE_WEIGHT"] ?? "20") ?? 20) * never.falseRate + 0.3 * hand.correctedRate - 2 * hand.wrongRate
    }

    private typealias Knob = (name: String, values: [Double], set: (inout TypingAutocorrectTuning, Double) -> Void)

    private let knobs: [Knob] = [
        ("neighbourSubstitution", [0.4, 0.55, 0.7, 0.85, 1.0], { $0.weights.neighbourSubstitution = $1 }),
        ("vowelSubstitution", [0.5, 0.65, 0.8], { $0.weights.vowelSubstitution = $1 }),
        ("substitution", [1.0, 1.2, 1.4, 1.7, 2.0, 3.0], { $0.weights.substitution = $1 }),
        ("insertion", [0.6, 0.8, 1.0, 1.2], { $0.weights.insertion = $1 }),
        ("doubledInsertion", [0.4, 0.6, 0.8, 1.0], { $0.weights.doubledInsertion = $1 }),
        ("deletion", [0.7, 0.9, 1.1, 1.4], { $0.weights.deletion = $1 }),
        ("doubledDeletion", [0.4, 0.6, 0.8, 1.0], { $0.weights.doubledDeletion = $1 }),
        ("transposition", [0.3, 0.45, 0.6, 0.8, 1.0], { $0.weights.transposition = $1 }),
        ("firstLetter", [0.2, 0.4, 0.8, 1.2, 2.0], { $0.weights.firstLetter = $1 }),
        ("usageStepPerLetter", [0.0, 0.1, 0.25, 0.4, 0.6, 0.9, 1.3], { $0.usageStepPerLetter = $1 }),
        ("usageStepPerPosition", [0.0, 0.005, 0.01, 0.02, 0.04], { $0.usageStepPerPosition = $1 }),
        ("usageMiss", [0.4, 0.7, 1.0, 1.4, 2.0, 3.0, 4.0], { $0.usageMiss = $1 }),
        ("usageDepth", [2, 3, 4, 5, 6, 8], { $0.usageDepth = Int($1) }),
        ("guessStepPerPosition", [0.0, 0.03, 0.05, 0.1, 0.2], { $0.guessStepPerPosition = $1 }),
        ("notGuessed", [0.0, 0.15, 0.3, 0.6, 1.0], { $0.notGuessed = $1 }),
        ("budgetFourOrFive", [0.8, 1.0, 1.1, 1.3, 1.6], { $0.budgetFourOrFive = $1 }),
        ("budgetSixOrSeven", [1.0, 1.3, 1.6, 2.0, 2.4], { $0.budgetSixOrSeven = $1 }),
        ("budgetEightOrMore", [1.3, 1.6, 2.0, 2.4, 3.0], { $0.budgetEightOrMore = $1 }),
        ("maximumScore", [1.4, 1.8, 2.2, 2.6, 3.0, 4.0, 5.0, 7.0], { $0.maximumScore = $1 }),
        ("margin", [0.0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.9, 1.2, 1.6], { $0.margin = $1 }),
        ("marginPerExtraCost", [0.0, 0.25, 0.5, 1.0, 2.0], { $0.marginPerExtraCost = $1 }),
    ]

    func testTuneFromRecordedPools() throws {
        guard let path = ProcessInfo.processInfo.environment["MUESLI_POOL_RECORDING"] else {
            throw XCTSkip("Set MUESLI_POOL_RECORDING to the file AutocorrectPoolRecorderTests wrote.")
        }
        let rows = try load(path)
        let single: Set<String> = ["neighbour", "drop", "double", "transposition"]
        let neverKinds = Set(rows.map(\.kind).filter { $0.hasPrefix("never:") })

        /// The held-out single-slip rate for words of four letters or more, the number the PR states.
        func fourPlus(_ rows: [Row], _ tuning: TypingAutocorrectTuning, tail: Bool) -> Tally {
            evaluate(rows.filter { $0.length >= 4 }, tuning, tuningHalf: false, kinds: single, tail: tail)
        }
        func report(_ name: String, _ tuning: TypingAutocorrectTuning) {
            details = []
            let hand = evaluate(rows, tuning, tuningHalf: nil, kinds: ["hand-made"], collect: true)
            let neverTuning = evaluate(rows, tuning, tuningHalf: true, kinds: neverKinds)
            let neverHeld = evaluate(rows, tuning, tuningHalf: false, kinds: neverKinds, collect: true)
            print("TUNING \(name)\n  common held-out, 4+ letters: \(fourPlus(rows, tuning, tail: false).text)\n" +
                  "  common held-out, all:        \(evaluate(rows, tuning, tuningHalf: false, kinds: single, tail: false).text)\n" +
                  "  tail held-out, 4+ letters:   \(fourPlus(rows, tuning, tail: true).text)\n" +
                  "  never tuning: \(neverTuning.falseCorrections)/\(neverTuning.neverTrials)  never held-out: \(neverHeld.falseCorrections)/\(neverHeld.neverTrials)\n" +
                  "  hand-made (independent): \(hand.text)\n  details: " + details.prefix(60).joined(separator: "; "))
        }
        func breakdown(_ tuning: TypingAutocorrectTuning, tail: Bool) {
            var lines: [String] = []
            for kind in ["neighbour", "drop", "double", "transposition"] {
                for (name, range) in [("3", 3...3), ("4", 4...4), ("5-6", 5...6), ("7-8", 7...8), ("9+", 9...99)] {
                    let subset = rows.filter { $0.kind == kind && !$0.tuning && $0.tail == tail && range.contains($0.length) }
                    guard !subset.isEmpty else { continue }
                    var corrected = 0, wrong = 0, inPool = 0
                    for row in subset {
                        let fixed = decide(row, strict: false, tuning)
                        if fixed == row.intended { corrected += 1 } else if fixed != nil { wrong += 1 }
                        if row.candidates.contains(where: { $0.word == row.intended }) { inPool += 1 }
                    }
                    lines.append(String(format: "  %@ %@ n=%d corrected %.1f%% wrong %.1f%% intended-in-pool %.1f%%", kind, name, subset.count,
                                        Double(corrected) / Double(subset.count) * 100, Double(wrong) / Double(subset.count) * 100,
                                        Double(inPool) / Double(subset.count) * 100))
                }
            }
            print("BREAKDOWN \(tail ? "tail" : "common") (held-out)\n" + lines.joined(separator: "\n"))
        }
        var best = TypingAutocorrectTuning.standard
        if let given = ProcessInfo.processInfo.environment["MUESLI_TUNING_START"], given == "standard" { best = .standard }
        report("start", best)
        var bestScore = objective(rows, best)
        let passes = Int(ProcessInfo.processInfo.environment["MUESLI_TUNING_PASSES"] ?? "3") ?? 3
        for pass in 0..<passes {
            for knob in knobs {
                for value in knob.values {
                    var trial = best
                    knob.set(&trial, value)
                    let score = objective(rows, trial)
                    if score > bestScore + 1e-9 { best = trial; bestScore = score }
                }
            }
            print(String(format: "pass %d objective %.4f", pass + 1, bestScore))
        }
        report("final", best)
        breakdown(best, tail: false)
        breakdown(best, tail: true)
        var examples: [String] = []
        for row in rows where !row.tuning && !row.tail && ["transposition", "drop", "neighbour"].contains(row.kind) && (4...6).contains(row.length) {
            let fixed = decide(row, strict: false, best)
            if fixed != row.intended, examples.count < 60 { examples.append("\(row.typed)->\(fixed ?? "-") [\(row.intended ?? "")]") }
        }
        print("EXAMPLES " + examples.joined(separator: "; "))

        // What each piece contributes, removed from the tuned configuration one at a time.
        var noUsage = best
        noUsage.usageMiss = 0
        noUsage.usageStepPerLetter = 0
        noUsage.usageStepPerPosition = 0
        var unitCost = best
        unitCost.weights = TypingEditWeights(
            transposition: 1, neighbourSubstitution: 1, vowelSubstitution: 1, substitution: 1, insertion: 1,
            doubledInsertion: 1, deletion: 1, doubledDeletion: 1, firstLetter: 0
        )
        var noMargin = best
        noMargin.margin = 0
        noMargin.marginPerExtraCost = 0
        print("ABLATIONS (common held-out 4+; hand-made; never held-out)")
        for (name, candidateRows, tuning) in [
            ("tuned", rows, best), ("without the usage prior", rows, noUsage),
            ("without weighted costs (all slips cost 1)", rows, unitCost), ("without the margin", rows, noMargin),
        ] {
            let common = fourPlus(candidateRows, tuning, tail: false)
            let hand = evaluate(candidateRows, tuning, tuningHalf: nil, kinds: ["hand-made"])
            let never = evaluate(candidateRows, tuning, tuningHalf: false, kinds: neverKinds)
            print(String(format: "  %@: corrected %.1f%% wrong %.1f%% | hand-made %.1f%% wrong %.1f%% | never false %d/%d",
                         name.padding(toLength: 42, withPad: " ", startingAt: 0), common.correctedRate * 100, common.wrongRate * 100,
                         hand.correctedRate * 100, hand.wrongRate * 100, never.falseCorrections, never.neverTrials))
        }
        print("TUNED \(best)")
    }
}
