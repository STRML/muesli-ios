import Foundation

/// A tiny 16-bit PCM WAV reader and writer, so fixtures are plain bytes the tests and the harness build themselves.
/// No AVFoundation: the trimmer's own file I/O must not be checked with the same code that produced the fixtures.
public enum WavFile {
    public struct Clip: Sendable {
        public var samples: [Float]
        public var sampleRate: Int
        public var channels: Int

        public init(samples: [Float], sampleRate: Int = 16_000, channels: Int = 1) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.channels = channels
        }

        /// Frames per channel.
        public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
        public var duration: Double { sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0 }
    }

    public enum Failure: Error { case notWav, unsupported }

    /// `samples` are interleaved when `channels` > 1. Values are clamped to [-1, 1] and quantised to 16 bits.
    public static func write(_ clip: Clip, to url: URL) throws {
        var data = Data()
        let dataBytes = clip.samples.count * 2
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func u16(_ value: Int) { var v = UInt16(value).littleEndian; data.append(Data(bytes: &v, count: 2)) }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(clip.channels)
        u32(clip.sampleRate); u32(clip.sampleRate * clip.channels * 2); u16(clip.channels * 2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        var pcm = [Int16](repeating: 0, count: clip.samples.count)
        for (index, sample) in clip.samples.enumerated() {
            pcm[index] = Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) throws -> Clip {
        let data = try Data(contentsOf: url)
        guard data.count >= 44, String(decoding: data[0..<4], as: UTF8.self) == "RIFF" else { throw Failure.notWav }
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        var offset = 12
        var channels = 1, rate = 16_000, bits = 16
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                guard bits == 16 else { throw Failure.unsupported }
                let end = min(data.count, body + size)
                var samples = [Float]()
                samples.reserveCapacity((end - body) / 2)
                var cursor = body
                while cursor + 1 < end {
                    samples.append(Float(Int16(truncatingIfNeeded: u16(cursor))) / 32768)
                    cursor += 2
                }
                return Clip(samples: samples, sampleRate: rate, channels: channels)
            }
            offset = body + size + (size & 1)
        }
        throw Failure.notWav
    }
}
