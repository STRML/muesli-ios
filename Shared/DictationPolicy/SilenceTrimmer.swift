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
        /// A trimmed copy is never shorter than this. WhisperKit decodes a window only while more than its
        /// `windowClipTime` (1 s) of audio remains, so a copy of 1 s or less transcribes to nothing at all.
        var minKeptSeconds: Double = 1.2
        /// Clips shorter than this are never trimmed; they are too short to tell speech from noise safely.
        var minClipSeconds: Double = 0.5
        /// A clip whose loud and quiet frames differ by less than this has no syllables: it is a hum, room tone, or
        /// speech so close to the noise that the two cannot be told apart.
        var steadyRangeDB: Float = 6
        /// A steady clip whose loudest frames are below this is room tone with nobody speaking: silent. Louder, it
        /// could be quiet speech over a fan, so the detector does not judge it (see `Analysis.indeterminate`).
        var steadySilentCeilingDB: Float = -42
        var steadyCeilingDB: Float = -30
        /// The loud reference is the level of this many of the clip's loudest frames (fewer in a very short clip).
        var loudReferenceSeconds: Double = 0.3
    }

    struct Plan: Sendable, Equatable {
        var hasSpeech: Bool
        var keepStartFrame: Int
        var keepEndFrame: Int
        var totalFrames: Int
        /// Where the last speech ends, or the end of the clip when it was not judged.
        var speechEndFrame: Int

        var leadingTrimSeconds: Double { Double(keepStartFrame) * ClipEnergyProfile.frameSeconds }
        var trailingTrimSeconds: Double { Double(totalFrames - keepEndFrame) * ClipEnergyProfile.frameSeconds }
        var isNoOp: Bool { keepStartFrame == 0 && keepEndFrame == totalFrames }
    }

    /// What the detector can say about a clip. Losing a real dictation is far worse than a stray "Thank you.", so
    /// anything it cannot prove empty is `indeterminate` and treated as speech everywhere.
    enum Analysis: Sendable, Equatable {
        /// Provably nothing said: quieter than any speech, or only quiet steady noise.
        case silent
        /// Steady and not quiet enough to rule out speech (quiet speech over a fan, a loud hum). Nothing is cut,
        /// nothing is skipped and nothing is filtered.
        case indeterminate
        /// Where the speech is, in frames, in order.
        case speech([Range<Int>])
    }

    static func plan(for profile: ClipEnergyProfile, config: Config = .standard) -> Plan {
        let total = profile.frameCount
        let untouched = Plan(hasSpeech: true, keepStartFrame: 0, keepEndFrame: total, totalFrames: total, speechEndFrame: total)
        let spans: [Range<Int>]
        switch analyse(profile, config: config) {
        case .silent: return Plan(hasSpeech: false, keepStartFrame: 0, keepEndFrame: total, totalFrames: total, speechEndFrame: total)
        case .indeterminate: return untouched
        case .speech(let found): spans = found
        }
        guard let first = spans.first, let last = spans.last else { return untouched }
        guard profile.duration >= config.minClipSeconds else {
            return Plan(hasSpeech: true, keepStartFrame: 0, keepEndFrame: total, totalFrames: total, speechEndFrame: last.upperBound)
        }

        let pad = frames(config.padSeconds)
        let minTrim = frames(config.minTrimSeconds)
        var start = max(0, first.lowerBound - pad)
        var end = min(total, last.upperBound + pad)
        let deficit = frames(config.minKeptSeconds) - (end - start)
        if deficit > 0 {
            let forward = min(deficit, total - end)
            end += forward
            start = max(0, start - (deficit - forward))
        }
        if start < minTrim { start = 0 }
        if total - end < minTrim { end = total }
        return Plan(hasSpeech: true, keepStartFrame: start, keepEndFrame: end, totalFrames: total, speechEndFrame: last.upperBound)
    }

    static func analyse(_ profile: ClipEnergyProfile, config: Config = .standard) -> Analysis {
        switch gate(for: profile, config: config) {
        case .silent: return .silent
        case .indeterminate: return .indeterminate
        case .level(let level):
            let spans = speechSpans(in: profile, gate: level, config: config)
            return spans.isEmpty ? .silent : .speech(spans)
        }
    }

    private static func speechSpans(in profile: ClipEnergyProfile, gate: Float, config: Config) -> [Range<Int>] {
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

    private enum Gate { case silent, indeterminate, level(Float) }

    /// The level a frame must reach to count as speech.
    private static func gate(for profile: ClipEnergyProfile, config: Config) -> Gate {
        guard !profile.frameDB.isEmpty else { return .silent }
        let histogram = LevelHistogram(profile.frameDB)
        let rank = min(max(1, profile.frameCount / 10), max(1, frames(config.loudReferenceSeconds)))
        let loud = histogram.level(fromTop: rank)
        guard loud >= config.absoluteFloorDB else { return .silent }
        let quiet = histogram.level(fromBottomFraction: 0.1)
        if loud - quiet < config.steadyRangeDB, loud < config.steadyCeilingDB {
            return loud < config.steadySilentCeilingDB ? .silent : .indeterminate
        }
        return .level(max(config.absoluteFloorDB, loud - config.belowLoudDB))
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
