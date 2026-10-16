import Foundation

/// Which engine streams the live preview for a dictation.
///
/// The preview is the Parakeet Realtime EOU 120M model. When that is the selected model it already streams, so the
/// one engine does both jobs. Otherwise a dedicated preview engine runs beside the selected model, only for keyboard
/// dictations the keyboard can show, and only when the preview model is on the phone. The preview never decides the
/// final text: the selected model's full-clip pass does.
enum LivePreviewEnginePolicy {
    enum Choice: Sendable, Equatable {
        /// The selected model streams itself (today's realtime path).
        case finalModel
        /// A separate EOU engine streams beside the selected model.
        case dedicated
        case off(OffReason)

        var streams: Bool {
            if case .off = self { return false }
            return true
        }
    }

    enum OffReason: Sendable, Equatable {
        /// Action Button and in-app dictations have no keyboard strip to fill.
        case notKeyboard
        /// Notepad bursts have their own path.
        case notepad
        /// The preview model is not downloaded; Settings offers it.
        case previewModelMissing
    }

    static func choose(
        selectedModelStreams: Bool,
        isKeyboardDictation: Bool,
        startsAsNotepad: Bool,
        previewModelDownloaded: Bool
    ) -> Choice {
        if selectedModelStreams { return .finalModel }
        guard isKeyboardDictation else { return .off(.notKeyboard) }
        guard !startsAsNotepad else { return .off(.notepad) }
        guard previewModelDownloaded else { return .off(.previewModelMissing) }
        return .dedicated
    }
}

/// When the dedicated preview engine holds its model in memory. It loads lazily on the first dictation that uses it
/// and lets go under memory pressure, but never in the middle of a dictation it is streaming.
struct LivePreviewResidency: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case none
        case unload
    }

    private(set) var isLoaded = false
    private(set) var isStreaming = false
    private(set) var unloadsWhenIdle = false

    mutating func streamingStarted() {
        isLoaded = true
        isStreaming = true
    }

    mutating func streamingEnded() -> Action {
        isStreaming = false
        guard unloadsWhenIdle else { return .none }
        return unload()
    }

    mutating func memoryWarning() -> Action {
        guard isLoaded else { return .none }
        if isStreaming {
            unloadsWhenIdle = true
            return .none
        }
        return unload()
    }

    /// The selected model became the preview model (one engine now does both) or the preview model was removed.
    mutating func dedicatedEngineNotNeeded() -> Action {
        guard isLoaded else { return .none }
        if isStreaming {
            unloadsWhenIdle = true
            return .none
        }
        return unload()
    }

    private mutating func unload() -> Action {
        isLoaded = false
        unloadsWhenIdle = false
        return .unload
    }
}

/// The Settings row that offers the preview model when it is missing.
enum LivePreviewDownloadOffer: Sendable, Equatable {
    case hidden
    case available(sizeLabel: String)
    case downloading(progress: Double?)
    /// The download service runs one model at a time; starting this one would cancel the other.
    case waitingForOtherDownload

    /// What the app downloads for Parakeet Realtime EOU 120M (320 ms): the three .mlmodelc bundles and their JSON,
    /// summed from the Hugging Face tree of FluidInference/parakeet-realtime-eou-120m-coreml on 2026-10-16.
    static let previewModelBytes: Int64 = 224_240_384

    static func state(
        previewModelDownloaded: Bool,
        selectedModelStreams: Bool,
        previewDownloadProgress: Double?,
        isPreviewDownloading: Bool,
        otherDownloadActive: Bool
    ) -> LivePreviewDownloadOffer {
        guard !previewModelDownloaded, !selectedModelStreams else { return .hidden }
        if isPreviewDownloading { return .downloading(progress: previewDownloadProgress) }
        if otherDownloadActive { return .waitingForOtherDownload }
        return .available(sizeLabel: sizeLabel(bytes: previewModelBytes))
    }

    static func sizeLabel(bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        return "\(Int(megabytes.rounded())) MB"
    }
}
