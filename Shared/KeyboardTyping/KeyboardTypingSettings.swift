import Foundation

/// What the Muesli keyboard reads from Settings through the shared store. Without Full Access the store is
/// unreachable and the keyboard uses `default`: autocorrect and live typing on, the full layout.
struct KeyboardTypingSettings: Codable, Sendable, Equatable {
    var autocorrect: Bool
    /// Dictated words appear in the host field while you speak, as marked text, and the final text replaces them.
    var liveTyping: Bool
    /// Full or minimal keyboard. Applied when the keyboard next appears, never while it is up.
    var layout: KeyboardLayout
    /// Full switches to the Dictate panel while a dictation records or transcribes. Off keeps the Type page, whose
    /// strip then carries the live status.
    var showsDictatePanelWhileRecording: Bool

    static let `default` = KeyboardTypingSettings(autocorrect: true)

    init(
        autocorrect: Bool,
        liveTyping: Bool = true,
        layout: KeyboardLayout = .full,
        showsDictatePanelWhileRecording: Bool = false
    ) {
        self.autocorrect = autocorrect
        self.liveTyping = liveTyping
        self.layout = layout
        self.showsDictatePanelWhileRecording = showsDictatePanelWhileRecording
    }

    private enum CodingKeys: String, CodingKey {
        case autocorrect, liveTyping, layout, showsDictatePanelWhileRecording
    }

    // A build from before live typing stored only `autocorrect`. Reading that must keep the autocorrect choice
    // and leave live typing on, not fail and fall back to the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autocorrect = try container.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? true
        liveTyping = try container.decodeIfPresent(Bool.self, forKey: .liveTyping) ?? true
        // Only the layout read may fail quietly: a wrong type there must not cost the user their other two choices.
        layout = (try? container.decodeIfPresent(String.self, forKey: .layout))
            .flatMap(KeyboardLayout.init(rawValue:)) ?? .fallback
        showsDictatePanelWhileRecording = (try? container.decodeIfPresent(Bool.self, forKey: .showsDictatePanelWhileRecording))
            .flatMap { $0 } ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autocorrect, forKey: .autocorrect)
        try container.encode(liveTyping, forKey: .liveTyping)
        try container.encode(layout.rawValue, forKey: .layout)
        try container.encode(showsDictatePanelWhileRecording, forKey: .showsDictatePanelWhileRecording)
    }
}
