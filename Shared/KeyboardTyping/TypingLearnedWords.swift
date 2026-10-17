import Foundation

/// What autocorrect has learned about this user's words, kept across keyboard launches. Two lists, both capped
/// so a long-lived keyboard never grows without bound.
///
/// - `rejected`: words the user took back (a backspace or a tap on the quoted original right after a fix). They
///   are never corrected again.
/// - `seen`: words the checker flags that were typed and left as typed, with how often. Three times is
///   deliberate, so the word is learned (see `TypingAutocorrector`). A word that was corrected and kept never
///   gets here, or "teh" would be learned after three successful fixes.
struct TypingLearnedWords: Codable, Equatable, Sendable {
    struct Seen: Codable, Equatable, Sendable {
        var word: String
        var count: Int
    }

    static let maximumRejected = 500
    static let maximumSeen = 300
    static let timesTypedToLearn = 3

    /// Oldest first.
    private(set) var rejected: [String] = []
    private(set) var learned: [String] = []
    private(set) var seen: [Seen] = []

    func isRejected(_ word: String) -> Bool { rejected.contains(word.lowercased()) }
    func isLearned(_ word: String) -> Bool { learned.contains(word.lowercased()) }

    mutating func reject(_ word: String) {
        Self.append(word.lowercased(), to: &rejected, limit: Self.maximumRejected)
    }

    /// Counts one more time the word was typed and left. Returns true when that makes it learned.
    mutating func noteLeftAsTyped(_ word: String) -> Bool {
        let lowered = word.lowercased()
        guard !isLearned(lowered), !isRejected(lowered) else { return false }
        var count = 1
        if let index = seen.firstIndex(where: { $0.word == lowered }) {
            count = seen.remove(at: index).count + 1
        }
        guard count < Self.timesTypedToLearn else {
            Self.append(lowered, to: &learned, limit: Self.maximumRejected)
            return true
        }
        seen.append(Seen(word: lowered, count: count))
        if seen.count > Self.maximumSeen { seen.removeFirst(seen.count - Self.maximumSeen) }
        return false
    }

    private static func append(_ word: String, to list: inout [String], limit: Int) {
        list.removeAll { $0 == word }
        list.append(word)
        if list.count > limit { list.removeFirst(list.count - limit) }
    }
}

/// Where `TypingLearnedWords` lives between launches. The keyboard keeps it in its own defaults, which survive
/// launches and do not need Full Access; tests use an in-memory store.
@MainActor
protocol TypingLearnedWordsStoring: AnyObject {
    func load() -> TypingLearnedWords
    func save(_ words: TypingLearnedWords)
}

@MainActor
final class TypingLearnedWordsDefaults: TypingLearnedWordsStoring {
    static let defaultKey = "muesli.keyboard.learnedWords"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = TypingLearnedWordsDefaults.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> TypingLearnedWords {
        guard let data = defaults.data(forKey: key),
              let words = try? JSONDecoder().decode(TypingLearnedWords.self, from: data)
        else { return TypingLearnedWords() }
        return words
    }

    func save(_ words: TypingLearnedWords) {
        guard let data = try? JSONEncoder().encode(words) else { return }
        defaults.set(data, forKey: key)
    }
}
