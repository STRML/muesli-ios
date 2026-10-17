import Foundation

/// Finds where the speech in a clip starts and ends, so the silence around it is never transcribed.
///
/// Whisper-family models invent text ("Thank you.") for the silent or near-silent stretch after the last word, so the
/// cheapest fix is not to hand them that stretch. The detector is deliberately conservative: it only ever cuts at the
/// two ends of a clip (a pause between words is never touched), it keeps a pad of silence next to the speech so a soft
/// word ending is not clipped, and it declines to trim clips too short to judge.
///
/// "Speech" is a frame louder than a gate that follows the clip itself: 18 dB under the loudest sustained part, but
/// never below an absolute floor. That keeps a quiet speaker in a quiet room and a loud speaker in a noisy one both
/// working without a calibrated level. Everything is linear in the clip length (a 1,000-bin histogram and two scans).
enum SilenceTrimmer {
    struct Config: Sendable, Equatable {
        static let standard = Config()
        /// Nothing quieter than this RMS level is speech, however quiet the rest of the clip is.
        var absoluteFloorDB: Float = -50
        /// The gate sits this far under the loud reference. Room tone at -40 dBFS under speech at -16 stays below it.
        var belowLoudDB: Float = 18
        /// A louder stretch must last this long to count: a key click or a pop is not a word.
        var minSpeechSeconds: Double = 0.06
        /// Gaps shorter than this inside speech do not split it (plosive closures, a breath between two words).
        var bridgeSeconds: Double = 0.30
        /// Silence kept on each side of the speech.
        var padSeconds: Double = 0.25
        /// A cut smaller than this is not worth rewriting the file for.
        var minTrimSeconds: Double = 0.2
        /// Clips shorter than this are never trimmed; they are too short to tell speech from noise safely.
        var minClipSeconds: Double = 0.5
        /// A clip whose loud and quiet frames differ by less than this, and which is quiet overall, is a hum or room
        /// tone: it has no syllables.
        var steadyRangeDB: Float = 6
        var steadyCeilingDB: Float = -30
        /// The loud reference is the level of this many of the clip's loudest frames (fewer in a very short clip).
        var loudReferenceSeconds: Double = 0.3
    }

    struct Plan: Sendable, Equatable {
        var hasSpeech: Bool
        var keepStartFrame: Int
        var keepEndFrame: Int
        var totalFrames: Int

        var leadingTrimSeconds: Double { Double(keepStartFrame) * ClipEnergyProfile.frameSeconds }
        var trailingTrimSeconds: Double { Double(totalFrames - keepEndFrame) * ClipEnergyProfile.frameSeconds }
        var isNoOp: Bool { keepStartFrame == 0 && keepEndFrame == totalFrames }
    }

    static func plan(for profile: ClipEnergyProfile, config: Config = .standard) -> Plan {
        let total = profile.frameCount
        let spans = speechSpans(in: profile, config: config)
        guard let first = spans.first, let last = spans.last else {
            return Plan(hasSpeech: false, keepStartFrame: 0, keepEndFrame: total, totalFrames: total)
        }
        let untouched = Plan(hasSpeech: true, keepStartFrame: 0, keepEndFrame: total, totalFrames: total)
        guard profile.duration >= config.minClipSeconds else { return untouched }

        let pad = frames(config.padSeconds)
        let minTrim = frames(config.minTrimSeconds)
        var start = max(0, first.lowerBound - pad)
        var end = min(total, last.upperBound + pad)
        if start < minTrim { start = 0 }
        if total - end < minTrim { end = total }
        return Plan(hasSpeech: true, keepStartFrame: start, keepEndFrame: end, totalFrames: total)
    }

    /// The stretches of the clip that hold speech, in frames, in order and non-overlapping. Empty when there is none.
    static func speechSpans(in profile: ClipEnergyProfile, config: Config = .standard) -> [Range<Int>] {
        guard let gate = gate(for: profile, config: config) else { return [] }
        let minFrames = max(1, frames(config.minSpeechSeconds))
        let bridge = max(1, frames(config.bridgeSeconds))
        let levels = profile.frameDB

        var spans = [Range<Int>]()
        var runStart: Int?
        var lastVoiced = 0
        var voicedCount = 0
        func close() {
            if let runStart, voicedCount >= minFrames { spans.append(runStart..<(lastVoiced + 1)) }
            runStart = nil
            voicedCount = 0
        }
        for (index, level) in levels.enumerated() where level >= gate {
            if runStart != nil, index - lastVoiced > bridge { close() }
            if runStart == nil { runStart = index }
            lastVoiced = index
            voicedCount += 1
        }
        close()
        return spans
    }

    /// The level a frame must reach to count as speech, or nil when the clip has none.
    private static func gate(for profile: ClipEnergyProfile, config: Config) -> Float? {
        guard !profile.frameDB.isEmpty else { return nil }
        let histogram = LevelHistogram(profile.frameDB)
        let rank = min(max(1, profile.frameCount / 10), max(1, frames(config.loudReferenceSeconds)))
        let loud = histogram.level(fromTop: rank)
        guard loud >= config.absoluteFloorDB else { return nil }
        let quiet = histogram.level(fromBottomFraction: 0.1)
        if loud - quiet < config.steadyRangeDB, loud < config.steadyCeilingDB { return nil }
        return max(config.absoluteFloorDB, loud - config.belowLoudDB)
    }

    private static func frames(_ seconds: Double) -> Int {
        Int((seconds / ClipEnergyProfile.frameSeconds).rounded())
    }
}

/// Half-decibel histogram of frame levels: percentile lookups in O(bins) for any clip length.
private struct LevelHistogram {
    private static let lowest: Float = ClipEnergyProfile.silenceDB
    private static let binsPerDB: Float = 2
    private var counts: [Int]
    private let total: Int

    init(_ levels: [Float]) {
        let bins = Int((6 - Self.lowest) * Self.binsPerDB) + 1
        var counts = [Int](repeating: 0, count: bins)
        for level in levels { counts[Self.bin(level)] += 1 }
        self.counts = counts
        total = levels.count
    }

    /// The level of the `rank`-th loudest frame (1 is the loudest).
    func level(fromTop rank: Int) -> Float {
        var seen = 0
        for bin in stride(from: counts.count - 1, through: 0, by: -1) {
            seen += counts[bin]
            if seen >= rank { return Self.level(of: bin) }
        }
        return Self.lowest
    }

    func level(fromBottomFraction fraction: Double) -> Float {
        let rank = max(1, Int((Double(total) * fraction).rounded(.up)))
        var seen = 0
        for bin in 0..<counts.count {
            seen += counts[bin]
            if seen >= rank { return Self.level(of: bin) }
        }
        return Self.lowest
    }

    private static func bin(_ level: Float) -> Int {
        Int(((min(max(level, lowest), 6) - lowest) * binsPerDB).rounded(.down))
    }

    private static func level(of bin: Int) -> Float {
        lowest + Float(bin) / binsPerDB
    }
}
