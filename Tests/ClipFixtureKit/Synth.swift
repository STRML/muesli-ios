import Foundation

/// Deterministic test signals. Everything is seeded, so a failing assertion reproduces byte for byte.
public enum Synth {
    public static let sampleRate = 16_000

    public static func dB(_ level: Double) -> Float { Float(pow(10, level / 20)) }

    public static func silence(_ seconds: Double, rate: Int = sampleRate) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// Room tone: seeded white noise scaled to the given RMS level in dBFS.
    public static func roomTone(_ seconds: Double, rmsDB: Double, seed: UInt64 = 7, rate: Int = sampleRate) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let amplitude = dB(rmsDB) * 3.0.squareRoot().asFloat   // uniform [-1, 1] has RMS 1/sqrt(3)
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
            return unit * amplitude
        }
    }

    /// A key press: a few ms of broadband click, nowhere near a syllable long.
    public static func keyboardTap(peakDB: Double = -12, rate: Int = sampleRate) -> [Float] {
        let count = Int(0.015 * Double(rate))
        let peak = dB(peakDB)
        return (0..<count).map { index in
            let decay = Float(exp(-Double(index) / (0.004 * Double(rate))))
            return peak * decay * (index % 2 == 0 ? 1 : -1) * 0.9
        }
    }

    /// A stand-in for speech: a 140 Hz harmonic stack under a 5 Hz syllable envelope, `rmsDB` over the voiced part.
    /// Real speech comes from `say` in the tests that need it; this keeps the logic tests hermetic.
    public static func voicedBurst(_ seconds: Double, rmsDB: Double = -20, rate: Int = sampleRate) -> [Float] {
        let count = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            var voiced = 0.0
            for harmonic in 1...8 { voiced += sin(2 * .pi * 140 * Double(harmonic) * t) / Double(harmonic) }
            let syllable = 0.55 + 0.45 * sin(2 * .pi * 5 * t - .pi / 2)
            let edge = min(1, t / 0.02, (seconds - t) / 0.02)
            out[index] = Float(voiced * syllable * max(0, edge))
        }
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Float(max(count, 1))).squareRoot()
        let gain = rms > 0 ? dB(rmsDB) / rms : 0
        return out.map { $0 * gain }
    }

    public static func rmsDB(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -120 }
        let mean = samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return mean > 1e-12 ? 10 * log10(mean) : -120
    }
}

private extension Double {
    var asFloat: Float { Float(self) }
}
