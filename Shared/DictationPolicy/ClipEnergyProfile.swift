import Foundation

/// Loudness of a clip as one dBFS value per 10 ms frame: the only thing the silence trimmer and the
/// hallucinated-tail filter look at. A frame is the RMS of the channel mix-down over 10 ms of samples, so an hour of
/// audio is 360,000 floats whatever the sample rate, and every pass over it is linear.
struct ClipEnergyProfile: Sendable, Equatable {
    static let frameSeconds: Double = 0.01
    /// Digital silence. Quieter than any converter's noise floor, so it never competes with real audio.
    static let silenceDB: Float = -120

    var frameDB: [Float]

    init(frameDB: [Float]) {
        self.frameDB = frameDB
    }

    var frameCount: Int { frameDB.count }
    var duration: TimeInterval { Double(frameDB.count) * Self.frameSeconds }

    static func db(rms: Float) -> Float {
        guard rms > 1e-6 else { return silenceDB }
        return max(silenceDB, 20 * log10(rms))
    }

    static func frame(atSeconds seconds: TimeInterval) -> Int {
        Int((max(0, seconds) / frameSeconds).rounded())
    }

    func slice(fromFrame start: Int, toFrame end: Int) -> ClipEnergyProfile {
        let lower = min(max(0, start), frameDB.count)
        let upper = min(max(lower, end), frameDB.count)
        return ClipEnergyProfile(frameDB: Array(frameDB[lower..<upper]))
    }
}

/// Folds mono samples into 10 ms frame levels as they stream in, so a long clip is analysed in fixed memory.
struct FrameEnergyAccumulator {
    private let samplesPerFrame: Int
    private var sumSquares: Double = 0
    private var inFrame = 0
    private(set) var frameDB: [Float] = []

    init(sampleRate: Double) {
        samplesPerFrame = max(1, Int((sampleRate * ClipEnergyProfile.frameSeconds).rounded()))
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            sumSquares += Double(sample) * Double(sample)
            inFrame += 1
            if inFrame == samplesPerFrame { closeFrame() }
        }
    }

    /// The last partial frame counts when it holds at least half a frame, so a clip is never one frame short.
    mutating func finish() -> ClipEnergyProfile {
        if inFrame * 2 >= samplesPerFrame { closeFrame() }
        return ClipEnergyProfile(frameDB: frameDB)
    }

    private mutating func closeFrame() {
        let rms = Float((sumSquares / Double(max(inFrame, 1))).squareRoot())
        frameDB.append(ClipEnergyProfile.db(rms: rms))
        sumSquares = 0
        inFrame = 0
    }
}
