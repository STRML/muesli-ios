#if canImport(KeyboardTypingKit)
@testable import KeyboardTypingKit
#else
@testable import Muesli
#endif

/// The kinds of slip a thumb makes, one per typo the generator writes.
enum TypoClass: String, CaseIterable, Sendable {
    /// A letter replaced by a key next to it ("thr" for "the").
    case neighbour
    /// A letter left out ("tomorow").
    case drop
    /// A letter typed twice ("thhe").
    case double
    /// Two neighbouring letters swapped ("teh").
    case transposition
    /// A contraction typed without its apostrophe ("dont").
    case apostrophe
}

struct GeneratedTypo: Sendable, Equatable {
    let typed: String
    /// What the user meant.
    let intended: String
    let kind: TypoClass
    /// From the long-tail list (`TailWords`) and not the common one.
    var isTail = false
    /// Letters in the intended word, without apostrophes.
    var length: Int { intended.filter(\.isLetter).count }
}

/// SplitMix64, written out so the corpus is the same on every run and every machine. Swift's own generators and
/// `hashValue` are seeded per process.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
}

enum TypoGenerator {
    static let seed: UInt64 = 20_261_016

    /// FNV-1a: a hash that does not change between runs, unlike `hashValue`.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return hash
    }

    /// Half the words tune the autocorrect weights; the other half are only ever used to report. A word's side
    /// depends on the word, not on its place in the list.
    static func isTuningWord(_ word: String) -> Bool { stableHash(word) % 2 == 0 }

    /// Plain words of three letters or more that can be typed on the letter keys.
    static func typableWords(from words: [String]) -> [String] {
        words.filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter } }
    }

    /// Contractions in the list: letters around one apostrophe, as the user would write them.
    static func contractions(from words: [String]) -> [String] {
        words.filter { word in
            word.filter { $0 == "'" }.count == 1 && word.first != "'" && word.last != "'"
                && word.allSatisfy { $0 == "'" || ($0.isASCII && $0.isLetter) }
        }
    }

    /// Typos for one word. Two neighbour substitutions, one drop, one double and one transposition, each at a
    /// position chosen from the word's own seeded stream; fewer when the word has no valid choice.
    static func typos(for word: String) -> [GeneratedTypo] {
        var rng = SplitMix64(seed: seed ^ stableHash(word))
        let letters = Array(word)
        var result: [GeneratedTypo] = []
        func add(_ kind: TypoClass, _ typed: [Character]) {
            let text = String(typed)
            guard text != word, !result.contains(where: { $0.typed == text }) else { return }
            result.append(GeneratedTypo(typed: text, intended: word, kind: kind))
        }
        for _ in 0..<2 {
            let index = rng.below(letters.count)
            let options = TypingKeyAdjacency.neighbours(of: letters[index])
            guard !options.isEmpty else { continue }
            var typed = letters
            typed[index] = options[rng.below(options.count)]
            add(.neighbour, typed)
        }
        var dropped = letters
        dropped.remove(at: rng.below(letters.count))
        add(.drop, dropped)
        var doubled = letters
        let doubleIndex = rng.below(letters.count)
        doubled.insert(letters[doubleIndex], at: doubleIndex)
        add(.double, doubled)
        let swappable = (0..<(letters.count - 1)).filter { letters[$0] != letters[$0 + 1] }
        if !swappable.isEmpty {
            let index = swappable[rng.below(swappable.count)]
            var swapped = letters
            swapped.swapAt(index, index + 1)
            add(.transposition, swapped)
        }
        return result
    }

    /// The contraction without its apostrophe, lowercased the way it is typed ("I'm" becomes "im").
    static func apostropheTypo(for contraction: String) -> GeneratedTypo? {
        let typed = contraction.lowercased().filter { $0 != "'" }
        guard typed.count >= 2 else { return nil }
        return GeneratedTypo(typed: typed, intended: contraction, kind: .apostrophe)
    }

    /// Typos of the long-tail sample, flagged so a report can keep them apart from the common words.
    static func generateTail() -> [GeneratedTypo] {
        typableWords(from: TailWords.all).flatMap { typos(for: $0) }.map {
            var typo = $0
            typo.isTail = true
            return typo
        }
    }

    static func generate(from words: [String]) -> [GeneratedTypo] {
        typableWords(from: words).flatMap { typos(for: $0) } + contractions(from: words).compactMap { apostropheTypo(for: $0) }
    }
}
