import AVFoundation
import Foundation
@preconcurrency import WhisperKit

actor WhisperKitTranscriptionRuntime {
    private static let completionMarkerName = ".muesli-download-complete"
    private static let requiredModelComponents = [
        "MelSpectrogram",
        "AudioEncoder",
        "TextDecoder",
    ]

    private var whisperKit: WhisperKit?
    private var loadedVariant: String?

    func load(
        variant: String,
        progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws {
        if loadedVariant == variant, whisperKit != nil { return }

        try Self.prepareDownloadStorage()

        guard Self.isModelDownloaded(variant) else {
            throw WhisperKitRuntimeError.incompleteDownload
        }
        progress?(0.92, "Loading downloaded Whisper model...")
        let modelFolder = Self.modelDirectory(for: variant)

        progress?(0.94, "Loading Whisper model...")
        let configuration = WhisperKitConfig(
            model: nil,
            modelFolder: modelFolder.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
        // SuspendingClock stops while the app is suspended, so a load that straddles a backgrounding reports
        // the time it spent running. WhisperKit's own timings are wall-clock and can include the suspension.
        let loadStart = SuspendingClock.now
        let wallStart = Date()
        do {
            let kit = try await WhisperKit(configuration)
            whisperKit = kit
            loadedVariant = variant
            Self.recordLoadTimings(
                variant: variant, kit: kit,
                total: SuspendingClock.now - loadStart, wall: Date().timeIntervalSince(wallStart)
            )
            progress?(1, "Whisper model ready")
        } catch {
            Self.invalidateCompletionMarker(at: modelFolder)
            throw error
        }
    }

    /// Specialization is the Neural Engine compile. It is slow when the system's cache for this model is cold
    /// (after a reboot, an OS update or a cache purge) and near zero when it is warm, so the diagnostics log
    /// shows which of the two a slow launch was.
    private static func recordLoadTimings(variant: String, kit: WhisperKit, total: Duration, wall: TimeInterval) {
        let timings = kit.currentTimings
        func seconds(_ value: Double) -> String { String(format: "%.2f", value) }
        KeyboardDiagnosticsLog.record("whisper.loaded", [
            "variant": variant,
            "total_s": seconds(Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18),
            "wall_s": seconds(wall),
            "encoder_load_s": seconds(timings.encoderLoadTime),
            "encoder_specialization_s": seconds(timings.encoderSpecializationTime),
            "decoder_load_s": seconds(timings.decoderLoadTime),
            "decoder_specialization_s": seconds(timings.decoderSpecializationTime),
        ])
    }

    /// What WhisperKit heard in one file, with the language it decoded in and the segment timing the silence guard
    /// needs to tell a phrase the speaker said from one the model invented over silence.
    struct Transcription: Sendable {
        let text: String
        let language: String
        let segments: [HallucinatedTailFilter.Segment]
    }

    func transcribe(audioURL: URL) async throws -> Transcription {
        guard let whisperKit else {
            throw WhisperKitRuntimeError.notLoaded
        }
        let seconds = Self.duration(of: audioURL)
        let options = WhisperKitDecodingOptions.options(forAudioSeconds: seconds)
        let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        return Transcription(
            text: results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            language: results.first?.language ?? "en",
            // Without timestamp tokens a segment's times are the window's, not the speech's.
            segments: options.withoutTimestamps ? [] : results.flatMap(\.segments).map {
                HallucinatedTailFilter.Segment(text: $0.text, start: TimeInterval($0.start), end: TimeInterval($0.end))
            }
        )
    }

    private static func duration(of audioURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: audioURL), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
        loadedVariant = nil
    }

    static func isModelDownloaded(_ variant: String) -> Bool {
        isModelDownloaded(at: modelDirectory(for: variant))
    }

    static func isModelDownloaded(at directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(completionMarkerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        return requiredModelComponents.allSatisfy { modelComponentExists(named: $0, in: directory) }
    }

    static func modelDirectory(for variant: String) -> URL {
        let fullName = variant.hasPrefix("openai_whisper-")
            ? variant
            : "openai_whisper-\(variant)"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(fullName, isDirectory: true)
    }

    static func markDownloadComplete(at directory: URL) throws {
        guard requiredModelComponents.allSatisfy({ modelComponentExists(named: $0, in: directory) }) else {
            throw WhisperKitRuntimeError.incompleteDownload
        }
        try Data().write(
            to: directory.appendingPathComponent(completionMarkerName),
            options: .atomic
        )
    }

    private static func prepareDownloadStorage() throws {
        try FileManager.default.createDirectory(
            at: downloadStorageDirectory,
            withIntermediateDirectories: true
        )
        try excludeDownloadStorageFromBackup()
    }

    private static var downloadStorageDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    private static func excludeDownloadStorageFromBackup() throws {
        var directory = downloadStorageDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private static func invalidateCompletionMarker(at directory: URL) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(completionMarkerName)
        )
    }

    private static func modelComponentExists(named name: String, in directory: URL) -> Bool {
        let compiled = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if directoryContainsNonemptyFile(compiled) {
            return true
        }

        let packagedModel = directory
            .appendingPathComponent("\(name).mlpackage", isDirectory: true)
            .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        guard let values = try? packagedModel.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private static func directoryContainsNonemptyFile(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            if values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                return true
            }
        }
        return false
    }

}

private enum WhisperKitRuntimeError: LocalizedError {
    case notLoaded
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            "WhisperKit model is not loaded."
        case .incompleteDownload:
            "The WhisperKit model download is incomplete."
        }
    }
}
