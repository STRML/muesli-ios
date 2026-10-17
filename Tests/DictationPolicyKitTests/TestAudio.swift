import ClipFixtureKit
import Foundation
import XCTest
@testable import DictationPolicyKit

/// Shared helpers for the silence-guard tests.
enum TestAudio {
    static let rate = Synth.sampleRate

    static func profile(_ samples: [Float], rate: Int = TestAudio.rate) -> ClipEnergyProfile {
        var accumulator = FrameEnergyAccumulator(sampleRate: Double(rate))
        samples.withUnsafeBufferPointer { accumulator.add($0) }
        return accumulator.finish()
    }

    /// A stand-in for "speech, a pause, speech": two voiced bursts with a short gap, 1.8 s in all.
    static func speechLike() -> [Float] {
        Synth.voicedBurst(0.8) + Synth.silence(0.2) + Synth.voicedBurst(0.8)
    }

    static func seconds(_ frame: Int) -> Double { Double(frame) * ClipEnergyProfile.frameSeconds }

    static func temporaryDirectory(_ test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Real speech from `say`, scaled to phone-microphone level. Skips where `say` is missing (Linux CI, sandboxes).
    static func sayClip(_ text: String, in directory: URL) throws -> [Float] {
        guard SayFixtures.isAvailable else { throw XCTSkip("/usr/bin/say is not available") }
        do {
            return SayFixtures.normalised(try SayFixtures.speech(text, in: directory)).samples
        } catch {
            throw XCTSkip("say could not synthesise speech here: \(error)")
        }
    }
}
