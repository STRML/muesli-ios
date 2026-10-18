import Foundation

/// Edit distance counting an adjacent swap as one edit (optimal string alignment), compared without regard to
/// case. "teh" to "the" is one edit.
enum TypingEditDistance {
    static func between(_ a: String, _ b: String) -> Int {
        let s = Array(a.lowercased())
        let t = Array(b.lowercased())
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var twoBack = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0...t.count)
        for i in 1...s.count {
            var row = [Int](repeating: i, count: t.count + 1)
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    row[j] = min(row[j], twoBack[j - 2] + 1)
                }
            }
            twoBack = previous
            previous = row
        }
        return previous[t.count]
    }
}

/// Everything the rule weighs, in one place so the corpus can tune it and a test can pin each piece.
struct TypingAutocorrectTuning: Sendable, Equatable {
    /// Tuned on the tuning half of the generated corpus (see `TuningHarnessTests`); the held-out half and the
    /// hand-made list are only ever used to report.
    var weights = TypingEditWeights()

    /// The most a correction may cost, by the length of the typed word. Two letters or fewer are never corrected,
    /// and a three-letter word only takes a swap of two letters that makes one of the most used words ("teh" for
    /// "the"; "cto" for "cot" is not a typo): "npm" and "faq" are not typos, and "wel"
    /// for "well" and "ide" for "idea" cost more wrong fixes than they gain (measured on the generated corpus).
    var budgetFourOrFive = 1.0
    var budgetSixOrSeven = 1.0
    var budgetEightOrMore = 1.3

    /// The same budgets when the checker offers exactly one candidate: with no runner-up to confuse it with, the
    /// only risk is the edit itself ("truely" for "truly" costs 1.4). Three-letter words are unchanged.
    var soleBudgetFourOrFive = 1.6
    var soleBudgetSixOrSeven = 1.6
    var soleBudgetEightOrMore = 2.2

    /// What a candidate's use costs it: per extra letter of prefix before the checker's completions list it, per
    /// place down that list, and when they never list it.
    var usageStepPerLetter = 0.1
    var usageStepPerPosition = 0.005
    var usageMiss = 1.4
    /// How many prefix letters count; a word first listed past this is treated as unlisted.
    var usageDepth = 2

    /// What the checker's own ranking adds: per place down its guesses, and for a word it did not guess.
    var guessStepPerPosition = 0.0
    var notGuessed = 1.0

    /// The best score may be at most this.
    var maximumScore = 2.2
    /// The best must beat the second best by this much, plus `marginPerExtraCost` for each unit of cost over one.
    var margin = 0.6
    var marginPerExtraCost = 0.0

    func budget(forWordLength length: Int, soleCandidate: Bool = false) -> Double {
        switch length {
        case ..<3: 0
        case 3: weights.transposition + weights.firstLetter
        case 4...5: soleCandidate ? soleBudgetFourOrFive : budgetFourOrFive
        case 6...7: soleCandidate ? soleBudgetSixOrSeven : budgetSixOrSeven
        default: soleCandidate ? soleBudgetEightOrMore : budgetEightOrMore
        }
    }

    static let standard = TypingAutocorrectTuning()
}

/// Whether the best candidate for a flagged word is safe to type over what the user wrote. Conservative on
/// purpose: a wrong correction is worse than a missed one, so every doubt returns nil. A candidate is scored by
/// what the slip would have cost a thumb, how used the word is, and where the checker ranked it; the best one wins
/// only if it is close enough to what was typed, scores low enough, and beats the runner-up by a margin.
enum TypingAutocorrectRule {
    struct Scored: Equatable {
        let word: String
        let cost: Double
        let score: Double
    }

    /// What each candidate would cost, in the order given. Kept apart so the corpus tuning can reuse the costs
    /// while it moves the knobs that do not change them.
    static func costs(for typed: String, candidates: [TypingCandidate], weights: TypingEditWeights) -> [Double] {
        let word = typed.lowercased()
        return candidates.map { TypingEditCost.between(word, $0.word, weights: weights) }
    }

    static func scored(for typed: String, candidates: [TypingCandidate], tuning: TypingAutocorrectTuning) -> [Scored] {
        scored(for: typed, candidates: candidates, costs: costs(for: typed, candidates: candidates, weights: tuning.weights), tuning: tuning)
    }

    static func scored(
        for typed: String, candidates: [TypingCandidate], costs: [Double], tuning: TypingAutocorrectTuning
    ) -> [Scored] {
        let word = typed.lowercased()
        return zip(candidates, costs).compactMap { candidate, cost in
            let limit = tuning.budget(forWordLength: word.count, soleCandidate: isSoleCandidate(candidates, for: word))
            guard candidate.word != word, abs(candidate.word.count - word.count) <= 2, cost <= limit else { return nil }
            guard word.count != 3 || (isAdjacentSwap(word, candidate.word) && candidate.usage.first.map({ $0 >= 0 }) == true) else { return nil }
            return Scored(word: candidate.word, cost: cost, score: cost + prior(candidate, tuning: tuning))
        }.sorted { ($0.score, $0.word) < ($1.score, $1.word) }
    }

