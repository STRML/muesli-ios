import AVFoundation

/// What the recorder left on disk, read from the file header only. Counts and sizes, never content.
struct AudioFileFacts: Equatable {
    var frames: Int
    var durationMs: Int
    var bytes: Int

    static func read(_ url: URL) -> AudioFileFacts? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let frames = Int(file.length)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        return AudioFileFacts(
            frames: frames,
            durationMs: rate > 0 ? Int(Double(frames) / rate * 1_000) : 0,
            bytes: bytes
        )
    }
}
