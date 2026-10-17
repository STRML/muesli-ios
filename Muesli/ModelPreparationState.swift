import Foundation

enum ModelPreparationPhase: Equatable {
    case idle
    case downloading
    case preparing
    case ready
    case failed
}

extension ModelPreparationPhase {
    /// The same phase in the package that decides what the keyboard is told.
    var kind: PreparationPhaseKind {
        switch self {
        case .idle: .idle
        case .downloading: .downloading
        case .preparing: .preparing
        case .ready: .ready
        case .failed: .failed
        }
    }
}

struct ModelPreparationState: Equatable {
    var phase: ModelPreparationPhase = .idle
    var progress: Double?
    var status = "\(LocalTranscriptionModel.defaultModel.shortName) is not downloaded"
    var detail = LocalTranscriptionModel.defaultModel.detail

    var isPreparing: Bool {
        phase == .downloading || phase == .preparing
    }

    var isReady: Bool {
        phase == .ready
    }
}

enum ModelPreparationAction: Equatable {
    case startBackgroundDownload
    case warmDownloadedModel
}

enum ModelPreparationPolicy {
    /// Progress text for work done on the device (compiling or loading into memory) is
    /// preparing; anything else reported during a model fetch is the download.
    static func phase(forProgressDetail detail: String) -> ModelPreparationPhase {
        ModelProgressText.isOnDeviceWork(detail) ? .preparing : .downloading
    }

    static func action(isDownloaded: Bool) -> ModelPreparationAction {
        isDownloaded ? .warmDownloadedModel : .startBackgroundDownload
    }
}
