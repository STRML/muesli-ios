import Foundation

/// The keyboard's one-line preview of what the streaming model has heard so far. The strip itself is display
/// only. With "Live typing" on, the same words are also typed into the host field as marked text
/// (`LiveTypingSession`), and the strip is the fallback view when the host cannot show them.
struct KeyboardLivePreview: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Still recording: the newest words, the recording dot and the elapsed time.
        case listening
        /// Recording ended and the final pass is running: the same words, dimmed, until the final text lands.
        case finalizing
    }

    let text: String
    let phase: Phase

    static func make(
        isRecording: Bool,
        isTranscribing: Bool,
        isRewriting: Bool,
        text: String,
        isFinal: Bool
    ) -> KeyboardLivePreview? {
        // The final text arrives as an isFinal transcript just before it is inserted; showing it would flash.
        guard !isFinal, !isRewriting else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isRecording { return KeyboardLivePreview(text: text, phase: .listening) }
        if isTranscribing { return KeyboardLivePreview(text: text, phase: .finalizing) }
        return nil
    }

    static func elapsedLabel(from start: Date?, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
