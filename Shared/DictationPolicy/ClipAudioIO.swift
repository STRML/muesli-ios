import AVFoundation
import Foundation

/// The file side of the silence guard: reads a clip's loudness and writes a trimmed copy. Both stream the file in
/// 32k-frame blocks, so memory stays flat however long the clip is, and both work in the file's own sample rate and
/// channel count: nothing is resampled here, because the engine resamples anyway.
enum ClipAudioIO {
    enum Failure: Error { case emptyRange, bufferUnavailable }

    private static let blockFrames: AVAudioFrameCount = 32_768

    /// Loudness per 10 ms frame. Channels are folded into the frame's level by averaging their power, so a clip with
    /// speech on one channel of a stereo file still reads as speech.
    static func energyProfile(of url: URL) throws -> ClipEnergyProfile {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var accumulator = FrameEnergyAccumulator(sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw Failure.bufferUnavailable
        }
        let channelCount = Int(format.channelCount)
        var mixed = [Float](repeating: 0, count: Int(blockFrames))

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            if channelCount == 1 {
                accumulator.add(UnsafeBufferPointer(start: channels[0], count: frames))
            } else {
                for frame in 0..<frames {
                    var power: Float = 0
                    for channel in 0..<channelCount { power += channels[channel][frame] * channels[channel][frame] }
                    mixed[frame] = (power / Float(channelCount)).squareRoot()
                }
                mixed.withUnsafeBufferPointer { accumulator.add(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
            }
        }
        return accumulator.finish()
    }

    /// Writes 16-bit PCM WAV holding the 10 ms frames in `range` of `url`, at the source's sample rate and channels.
    static func writeTrimmedCopy(of url: URL, keepingFrames range: Range<Int>, to destination: URL) throws {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let samplesPerFrame = format.sampleRate * ClipEnergyProfile.frameSeconds
        let startSample = AVAudioFramePosition((Double(range.lowerBound) * samplesPerFrame).rounded())
        let endSample = min(source.length, AVAudioFramePosition((Double(range.upperBound) * samplesPerFrame).rounded()))
        guard endSample > startSample else { throw Failure.emptyRange }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw Failure.bufferUnavailable
        }
        source.framePosition = startSample
        while source.framePosition < endSample {
            let wanted = AVAudioFrameCount(min(AVAudioFramePosition(blockFrames), endSample - source.framePosition))
            try source.read(into: buffer, frameCount: wanted)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
