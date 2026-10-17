import Foundation

/// What the Muesli keyboard reads from Settings through the shared store.
struct KeyboardTypingSettings: Codable, Sendable, Equatable {
    var autocorrect: Bool
    /// Dictated words appear in the host field while you speak, as marked text, and the final text replaces them.
    var liveTyping: Bool
    /// Full or minimal keyboard. Applied when the keyboard next appears, never while it is up.
    var layout: KeyboardLayout

    static let `default` = KeyboardTypingSettings(autocorrect: true)

    init(autocorrect: Bool, liveTyping: Bool = true, layout: KeyboardLayout = .full) {
        self.autocorrect = autocorrect
        self.liveTyping = liveTyping
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey {
        case autocorrect, liveTyping, layout
    }

    // A build from before live typing stored only `autocorrect`. Reading that must keep the autocorrect choice
    // and leave live typing on, not fail and fall back to the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autocorrect = try container.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? true
        liveTyping = try container.decodeIfPresent(Bool.self, forKey: .liveTyping) ?? true
        layout = .full
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autocorrect, forKey: .autocorrect)
        try container.encode(liveTyping, forKey: .liveTyping)
        try container.encode(layout.storedValue, forKey: .layout)
    }
}
