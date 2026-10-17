import ClipFixtureKit
@testable import DictationPolicyKit
import Foundation
@preconcurrency import WhisperKit

// tail-harness: reproduces and measures the trailing "Thank you." hallucination with the real WhisperKit model.
// No recording of a person is used anywhere: speech is macOS `say`, tails are synthetic.

struct Fixture: Codable {
    var id: String
    var speechID: String
    var reference: String
    var tail: String
    var path: String
}

struct Row: Codable {
    var fixture: String
    var speechID: String
    var tail: String
    var setting: String
    var prep: String
    var reference: String
    var output: String
    var filtered: String
    var tailExtraWords: Int
    var filteredExtraWords: Int
    var exact: Bool
    var language: String
    var dropped: String
    var trimmedLeadingMS: Int
    var trimmedTrailingMS: Int
    var skippedSilent: Bool
    var seconds: Double
}

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

// MARK: - Scoring

func words(_ text: String) -> [String] {
    var cleaned = text.lowercased()
    cleaned = cleaned.replacingOccurrences(of: "<\\|[^|]*\\|>", with: " ", options: .regularExpression)
    cleaned = cleaned.replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
    return cleaned.split(separator: " ").map(String.init)
}

/// Output words after the one aligned to the last reference word, by edit-distance alignment.
func trailingExtraWords(reference: String, output: String) -> Int {
    let ref = words(reference), out = words(output)
    guard !out.isEmpty else { return 0 }
    guard !ref.isEmpty else { return out.count }
    var cost = [[Int]](repeating: [Int](repeating: 0, count: out.count + 1), count: ref.count + 1)
    for i in 0...ref.count { cost[i][0] = i }
    for j in 0...out.count { cost[0][j] = j }
    for i in 1...ref.count {
        for j in 1...out.count {
            let sub = cost[i - 1][j - 1] + (ref[i - 1] == out[j - 1] ? 0 : 1)
            cost[i][j] = min(sub, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
        }
    }
    // Walk back from the end; the first output index consumed by a diagonal move is the last aligned word.
    var i = ref.count, j = out.count
    while i > 0 && j > 0 {
        let diagonal = cost[i - 1][j - 1] + (ref[i - 1] == out[j - 1] ? 0 : 1)
        if cost[i][j] == diagonal { return out.count - j }
        if cost[i][j] == cost[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
    }
    return out.count - j
}

// MARK: - Commands

func generate(into directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var manifest = [Fixture]()
    let speeches = SayFixtures.phrases + [SayFixtures.thankYou] + SayFixtures.paragraphs
    for voice in SayFixtures.voices {
        for speech in speeches {
            let clip = SayFixtures.normalised(try SayFixtures.speech(speech.text, voice: voice, in: directory))
            for tail in TailKind.allCases {
                let id = "\(speech.id)-\(voice)__\(tail)"
                let url = directory.appendingPathComponent("\(id).wav")
                try WavFile.write(WavFile.Clip(samples: clip.samples + tail.samples()), to: url)
                manifest.append(Fixture(id: id, speechID: "\(speech.id)-\(voice)", reference: speech.text, tail: "\(tail)", path: url.lastPathComponent))
            }
        }
    }
    for speech in SayFixtures.foreign {
        let clip = SayFixtures.normalised(try SayFixtures.speech(speech.text, voice: speech.voice, in: directory))
        for tail in [TailKind.none, .silence(seconds: 2), .silence(seconds: 4)] {
            let id = "foreign-\(speech.id)__\(tail)"
            let url = directory.appendingPathComponent("\(id).wav")
            try WavFile.write(WavFile.Clip(samples: clip.samples + tail.samples()), to: url)
            manifest.append(Fixture(id: id, speechID: "foreign-\(speech.id)", reference: speech.text, tail: "foreign-\(tail)", path: url.lastPathComponent))
        }
    }
    // Pure silence and pure room tone: nothing was said, so any text is a hallucination.
    for (name, samples) in [
        ("only-silence-3s", Synth.silence(3)),
        ("only-roomtone-50dB-3s", Synth.roomTone(3, rmsDB: -50)),
        ("only-roomtone-40dB-3s", Synth.roomTone(3, rmsDB: -40)),
    ] {
        let url = directory.appendingPathComponent("\(name).wav")
        try WavFile.write(WavFile.Clip(samples: samples), to: url)
        manifest.append(Fixture(id: name, speechID: name, reference: "", tail: "all", path: url.lastPathComponent))
    }
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    print("wrote \(manifest.count) fixtures to \(directory.path)")
}

func decodingOptions(named name: String) -> DecodingOptions? {
    switch name {
    case "default": return nil   // what the app passes today: transcribe(audioPath:) with no options
    case "nospeech0.3": return DecodingOptions(noSpeechThreshold: 0.3)
    case "suppressBlank": return DecodingOptions(suppressBlank: true)
    case "logprob-0.5": return DecodingOptions(logProbThreshold: -0.5, firstTokenLogProbThreshold: -1.0)
    case "compression1.8": return DecodingOptions(compressionRatioThreshold: 1.8)
    case "nofallback": return DecodingOptions(temperatureFallbackCount: 0)
    case "notimestamps": return DecodingOptions(withoutTimestamps: true)
    case "strict":
        return DecodingOptions(
            suppressBlank: true, compressionRatioThreshold: 2.0, logProbThreshold: -0.6,
            firstTokenLogProbThreshold: -1.0, noSpeechThreshold: 0.3
        )
    default: fatalError("unknown setting \(name)")
    }
}

func downloadModel(variant: String, models: URL) async throws -> URL {
    let folder = models.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)")
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path) { return folder }
    print("downloading openai_whisper-\(variant) into \(models.path)")
    return try await WhisperKit.download(variant: variant, downloadBase: models) { progress in
        print(String(format: "  %.0f%%", progress.fractionCompleted * 100))
    }
}