    /// The looser budget is for a pool of one, unless that one is the typed word minus its final "s": a possessive
    /// typed without its apostrophe ("oenologys" for "oenology's") would be turned into the plain word.
    private static func isSoleCandidate(_ candidates: [TypingCandidate], for word: String) -> Bool {
        guard candidates.count == 1, let only = candidates.first else { return false }
        return !(word.hasSuffix("s") && only.word == String(word.dropLast()))
    }

    /// The guess to type instead of `typed`, or nil. `strict` is for a word that may be the start of a host name
    /// or a URL scheme ("github" before a "."), where only a single edit is accepted.
    static func correction(
        for typed: String, candidates: [TypingCandidate], strict: Bool = false,
        tuning: TypingAutocorrectTuning = .standard
    ) -> String? {
        correction(
            for: typed, scored: scored(for: typed, candidates: candidates, tuning: tuning), strict: strict, tuning: tuning
        )
    }

    static func correction(for typed: String, scored ranked: [Scored], strict: Bool, tuning: TypingAutocorrectTuning) -> String? {
        if case .correct(let word) = decision(for: typed, scored: ranked, strict: strict, tuning: tuning) { return word }
        return nil
    }

    /// What the rule decided, and when it left the word alone, the first check that stopped it. For diagnostics:
    /// the thresholds and scoring are those of `correction`.
    enum Decision: Equatable {
        case correct(String)
        case declined(TypingDeclineReason)
    }

    static func decision(
        for typed: String, candidates: [TypingCandidate], strict: Bool = false, tuning: TypingAutocorrectTuning = .standard
    ) -> Decision {
        let ranked = scored(for: typed, candidates: candidates, tuning: tuning)
        guard ranked.isEmpty else { return decision(for: typed, scored: ranked, strict: strict, tuning: tuning) }
        return .declined(whyNothingWasScored(for: typed, candidates: candidates, tuning: tuning))
    }

    static func decision(for typed: String, scored ranked: [Scored], strict: Bool, tuning: TypingAutocorrectTuning) -> Decision {
        guard let best = ranked.first else { return .declined(.noGuesses) }
        guard best.score <= tuning.maximumScore else { return .declined(.maxScore) }
        if strict, TypingEditDistance.between(typed, best.word) > 1 { return .declined(.strictEdit) }
        if let runnerUp = ranked.dropFirst().first {
            let required = tuning.margin + tuning.marginPerExtraCost * max(0, best.cost - 1)
            guard runnerUp.score - best.score >= required else { return .declined(.margin) }
        }
        return .correct(best.word)
    }

    /// The same filters as `scored`, read for the one that stopped the nearest candidate.
    private static func whyNothingWasScored(
        for typed: String, candidates: [TypingCandidate], tuning: TypingAutocorrectTuning
    ) -> TypingDeclineReason {
        let word = typed.lowercased()
        let limit = tuning.budget(forWordLength: word.count)
        let near = candidates.filter { $0.word != word && abs($0.word.count - word.count) <= 2 }
        guard !near.isEmpty else { return candidates.isEmpty ? .noGuesses : .lengthDiff }
        let affordable = near.filter { TypingEditCost.between(word, $0.word, weights: tuning.weights) <= limit }
        return affordable.isEmpty ? .budget : .shortWord
    }

    static func isAdjacentSwap(_ a: String, _ b: String) -> Bool {
        a.count == b.count && a != b && a.sorted() == b.sorted() && TypingEditDistance.between(a, b) == 1
    }

    private static func prior(_ candidate: TypingCandidate, tuning: TypingAutocorrectTuning) -> Double {
        usagePenalty(candidate.usage, tuning: tuning) + guessPenalty(candidate.guessPosition, tuning: tuning)
    }

    private static func usagePenalty(_ usage: [Int], tuning: TypingAutocorrectTuning) -> Double {
        guard let hit = usage.prefix(tuning.usageDepth).enumerated().first(where: { $0.element >= 0 }) else {
            return tuning.usageMiss
        }
        return tuning.usageStepPerLetter * Double(hit.offset) + tuning.usageStepPerPosition * Double(hit.element)
    }

    private static func guessPenalty(_ position: Int?, tuning: TypingAutocorrectTuning) -> Double {
        guard let position else { return tuning.notGuessed }
        return tuning.guessStepPerPosition * Double(position)
    }
}
