import ClipFixtureKit
import XCTest
@testable import DictationPolicyKit

/// The whole guard against real files: what the engine is handed, what comes back, what is logged, what is cleaned up.
final class ClipSilenceGuardTests: XCTestCase {
    typealias Segment = HallucinatedTailFilter.Segment

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(String, [String: String])] = []
        private var _urls: [URL] = []
        private var _durations: [Double] = []
        func log(_ event: String, _ detail: [String: String]) { lock.lock(); _events.append((event, detail)); lock.unlock() }
        func saw(_ url: URL, duration: Double) { lock.lock(); _urls.append(url); _durations.append(duration); lock.unlock() }
        var events: [(String, [String: String])] { lock.lock(); defer { lock.unlock() }; return _events }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
        var durations: [Double] { lock.lock(); defer { lock.unlock() }; return _durations }
        func names() -> [String] { events.map(\.0) }
        func detail(_ name: String) -> [String: String]? { events.first { $0.0 == name }?.1 }
    }

    private let speech = TestAudio.speechLike()
    private var speechEnd: Double { Double(speech.count) / Double(TestAudio.rate) }

    private func write(_ samples: [Float], rate: Int = TestAudio.rate, channels: Int = 1, in directory: URL, name: String = "clip.wav") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try WavFile.write(WavFile.Clip(samples: samples, sampleRate: rate, channels: channels), to: url)
        return url
    }

    private func run(
        _ url: URL,
        options: ClipSilenceGuard.Options = .standard,
        recorder: Recorder,
        engine: @escaping @Sendable (URL) -> ClipSilenceGuard.EngineOutput
    ) async throws -> ClipSilenceGuard.Outcome {
        try await ClipSilenceGuard.run(audioURL: url, options: options, log: { recorder.log($0, $1) }) { handed in
            let duration = (try? WavFile.read(handed).duration) ?? -1
            recorder.saw(handed, duration: duration)
            return engine(handed)
        }
    }

    // MARK: trimming

    func testTheEngineIsHandedATrimmedCopyAndItIsRemovedAfterwards() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(speech + Synth.silence(4), in: directory)
        let recorder = Recorder()
        let outcome = try await run(original, recorder: recorder) { _ in .init(text: "Please send it.") }

        XCTAssertEqual(outcome.text, "Please send it.")
        XCTAssertNotEqual(recorder.urls.first, original)
        XCTAssertEqual(recorder.durations.first ?? 0, speechEnd + 0.25, accuracy: 0.05)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.urls[0].path), "the temporary copy is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "the original is never touched")
        let detail = try XCTUnwrap(recorder.detail("transcribe.trimmed"))
        XCTAssertEqual(detail["leading_ms"], "0")
        XCTAssertEqual(Double(detail["trailing_ms"] ?? "") ?? 0, (4 - 0.25) * 1000, accuracy: 60)
    }

    func testTheCopyIsRemovedWhenTheEngineThrows() async throws {
        struct Boom: Error {}
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(speech + Synth.silence(4), in: directory)
        let recorder = Recorder()
        do {
            _ = try await ClipSilenceGuard.run(audioURL: original, log: { recorder.log($0, $1) }) { handed in
                recorder.saw(handed, duration: 0)
                throw Boom()
            }
            XCTFail("the engine's error must propagate")
        } catch is Boom {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.urls[0].path))
    }

    func testLeadingSilenceIsTrimmedAndTheOffsetIsReported() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(Synth.silence(2) + speech, in: directory)
        let recorder = Recorder()
        let outcome = try await run(original, recorder: recorder) { _ in .init(text: "hi") }
        XCTAssertEqual(outcome.leadingOffset, 1.75, accuracy: 0.05)
        XCTAssertEqual(Double(recorder.detail("transcribe.trimmed")?["leading_ms"] ?? "") ?? 0, 1750, accuracy: 60)
    }

    func testSpeechWithNoSilenceAroundItIsHandedOverUntouched() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(speech, in: directory)
        let recorder = Recorder()
        let outcome = try await run(original, recorder: recorder) { _ in .init(text: "hi") }
        XCTAssertEqual(recorder.urls, [original])
        XCTAssertEqual(outcome.leadingOffset, 0)
        XCTAssertFalse(recorder.names().contains("transcribe.trimmed"))
    }

    func testRealSpeechWithTwoSecondsOfSilenceKeepsEveryWord() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let said = try TestAudio.sayClip("Please send the report by Friday afternoon", in: directory)
        let original = try write(said + Synth.silence(2), in: directory)
        let recorder = Recorder()
        _ = try await run(original, recorder: recorder) { _ in .init(text: "x") }
        let handed = Double(said.count) / Double(TestAudio.rate)
        XCTAssertGreaterThanOrEqual(recorder.durations[0], handed, "no sample of the spoken words is cut")
        XCTAssertLessThan(recorder.durations[0], handed + 0.6)
    }

    // MARK: silence

    func testAClipOfOnlySilenceIsNeverTranscribedAndReturnsNothing() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let recorder = Recorder()
        for samples in [Synth.silence(3), Synth.roomTone(3, rmsDB: -60), Synth.roomTone(3, rmsDB: -50)] {
            let original = try write(samples, in: directory)
            let outcome = try await run(original, recorder: recorder) { _ in .init(text: "Thank you.") }
            XCTAssertEqual(outcome.text, "")
            XCTAssertTrue(outcome.skippedAsSilent)
        }
        XCTAssertTrue(recorder.urls.isEmpty, "the engine heard nothing")
        XCTAssertEqual(recorder.names().filter { $0 == "transcribe.skipped_silent" }.count, 3)
    }

    func testRealSpeechQuietOverRoomToneIsHandedToTheEngine() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let said = SayFixtures.normalised(
            WavFile.Clip(samples: try TestAudio.sayClip("Please send the report by Friday afternoon", in: directory)),
            loudestFrameDB: -32
        ).samples
        let noisy = zip(said, Synth.roomTone(Double(said.count) / 16_000, rmsDB: -40)).map { $0 + $1 }
        let original = try write(noisy, in: directory)
        let recorder = Recorder()
        let outcome = try await run(original, recorder: recorder) { _ in .init(text: "Please send the report.") }
        XCTAssertFalse(outcome.skippedAsSilent)
        XCTAssertEqual(outcome.text, "Please send the report.")
        XCTAssertEqual(recorder.urls.count, 1)
    }

    // MARK: the post-filter

    func testAHallucinatedPhraseInTheUntrimmedTailIsDroppedAndLoggedWithoutItsText() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(speech + Synth.silence(3), in: directory)
        let recorder = Recorder()
        var options = ClipSilenceGuard.Options.standard
        options.trim = false
        let end = speechEnd
        let outcome = try await run(original, options: options, recorder: recorder) { _ in
            .init(
                text: "Please send it. Thank you.", language: "en",
                segments: [
                    Segment(text: " Please send it.", start: 0, end: end),
                    Segment(text: " Thank you.", start: end + 1, end: end + 2),
                ]
            )
        }
        XCTAssertEqual(outcome.text, "Please send it.")
        let detail = try XCTUnwrap(recorder.detail("transcribe.tail_dropped"))
        XCTAssertEqual(detail["reason"], "silent_segment")
        XCTAssertEqual(detail["phrase_len"], "\("Thank you.".count)")
        for (_, fields) in recorder.events {
            XCTAssertFalse(fields.values.contains { $0.localizedCaseInsensitiveContains("thank") }, "no content in the log")
        }
    }

    func testRemoteStyleTextWithoutSegmentsGoesThroughTheSameFilter() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(speech + Synth.silence(3), in: directory)
        var options = ClipSilenceGuard.Options.standard
        options.trim = false
        let outcome = try await run(original, options: options, recorder: Recorder()) { _ in
            .init(text: "Please send it. Thank you.")
        }
        XCTAssertEqual(outcome.text, "Please send it.")
    }

    func testAUserSayingThankYouThenTwoSecondsOfSilenceKeepsItOnce() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let said = try TestAudio.sayClip("Thank you", in: directory)
        let original = try write(said + Synth.silence(2), in: directory)
        let recorder = Recorder()
        let outcome = try await run(original, recorder: recorder) { _ in
            .init(text: "Thank you.", language: "en", segments: [Segment(text: " Thank you.", start: 0, end: Double(said.count) / 16_000)])
        }
        XCTAssertEqual(outcome.text, "Thank you.")
        XCTAssertFalse(recorder.names().contains("transcribe.tail_dropped"))
    }

    func testAnEngineThatStillDoublesThePhraseInTheKeptPadIsFilteredBackToOne() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let said = try TestAudio.sayClip("Thank you", in: directory)
        let end = Double(said.count) / 16_000
        let original = try write(said + Synth.silence(2), in: directory)
        let outcome = try await run(original, recorder: Recorder()) { _ in
            .init(
                text: "Thank you. Thank you.", language: "en",
                segments: [
                    Segment(text: " Thank you.", start: 0, end: end),
                    Segment(text: " Thank you.", start: end + 0.4, end: end + 0.9),
                ]
            )
        }
        XCTAssertEqual(outcome.text, "Thank you.")
    }

    func testFilteringCanBeSwitchedOffAndTheTextPassesThrough() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let original = try write(speech + Synth.silence(3), in: directory)
        var options = ClipSilenceGuard.Options.standard
        options.trim = false
        options.filter = false
        let outcome = try await run(original, options: options, recorder: Recorder()) { _ in
            .init(text: "Please send it. Thank you.")
        }
        XCTAssertEqual(outcome.text, "Please send it. Thank you.")
    }

    // MARK: failure and format rows

    func testAFileThatCannotBeReadIsPassedToTheEngineAsIs() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let broken = directory.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: broken)
        let recorder = Recorder()
        let outcome = try await run(broken, recorder: recorder) { _ in .init(text: "Done. Thank you.") }
        XCTAssertEqual(recorder.urls, [broken])
        XCTAssertEqual(outcome.text, "Done. Thank you.", "no profile, no proof, nothing dropped")
    }

    func testStereoAt44100IsTrimmedKeepingItsFormat() async throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let mono = Synth.voicedBurst(1.2, rate: 44_100) + Synth.silence(3, rate: 44_100)
        let stereo = mono.flatMap { [$0, $0 * 0.5] }
        let original = try write(stereo, rate: 44_100, channels: 2, in: directory)
        let recorder = Recorder()
        _ = try await run(original, recorder: recorder) { _ in .init(text: "hi") }
        let handed = recorder.durations[0]
        XCTAssertEqual(handed, 1.2 + 0.25, accuracy: 0.05)
    }

    func testTheCopyOfAStereoClipKeepsRateAndChannels() throws {
        let directory = try TestAudio.temporaryDirectory(self)
        let mono = Synth.voicedBurst(1.2, rate: 48_000) + Synth.silence(2, rate: 48_000)
        let original = try write(mono.flatMap { [$0, $0] }, rate: 48_000, channels: 2, in: directory)
        let profile = try ClipAudioIO.energyProfile(of: original)
        XCTAssertEqual(profile.duration, 3.2, accuracy: 0.02)
        let copy = directory.appendingPathComponent("copy.wav")
        try ClipAudioIO.writeTrimmedCopy(of: original, keepingFrames: 10..<150, to: copy)
        let clip = try WavFile.read(copy)
        XCTAssertEqual(clip.sampleRate, 48_000)
        XCTAssertEqual(clip.channels, 2)
        XCTAssertEqual(clip.duration, 1.4, accuracy: 0.011)
    }

    func testTheProfileOfALongFileIsBuiltInBoundedMemoryFromChunks() throws {
        let directory = try TestAudio.temporaryDirectory(self)
        // Ten minutes at 16 kHz is 19 MB of samples; written once, then only frame levels are ever held.
        let block = Synth.voicedBurst(10)
        var samples = [Float](); samples.reserveCapacity(block.count * 60)
        for _ in 0..<60 { samples += block }
        let original = try write(samples, in: directory)
        let profile = try ClipAudioIO.energyProfile(of: original)
        XCTAssertEqual(profile.duration, 600, accuracy: 0.05)
        XCTAssertEqual(profile.frameCount, 60_000, accuracy: 5)
    }
}
