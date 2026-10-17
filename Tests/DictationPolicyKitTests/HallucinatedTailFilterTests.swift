import ClipFixtureKit
import XCTest
@testable import DictationPolicyKit

/// The last-resort filter: a known phrase, last, over audio with no speech in it. One test per failure-matrix row.
final class HallucinatedTailFilterTests: XCTestCase {
    typealias Segment = HallucinatedTailFilter.Segment

    // A 1.8 s message of speech followed by 3 s of silence, then the engine "hears" a phrase in the silence.
    private let speech = TestAudio.speechLike()
    private var speechEnd: Double { Double(speech.count) / Double(TestAudio.rate) }

    private func profile(tail: [Float]) -> ClipEnergyProfile {
        TestAudio.profile(speech + tail)
    }

    private func apply(
        _ text: String,
        segments: [Segment] = [],
        language: String? = "en",
        profile: ClipEnergyProfile
    ) -> HallucinatedTailFilter.Result {
        HallucinatedTailFilter.apply(text: text, segments: segments, language: language, profile: profile)
    }

    // MARK: segments with timestamps

    func testAThankYouOverSilenceAfterTheSpeechIsDropped() {
        let profile = profile(tail: Synth.silence(3))
        let result = apply(
            "Please send it. Thank you.",
            segments: [
                Segment(text: " Please send it.", start: 0, end: speechEnd),
                Segment(text: " Thank you.", start: speechEnd + 1, end: speechEnd + 2),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Please send it.")
        XCTAssertEqual(result.dropped, [.init(reason: .silentSegment, phraseLength: "Thank you.".count)])
    }

    func testAThankYouTheSpeakerReallySaidIsKept() {
        let profile = TestAudio.profile(speech + Synth.silence(0.2) + Synth.voicedBurst(0.7))
        let thankYouStart = speechEnd + 0.2
        let result = apply(
            "Please send it. Thank you.",
            segments: [
                Segment(text: " Please send it.", start: 0, end: speechEnd),
                Segment(text: " Thank you.", start: thankYouStart, end: thankYouStart + 0.7),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Please send it. Thank you.")
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testAThankYouSaidForRealAndRepeatedOverSilenceIsKeptOnce() {
        let profile = TestAudio.profile(speech + Synth.silence(0.1) + Synth.voicedBurst(0.7) + Synth.silence(3))
        let said = speechEnd + 0.1
        let result = apply(
            "Please send it. Thank you. Thank you.",
            segments: [
                Segment(text: " Please send it.", start: 0, end: speechEnd),
                Segment(text: " Thank you.", start: said, end: said + 0.7),
                Segment(text: " Thank you.", start: said + 1.5, end: said + 2.5),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Please send it. Thank you.")
        XCTAssertEqual(result.dropped.count, 1)
    }

    func testASegmentPastTheEndOfTheAudioIsSilent() {
        let profile = profile(tail: Synth.silence(0.3))
        let result = apply(
            "Done. Thank you.",
            segments: [
                Segment(text: " Done.", start: 0, end: speechEnd),
                Segment(text: " Thank you.", start: 10, end: 11),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Done.")
    }

    func testASegmentTimedALittleLateStillCountsAsTheWordsBeforeIt() {
        let profile = profile(tail: Synth.silence(3))
        let result = apply(
            "Done. Thank you.",
            segments: [
                Segment(text: " Done.", start: 0, end: speechEnd),
                Segment(text: " Thank you.", start: speechEnd + 0.1, end: speechEnd + 0.9),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Done. Thank you.", "timestamps are rounded; speech within 200 ms is not silence")
    }

    func testTimestampsThatRunPastTheEndOfTheClipAreNotTrusted() {
        // A decode without timestamps reports one segment spanning a whole 30 s window. Spread over that window, a
        // real trailing "thank you" would land beyond the 3 s clip and look silent.
        let profile = TestAudio.profile(speech + Synth.voicedBurst(0.7) + Synth.silence(0.25))
        let result = apply(
            "Please send it. Thank you.",
            segments: [Segment(text: " Please send it. Thank you.", start: 0, end: 30)],
            profile: profile
        )
        XCTAssertEqual(result.text, "Please send it. Thank you.")
    }

    func testSeveralHallucinatedPhrasesInARowAreAllDropped() {
        let profile = profile(tail: Synth.silence(5))
        let result = apply(
            "Done. Thank you. Thank you.",
            segments: [
                Segment(text: " Done.", start: 0, end: speechEnd),
                Segment(text: " Thank you.", start: speechEnd + 1, end: speechEnd + 2),
                Segment(text: " Thank you.", start: speechEnd + 2.5, end: speechEnd + 3.5),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Done.")
        XCTAssertEqual(result.dropped.count, 2)
    }

    // MARK: only a trailing known phrase

    func testAPhraseThatIsNotTrailingIsNeverTouched() {
        let profile = profile(tail: Synth.silence(3))
        let result = apply(
            "Thank you. Send the report.",
            segments: [
                Segment(text: " Thank you.", start: speechEnd + 1, end: speechEnd + 2),
                Segment(text: " Send the report.", start: speechEnd + 2, end: speechEnd + 3),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Thank you. Send the report.")
    }

    func testATrailingPhraseThatIsNotOnTheListIsKept() {
        let profile = profile(tail: Synth.silence(3))
        let result = apply(
            "Done. See you next week.",
            segments: [
                Segment(text: " Done.", start: 0, end: speechEnd),
                Segment(text: " See you next week.", start: speechEnd + 1, end: speechEnd + 2),
            ],
            profile: profile
        )
        XCTAssertEqual(result.text, "Done. See you next week.")
    }

    func testTheListOnlyHoldsPhrasesWithASourceAndANormalisedForm() {
        XCTAssertFalse(HallucinatedTailFilter.phrases.isEmpty)
        for phrase in HallucinatedTailFilter.phrases {
            XCTAssertEqual(phrase.text, HallucinatedTailFilter.normalised(phrase.text), "\(phrase.text) is stored normalised")
            XCTAssertFalse(phrase.source.isEmpty, "\(phrase.text) names where it was seen")
        }
    }

    // MARK: the whole clip is the phrase

    func testAClipOfOnlyThankYouOverSilenceIsDropped() {
        let profile = TestAudio.profile(Synth.silence(3))
        let result = apply("Thank you.", segments: [Segment(text: " Thank you.", start: 0, end: 2)], profile: profile)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.dropped, [.init(reason: .silentClip, phraseLength: "Thank you.".count)])
    }

    func testAClipOfOnlyThankYouSpokenForRealIsKept() {
        let profile = TestAudio.profile(Synth.voicedBurst(0.8) + Synth.silence(0.25))
        let result = apply("Thank you.", segments: [Segment(text: " Thank you.", start: 0.05, end: 0.8)], profile: profile)
        XCTAssertEqual(result.text, "Thank you.")
    }

    func testAClipOfOnlyThankYouWithSpeechElsewhereInTheClipIsKept() {
        let profile = profile(tail: Synth.silence(3))
        let result = apply("Thank you.", segments: [Segment(text: " Thank you.", start: speechEnd + 1, end: speechEnd + 2)], profile: profile)
        XCTAssertEqual(result.text, "Thank you.", "the clip has speech; a lone phrase is only dropped from a silent clip")
    }

    // MARK: no timestamps (a remote endpoint, Parakeet): the last words of the clip decide

    func testFlatTextWithASilentTailDropsTheTrailingPhrase() {
        let result = apply("Please send it. Thank you.", profile: profile(tail: Synth.silence(3)))
        XCTAssertEqual(result.text, "Please send it.")
        XCTAssertEqual(result.dropped, [.init(reason: .silentTail, phraseLength: "Thank you.".count)])
    }

    func testFlatTextWithSpeechAtTheEndKeepsTheTrailingPhrase() {
        let profile = TestAudio.profile(speech + Synth.voicedBurst(0.7) + Synth.silence(0.25))
        let result = apply("Please send it. Thank you.", profile: profile)
        XCTAssertEqual(result.text, "Please send it. Thank you.")
    }

    func testFlatTextDropsAtMostOnePhraseSoARealOneBeforeItSurvives() {
        let result = apply("Please send it. Thank you. Thank you.", profile: profile(tail: Synth.silence(3)))
        XCTAssertEqual(result.text, "Please send it. Thank you.")
    }

    func testWordsThatEndTheSentenceButDoNotStartOneAreNeverTouched() {
        let profile = profile(tail: Synth.silence(3))
        for text in ["I just wanted to say thank you", "Please send it, thank you", "please send it thank you"] {
            XCTAssertEqual(apply(text, profile: profile).text, text, "\(text) is the speaker's sentence")
        }
    }

    func testFlatTextThatIsOnlyThePhraseOverASilentClipIsDropped() {
        let result = apply("Thank you.", profile: TestAudio.profile(Synth.silence(2)))
        XCTAssertEqual(result.text, "")
    }

    func testFlatTextThatIsOnlyThePhraseOverSpeechIsKept() {
        let result = apply("Thank you.", profile: TestAudio.profile(Synth.voicedBurst(0.8)))
        XCTAssertEqual(result.text, "Thank you.")
    }

    // MARK: language

    func testAnotherDetectedLanguageIsLeftAlone() {
        let profile = profile(tail: Synth.silence(3))
        for language in ["es", "de", "ja"] {
            let result = apply("Listo. Thank you.", language: language, profile: profile)
            XCTAssertEqual(result.text, "Listo. Thank you.", "language \(language)")
        }
    }

    func testEnglishVariantsAndAnUnknownLanguageAreFiltered() {
        let profile = profile(tail: Synth.silence(3))
        for language in ["en", "en-US", "EN", nil] {
            let result = apply("Done. Thank you.", language: language, profile: profile)
            XCTAssertEqual(result.text, "Done.", "language \(language ?? "nil")")
        }
    }

    // MARK: text variants

    func testCaseAndPunctuationDoNotHideThePhrase() {
        let profile = profile(tail: Synth.silence(3))
        for variant in ["THANK YOU!", "thank you", "Thank you...", "Thank you.", " Thank you. "] {
            let result = apply("Done. \(variant)", profile: profile)
            XCTAssertEqual(result.text, "Done.", "variant \(variant)")
        }
    }

    func testSpecialTokensAreIgnoredWhenMatching() {
        let profile = profile(tail: Synth.silence(3))
        let result = apply("Done. <|en|> Thank you.<|endoftext|>", profile: profile)
        XCTAssertEqual(result.text, "Done.")
    }

    func testEmptyTextAndNoProfileAreReturnedUnchanged() {
        XCTAssertEqual(apply("", profile: profile(tail: Synth.silence(1))).text, "")
        XCTAssertEqual(apply("Done. Thank you.", profile: ClipEnergyProfile(frameDB: [])).text, "Done. Thank you.",
                       "an empty profile proves nothing, so nothing is dropped")
    }

    func testAClipTheDetectorCannotJudgeIsNeverFiltered() {
        let steady = TestAudio.profile(Synth.roomTone(3, rmsDB: -38))
        XCTAssertEqual(apply("Done. Thank you.", profile: steady).text, "Done. Thank you.",
                       "quiet speech over a fan looks like this; no proof of silence, nothing dropped")
    }

    func testRunningTheFilterTwiceChangesNothingMore() {
        let profile = profile(tail: Synth.silence(3))
        let once = apply("Done. Thank you.", profile: profile)
        XCTAssertEqual(apply(once.text, profile: profile).text, once.text)
    }
}
