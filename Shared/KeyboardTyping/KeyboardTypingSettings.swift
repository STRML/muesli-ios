import Foundation

/// What the Muesli keyboard reads from Settings through the shared store.
struct KeyboardTypingSettings: Codable, Sendable, Equatable {
    var autocorrect: Bool
    /// Dictated words appear in the host field while you speak, as marked text, and the final text replaces them.
    var liveTyping: Bool

    static let `default` = KeyboardTypingSettings(autocorrect: true)

    init(autocorrect: Bool, liveTyping: Bool = true) {
        self.autocorrect = autocorrect
        self.liveTyping = liveTyping
    }

    // A build from before live typing stored only `autocorrect`. Reading that must keep the autocorrect choice
    // and leave live typing on, not fail and fall back to the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autocorrect = try container.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? true
        liveTyping = try container.decodeIfPresent(Bool.self, forKey: .liveTyping) ?? true
    }
}
