import Foundation
@preconcurrency import WhisperKit

/// The decode options the app gives WhisperKit. Kept in one file with no app dependencies so the Mac harness
/// (Tests/TailHarness) measures exactly what ships.
///
/// What was measured on large-v3-v20240930_626MB (324 `say` clips, README in Tests/TailHarness) and what it means here:
/// - `noSpeechThreshold` does nothing: the pinned WhisperKit revision never computes a no-speech probability
///   (`TextDecoder.swift`: `let noSpeechProb: Float = 0 // TODO`), so the skip it feeds can never fire. Not set.
/// - `suppressBlank`, `compressionRatioThreshold` and the temperature fallback change no output on silent tails.
/// - `logProbThreshold` -0.5 removes the tail after digital silence and room tone but not after a key tap.
/// - `withoutTimestamps` removes the artefact on every tail we generated. The artefact is a timestamped segment
///   decoded over padded silence; without timestamp tokens the model has no segment to invent. It is used only for a
///   clip that fits one 30 s window, because WhisperKit finds the seek point of the next window from the last
///   timestamp: without timestamps a longer clip would be cut at the window edge, mid-word.
/// - `windowClipTime` stays at WhisperKit's 1 s. Lowering it to 0.3 s let the artefact back in after a 0.3 s tail.
enum WhisperKitDecodingOptions {
    /// A 30 s window with room to spare: longer clips keep timestamps so WhisperKit can seek between windows.
    static let singleWindowSeconds: TimeInterval = 28

    static func options(forAudioSeconds seconds: TimeInterval?) -> DecodingOptions {
        var options = DecodingOptions()
        if let seconds, seconds <= singleWindowSeconds {
            options.withoutTimestamps = true
        }
        return options
    }
}
