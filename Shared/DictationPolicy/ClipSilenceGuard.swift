import Foundation

/// Wraps one transcription of one clip. Before the engine hears it, the silence around the speech is cut (a copy; the
/// recording is never touched) and a clip with no speech in it is not transcribed at all. After, a known hallucinated
/// phrase the engine still produced for a silent tail is dropped.
///
/// Every dictation path passes through here because every engine call does: the on-device engine
/// (`FluidAudioTranscriptionEngine.transcribeDetailed`, which serves the keyboard's final pass, in-app dictation, long
/// voice notes, meetings and the onboarding test) and the remote route (`RemoteTranscriptionService.transcribe`).
///
/// Fail-open by construction: if the clip cannot be analysed or the copy cannot be written, the engine gets the
/// original and nothing is filtered, because dropping text needs proof about the audio.
enum ClipSilenceGuard {
    struct Options: Sendable, Equatable {
        static let standard = Options()
        /// Cut leading and trailing silence, and skip a clip with no speech.
        var trim = true
        /// Drop a known hallucinated trailing phrase over silent audio.
        var filter = true
        var silence = SilenceTrimmer.Config.standard
    }

    /// What an engine produced for the file it was handed. Segment times are relative to that file.
    struct EngineOutput: Sendable {
        var text: String
        var language: String?
        var segments: [HallucinatedTailFilter.Segment]

        init(text: String, language: String? = nil, segments: [HallucinatedTailFilter.Segment] = []) {
            self.text = text
            self.language = language
            self.segments = segments
        }
    }

    struct Outcome: Sendable, Equatable {
        var text: String
        /// Seconds cut from the start; add to any timestamp the engine reported to get one in the original clip.
        var leadingOffset: TimeInterval
        var skippedAsSilent: Bool
    }

    typealias Log = @Sendable (_ event: String, _ detail: [String: String]) -> Void

    static func run(
        audioURL: URL,
        options: Options = .standard,
        log: Log = { _, _ in },
        transcribe: @Sendable (URL) async throws -> EngineOutput
    ) async throws -> Outcome {
        guard options.trim || options.filter,
              let profile = try? ClipAudioIO.energyProfile(of: audioURL)
        else {
            return Outcome(text: try await transcribe(audioURL).text, leadingOffset: 0, skippedAsSilent: false)
        }

        let plan = SilenceTrimmer.plan(for: profile, config: options.silence)
        if options.trim, !plan.hasSpeech {
            log("transcribe.skipped_silent", ["duration_ms": milliseconds(profile.duration)])
            return Outcome(text: "", leadingOffset: 0, skippedAsSilent: true)
        }

        var handed = audioURL
        var analysed: ClipEnergyProfile? = profile
        var leading: TimeInterval = 0
        var copy: URL?
        defer { if let copy { try? FileManager.default.removeItem(at: copy) } }

        if options.trim, !plan.isNoOp {
            let candidate = FileManager.default.temporaryDirectory
                .appendingPathComponent("muesli-trim-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            do {
                try ClipAudioIO.writeTrimmedCopy(
                    of: audioURL, keepingFrames: plan.keepStartFrame..<plan.keepEndFrame, to: candidate
                )
                copy = candidate
                handed = candidate
                leading = plan.leadingTrimSeconds
                analysed = profile.slice(fromFrame: plan.keepStartFrame, toFrame: plan.keepEndFrame)
                log("transcribe.trimmed", [
                    "leading_ms": milliseconds(plan.leadingTrimSeconds),
                    "trailing_ms": milliseconds(plan.trailingTrimSeconds),
                ])
            } catch {
                try? FileManager.default.removeItem(at: candidate)
                analysed = nil
            }
        }

        let output = try await transcribe(handed)
        guard options.filter, let analysed else {
            return Outcome(text: output.text, leadingOffset: leading, skippedAsSilent: false)
        }
        let filtered = HallucinatedTailFilter.apply(
            text: output.text, segments: output.segments, language: output.language, profile: analysed
        )
        for drop in filtered.dropped {
            log("transcribe.tail_dropped", ["reason": drop.reason.rawValue, "phrase_len": "\(drop.phraseLength)"])
        }
        return Outcome(text: filtered.text, leadingOffset: leading, skippedAsSilent: false)
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))"
    }
}
