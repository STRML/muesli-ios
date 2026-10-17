import ClipFixtureKit
import XCTest
@testable import DictationPolicyKit

/// Where the speech in a clip starts and ends. One test per failure-matrix row.
final class SilenceTrimmerTests: XCTestCase {
    private let speech = TestAudio.speechLike()
    private var speechSeconds: Double { Double(speech.count) / Double(TestAudio.rate) }

    private func plan(_ samples: [Float]) -> SilenceTrimmer.Plan {
        SilenceTrimmer.plan(for: TestAudio.profile(samples))
    }

    // MARK: speech with no trailing silence

    func testSpeechWithNoTrailingSilenceIsLeftAlone() {
        let plan = plan(speech)
        XCTAssertTrue(plan.hasSpeech)
        XCTAssertTrue(plan.isNoOp, "nothing to cut: \(plan)")
    }

    func testTheLastWordKeepsItsEnergyAndAPadAfterIt() {
        let samples = speech + Synth.silence(2)
        let plan = plan(samples)
        let kept = Array(samples[0..<plan.keepEndFrame * TestAudio.rate / 100])
        XCTAssertGreaterThanOrEqual(kept.count, speech.count, "the word-final samples must survive")
        let tailOfSpeech = kept[(speech.count - TestAudio.rate / 10)..<speech.count]
        XCTAssertGreaterThan(Synth.rmsDB(tailOfSpeech), -30, "the last 100 ms of the last word is still there")
        XCTAssertEqual(plan.keepEndFrame, Int((speechSeconds + 0.25) * 100), accuracy: 3, "speech end plus a 250 ms pad")
    }

    // MARK: trailing silence and noise

    func testTrailingSilenceIsCutAtOneTwoAndFourSeconds() {
        for seconds in [1.0, 2.0, 4.0] {
            let plan = plan(speech + Synth.silence(seconds))
            XCTAssertTrue(plan.hasSpeech)
            XCTAssertEqual(plan.trailingTrimSeconds, seconds - 0.25, accuracy: 0.05, "\(seconds) s of silence")
            XCTAssertEqual(plan.leadingTrimSeconds, 0, accuracy: 0.001)
        }
    }

    func testTrailingRoomToneIsCutAtMinus50AndMinus40() {
        for level in [-50.0, -40.0] {
            let plan = plan(speech + Synth.roomTone(3, rmsDB: level))
            XCTAssertEqual(plan.trailingTrimSeconds, 3 - 0.25, accuracy: 0.1, "room tone at \(level) dBFS")
        }
    }

    func testAShortKeyboardTapAfterTheSpeechIsNotSpeech() {
        let plan = plan(speech + Synth.silence(0.5) + Synth.keyboardTap() + Synth.silence(1))
        XCTAssertEqual(plan.keepEndFrame, Int((speechSeconds + 0.25) * 100), accuracy: 3, "the tap is cut with the tail")
    }

    func testALoudSustainedBurstAtTheEndIsKept() {
        let burst = Synth.voicedBurst(0.2, rmsDB: -10)
        let plan = plan(speech + Synth.silence(1) + burst)
        XCTAssertGreaterThanOrEqual(plan.keepEndFrame, Int((speechSeconds + 1 + 0.2) * 100) - 2, "a 200 ms loud sound is not silence")
    }

    // MARK: nothing but silence or noise

    func testAClipOfOnlySilenceHasNoSpeech() {
        XCTAssertFalse(plan(Synth.silence(3)).hasSpeech)
    }

    func testAClipOfOnlyVeryQuietRoomToneHasNoSpeech() {
        for level in [-60.0, -50.0, -45.0] {
            XCTAssertFalse(plan(Synth.roomTone(3, rmsDB: level)).hasSpeech, "room tone at \(level) dBFS")
        }
    }

    // MARK: quiet speech over noise is never called silent

    func testQuietSpeechOverRoomToneIsNeverSkipped() {
        for (speechDB, noiseDB) in [(-34.0, -38.0), (-32.0, -36.0), (-30.0, -34.0), (-36.0, -42.0)] {
            let mixed = zip(Synth.voicedBurst(2.5, rmsDB: speechDB), Synth.roomTone(2.5, rmsDB: noiseDB)).map { $0 + $1 }
            let plan = plan(mixed)
            XCTAssertTrue(plan.hasSpeech, "speech at \(speechDB) over noise at \(noiseDB) dBFS")
            XCTAssertEqual(plan.keepStartFrame, 0, "when the detector cannot tell, it keeps everything")
            XCTAssertEqual(plan.keepEndFrame, plan.totalFrames)
        }
    }