func run() async throws {
    guard let fixturesPath = option("--fixtures"), let modelsPath = option("--models"), let outPath = option("--out") else {
        print("usage: tail-harness run --fixtures DIR --models DIR --out FILE [--variant V] [--settings a,b] [--prep none,trim,...] [--only prefix]")
        exit(2)
    }
    let fixturesDir = URL(fileURLWithPath: fixturesPath)
    let variant = option("--variant") ?? "large-v3-v20240930_626MB"
    let settings = (option("--settings") ?? "default").split(separator: ",").map(String.init)
    let preps = (option("--prep") ?? "none").split(separator: ",").map(String.init)
    let only = option("--only")
    let manifest = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturesDir.appendingPathComponent("manifest.json")))
        .filter { only == nil || $0.id.hasPrefix(only!) }

    let modelFolder = try await downloadModel(variant: variant, models: URL(fileURLWithPath: modelsPath))
    let loadStart = Date()
    // The tokenizer files (tokenizer.json, tokenizer_config.json, config.json from openai/whisper-large-v3) are
    // fetched once with curl by scripts/fetch-model.sh, so a slow Hub listing cannot stall the run.
    let tokenizerFolder = URL(fileURLWithPath: modelsPath).appendingPathComponent("models/openai/whisper-large-v3")
    let kit = try await WhisperKit(WhisperKitConfig(
        modelFolder: modelFolder.path,
        tokenizerFolder: FileManager.default.fileExists(atPath: tokenizerFolder.path) ? tokenizerFolder : nil,
        computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
    ))
    print(String(format: "model %@ loaded in %.1fs", variant, Date().timeIntervalSince(loadStart)))

    FileManager.default.createFile(atPath: outPath, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    defer { try? handle.close() }

    for setting in settings {
        for prep in preps {
            for fixture in manifest {
                let url = fixturesDir.appendingPathComponent(fixture.path)
                let started = Date()
                let transcribed = try await transcribe(kit: kit, url: url, options: decodingOptions(named: setting), prep: prep)
                let row = Row(
                    fixture: fixture.id, speechID: fixture.speechID, tail: fixture.tail, setting: setting, prep: prep,
                    reference: fixture.reference, output: transcribed.raw, filtered: transcribed.filtered,
                    tailExtraWords: trailingExtraWords(reference: fixture.reference, output: transcribed.raw),
                    filteredExtraWords: trailingExtraWords(reference: fixture.reference, output: transcribed.filtered),
                    exact: words(fixture.reference) == words(transcribed.raw), language: transcribed.language,
                    dropped: transcribed.dropped, trimmedLeadingMS: transcribed.leadingMS,
                    trimmedTrailingMS: transcribed.trailingMS, skippedSilent: transcribed.skipped,
                    seconds: Date().timeIntervalSince(started)
                )
                try handle.write(contentsOf: JSONEncoder().encode(row) + Data("\n".utf8))
                print("\(setting)/\(prep) \(fixture.id): extra=\(row.tailExtraWords)->\(row.filteredExtraWords) \"\(row.filtered)\"")
            }
        }
    }
}

