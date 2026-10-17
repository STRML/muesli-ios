import Foundation

/// Speech for the fixtures, synthesised by macOS `say` so no recording of a person is ever involved.
/// Nothing is committed: every clip is generated on demand into the caller's directory.
public enum SayFixtures {
    public static let sayPath = "/usr/bin/say"

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: sayPath) }

    /// The short phrases and longer paragraphs the harness uses. The reference text is what `say` was given, so a
    /// transcript can be scored against it. Every one is rendered by each voice in `voices`.
    public static let phrases: [(id: String, text: String)] = [
        ("p1-report", "Please send the report by Friday afternoon"),
        ("p2-meeting", "Let's move the meeting to Tuesday morning"),
        ("p3-reminder", "Remind me to call the dentist tomorrow morning"),
        ("p4-short", "I will be there soon"),
        ("p5-groceries", "We need milk, eggs and some bread from the store"),
        ("p6-status", "The build is green and the release can go out today"),
        ("p7-question", "Can you check whether the invoice was paid"),
        ("p8-note", "Note to self, look into the battery drain on the new phone"),
        // Ends in a "thank you" the speaker really says: the guard must never remove it.
        ("p9-signoff", "Please send the report by Friday. Thank you."),
    ]

    public static let paragraphs: [(id: String, text: String)] = [
        (
            "para-10s",
            "The quarterly numbers came in higher than expected, mostly because the new onboarding flow cut the drop off in half. "
                + "I want the team to write up what changed, so we can repeat it in the other regions before the end of the month."
        ),
        (
            "para-7s",
            "Thanks for the update on the migration. I read through the plan and I think the rollout order makes sense, "
                + "but let's keep the old database around for two weeks."
        ),
        (
            "para-12s",
            "Here is what I need from you this week. First, finish the draft of the proposal and send it to legal. "
                + "Second, schedule the review with the design team. Third, make sure the budget numbers match the spreadsheet we shared on Monday."
        ),
    ]

    /// Three accents that ship with every Mac, so the numbers are not one voice's quirk.
    public static let voices = ["Samantha", "Daniel", "Karen"]

    /// Non-English speech, to see what language WhisperKit reports and that the English phrase list stays out of it.
    public static let foreign: [(id: String, voice: String, text: String)] = [
        ("es", "Paulina", "Por favor envía el informe antes del viernes por la tarde"),
        ("de", "Anna", "Bitte schicken Sie den Bericht bis Freitagnachmittag"),
        ("fr", "Thomas", "Merci d'envoyer le rapport avant vendredi après-midi"),
    ]

    public static let thankYou: (id: String, text: String) = ("ty", "Thank you")

    public enum Failure: Error { case sayUnavailable, sayFailed(Int32) }

    /// 16 kHz mono speech. `voice` defaults to Samantha, which ships on every Mac.
    public static func speech(_ text: String, voice: String = "Samantha", in directory: URL) throws -> WavFile.Clip {
        guard isAvailable else { throw Failure.sayUnavailable }
        let url = directory.appendingPathComponent("say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sayPath)
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.sayFailed(process.terminationStatus) }
        let clip = try WavFile.read(url)
        guard !clip.samples.isEmpty else { throw Failure.sayFailed(-1) }
        return clip
    }

    /// Scales the clip so its loudest 10 ms frame sits at `peakDB` RMS, the level a phone microphone gives speech.
    public static func normalised(_ clip: WavFile.Clip, loudestFrameDB: Double = -16) -> WavFile.Clip {
        let frame = max(1, clip.sampleRate / 100)
        var loudest = 1e-12
        var start = 0
        while start + frame <= clip.samples.count {
            let mean = clip.samples[start..<start + frame].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame)
            loudest = max(loudest, mean)
            start += frame
        }
        let gain = Float(pow(10, loudestFrameDB / 20) / loudest.squareRoot())
        return WavFile.Clip(samples: clip.samples.map { $0 * gain }, sampleRate: clip.sampleRate, channels: clip.channels)
    }
}

/// What follows the speech in a fixture.
public enum TailKind: Sendable, CaseIterable, CustomStringConvertible {
    case none
    case silence(seconds: Double)
    case roomTone(seconds: Double, dB: Double)
    case keyboardTap
    /// A fan or traffic: loud enough that it is within 18 dB of the speech and the trimmer cannot call it silence.
    case fan(seconds: Double)

    public static let allCases: [TailKind] = [
        .none,
        .silence(seconds: 0.3), .silence(seconds: 1), .silence(seconds: 2), .silence(seconds: 4),
        .roomTone(seconds: 3, dB: -50), .roomTone(seconds: 3, dB: -40),
        .keyboardTap,
        .fan(seconds: 3),
    ]

    public var description: String {
        switch self {
        case .none: "none"
        case .silence(let seconds): "silence-\(seconds)s"
        case .roomTone(_, let dB): "roomtone\(Int(dB))dB"
        case .keyboardTap: "tap"
        case .fan: "fan-30dB"
        }
    }

    public func samples(rate: Int = Synth.sampleRate) -> [Float] {
        switch self {
        case .none: []
        case .silence(let seconds): Synth.silence(seconds, rate: rate)
        case .roomTone(let seconds, let dB): Synth.roomTone(seconds, rmsDB: dB, rate: rate)
        case .fan(let seconds): Synth.roomTone(seconds, rmsDB: -30, seed: 11, rate: rate)
        case .keyboardTap: Synth.silence(0.5, rate: rate) + Synth.keyboardTap(rate: rate) + Synth.silence(1.0, rate: rate)
        }
    }
}