    func testASteadyNoiseFloorTheDetectorCannotJudgeIsHandedOverWhole() {
        let plan = plan(Synth.roomTone(3, rmsDB: -40))
        XCTAssertTrue(plan.hasSpeech, "-40 dBFS could be a whisper over a fan: not skipped")
        XCTAssertTrue(plan.isNoOp)
    }

    func testAnEmptyClipHasNoSpeech() {
        XCTAssertFalse(plan([]).hasSpeech)
    }

    // MARK: leading silence

    func testLeadingSilenceIsCutWithAPadBeforeTheFirstWord() {
        let plan = plan(Synth.silence(2) + speech)
        XCTAssertEqual(plan.leadingTrimSeconds, 2 - 0.25, accuracy: 0.05)
        XCTAssertEqual(plan.trailingTrimSeconds, 0, accuracy: 0.001)
    }

    func testBothEndsAreTrimmedAndAPauseInsideIsNeverTouched() {
        let inner = Synth.voicedBurst(0.6) + Synth.silence(1.5) + Synth.voicedBurst(0.6)
        let plan = plan(Synth.silence(1) + inner + Synth.silence(2))
        XCTAssertEqual(plan.keepStartFrame, 75, accuracy: 3)
        XCTAssertEqual(plan.keepEndFrame, Int((1 + 2.7 + 0.25) * 100), accuracy: 3, "the 1.5 s pause between the words stays")
    }

    // MARK: very short clips

    func testAClipUnderHalfASecondIsNeverTrimmed() {
        let word = Synth.voicedBurst(0.2)
        let plan = plan(Synth.silence(0.15) + word)
        XCTAssertTrue(plan.hasSpeech)
        XCTAssertTrue(plan.isNoOp, "a 0.35 s clip is too short to trim safely: \(plan)")
    }

    func testAShortSilentClipStillHasNoSpeech() {
        XCTAssertFalse(plan(Synth.silence(0.3)).hasSpeech)
    }

    // MARK: level and waveform extremes

    func testQuietSpeechIsStillSpeech() {
        let quiet = Synth.voicedBurst(1.5, rmsDB: -38)
        let plan = plan(quiet + Synth.silence(2))
        XCTAssertTrue(plan.hasSpeech)
        XCTAssertEqual(plan.keepEndFrame, Int((1.5 + 0.25) * 100), accuracy: 3)
    }

    func testSaturatedAudioIsSpeechAndItsTailIsCut() {
        let square = (0..<(2 * TestAudio.rate)).map { Float(($0 / 40) % 2 == 0 ? 1 : -1) }
        let plan = plan(square + Synth.silence(2))
        XCTAssertTrue(plan.hasSpeech)
        XCTAssertEqual(plan.trailingTrimSeconds, 2 - 0.25, accuracy: 0.05)
    }

    func testAQuietSteadyHumIsHandedOverWhole() {
        let hum = (0..<(3 * TestAudio.rate)).map { Float(sin(2 * Double.pi * 60 * Double($0) / 16_000)) * 0.02 }
        let plan = plan(hum)
        XCTAssertTrue(plan.hasSpeech, "a 60 Hz hum at about -37 dBFS has no syllables, but it is not provably empty")
        XCTAssertTrue(plan.isNoOp)
    }

    // MARK: cost on long clips

    func testAnHourOfAudioIsPlannedInLinearTime() {
        func frames(minutes: Double) -> ClipEnergyProfile {
            let count = Int(minutes * 6000)
            // Speech-level frames with a long silent tail, like a long voice note that was left running.
            return ClipEnergyProfile(frameDB: (0..<count).map { $0 < count * 9 / 10 ? Float(-25 + ($0 % 7)) : -90 })
        }
        let clock = ContinuousClock()
        let short = clock.measure { _ = SilenceTrimmer.plan(for: frames(minutes: 15)) }
        let long = clock.measure { _ = SilenceTrimmer.plan(for: frames(minutes: 60)) }
        let plan = SilenceTrimmer.plan(for: frames(minutes: 60))
        XCTAssertTrue(plan.hasSpeech)
        XCTAssertEqual(plan.trailingTrimSeconds, 3600 * 0.1 - 0.25, accuracy: 1)
        XCTAssertLessThan(long, .seconds(2))
        XCTAssertLessThan(long / max(short, .milliseconds(1)), 12, "4x the audio must not cost more than ~4x (not quadratic)")
    }

    func testTheAccumulatorHoldsOnlyFramesNotSamples() {
        var accumulator = FrameEnergyAccumulator(sampleRate: 16_000)
        let block = Synth.voicedBurst(1)
        for _ in 0..<600 { block.withUnsafeBufferPointer { accumulator.add($0) } }   // ten minutes, one second at a time
        let profile = accumulator.finish()
        XCTAssertEqual(profile.frameCount, 60_000, accuracy: 1)
        XCTAssertEqual(profile.duration, 600, accuracy: 0.02)
    }
}