struct Transcribed {
    var raw: String
    var filtered: String
    var language: String
    var dropped: String
    var leadingMS: Int
    var trailingMS: Int
    var skipped: Bool
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String: String])] = []
    func add(_ event: String, _ detail: [String: String]) { lock.lock(); items.append((event, detail)); lock.unlock() }
    var all: [(String, [String: String])] { lock.lock(); defer { lock.unlock() }; return items }
}

final class TextBox: @unchecked Sendable {
    var raw = ""
    var language = ""
}

/// prep: none = the app before this change; trim = silence trimmed only; filter = post-filter only (untrimmed
/// audio); guard = trim + filter, exactly what ships.
func transcribe(kit: WhisperKit, url: URL, options: DecodingOptions?, prep: String) async throws -> Transcribed {
    let seen = TextBox()
    func hear(_ file: URL) async throws -> ClipSilenceGuard.EngineOutput {
        let results = try await kit.transcribe(audioPath: file.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = results.first?.language ?? ""
        seen.raw = text
        seen.language = language
        let segments = results.flatMap(\.segments).map {
            HallucinatedTailFilter.Segment(text: $0.text, start: TimeInterval($0.start), end: TimeInterval($0.end))
        }
        return .init(text: text, language: language, segments: segments)
    }
    if prep == "none" {
        let output = try await hear(url)
        return Transcribed(raw: output.text, filtered: output.text, language: seen.language, dropped: "", leadingMS: 0, trailingMS: 0, skipped: false)
    }
    var guardOptions = ClipSilenceGuard.Options.standard
    guardOptions.trim = prep == "trim" || prep == "guard"
    guardOptions.filter = prep == "filter" || prep == "guard"
    let events = EventBox()
    let outcome = try await ClipSilenceGuard.run(audioURL: url, options: guardOptions, log: { events.add($0, $1) }, transcribe: { try await hear($0) })
    let trimmed = events.all.first { $0.0 == "transcribe.trimmed" }?.1
    let dropped = events.all.filter { $0.0 == "transcribe.tail_dropped" }.map { $0.1["reason"] ?? "" }.joined(separator: ",")
    return Transcribed(
        raw: seen.raw, filtered: outcome.text, language: seen.language, dropped: dropped,
        leadingMS: Int(trimmed?["leading_ms"] ?? "") ?? 0, trailingMS: Int(trimmed?["trailing_ms"] ?? "") ?? 0,
        skipped: outcome.skippedAsSilent
    )
}

func report(_ paths: [String]) throws {
    var rows = [Row]()
    for path in paths {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(separator: "\n") { rows.append(try JSONDecoder().decode(Row.self, from: Data(line.utf8))) }
    }
    let groups = Dictionary(grouping: rows) { "\($0.setting) | \($0.prep)" }
    for key in groups.keys.sorted() {
        print("\n## \(key)")
        let byTail = Dictionary(grouping: groups[key]!) { $0.tail }
        print("| tail | clips | model added trailing words | final text added trailing words | final text exact | final text on a clip with no speech |")
        print("|---|---|---|---|---|---|")
        for tail in byTail.keys.sorted() {
            let list = byTail[tail]!
            let raw = list.filter { $0.tailExtraWords > 0 }.count
            let filtered = list.filter { $0.filteredExtraWords > 0 }.count
            let exact = list.filter { words($0.reference) == words($0.filtered) }.count
            let silentOnlyText = list.filter { $0.reference.isEmpty && !words($0.filtered).isEmpty }.count
            print("| \(tail) | \(list.count) | \(raw) | \(filtered) | \(exact) | \(silentOnlyText) |")
        }
        let extras = groups[key]!.filter { $0.tailExtraWords > 0 }.map { "\($0.output.suffix(40))" }
        if !extras.isEmpty { print("tails seen: \(Set(extras).sorted().prefix(12))") }
    }
}

let command = args.first ?? ""
switch command {
case "generate":
    guard args.count >= 2 else { print("usage: tail-harness generate DIR"); exit(2) }
    try generate(into: URL(fileURLWithPath: args[1]))
case "run":
    try await run()
case "report":
    try report(Array(args.dropFirst()))
default:
    print("commands: generate DIR | run ... | report FILE...")
    exit(2)
}
