import Foundation

/// One readiness trip: the user tapped Record in the keyboard, the keyboard opened Muesli to get ready, and Muesli
/// is loading the speech model. It ends when the model is usable, when the load fails, or when the user dismisses
/// it. Pure, so the Preparing screen and the notification rule run in `swift test`.
struct PrepareTrip: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case working
        /// The model is not on the phone; downloading it is the user's choice.
        case needsDownload
        case ready(at: Date)
        case failed(ReadinessModelFailure)
    }

    enum Effect: Equatable, Sendable {
        /// The load finished while the app was in the background: tell the user they can go back.
        case notifyReady
    }

    let id: UUID
    let startedAt: Date
    /// The app the user came from, when it is known. Nothing in Muesli can learn it today, so this is usually nil.
    var hostAppName: String?
    private(set) var outcome: Outcome = .working
    private(set) var notified = false

    init(id: UUID, startedAt: Date, hostAppName: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.hostAppName = hostAppName
    }

    var isFinished: Bool {
        switch outcome {
        case .ready, .failed: true
        case .working, .needsDownload: false
        }
    }

    /// Feeds the app's model state in. Returns an effect to perform, at most once per trip.
    mutating func apply(
        model: ReadinessModelState,
        now: Date,
        isAppActive: Bool,
        notificationsAllowed: Bool
    ) -> Effect? {
        guard !isFinished else { return nil }
        switch model {
        case .ready, .readyOnDemand:
            outcome = .ready(at: now)
            guard !isAppActive, notificationsAllowed, !notified else { return nil }
            notified = true
            return .notifyReady
        case let .failed(failure):
            outcome = .failed(failure)
        case .notDownloaded:
            outcome = .needsDownload
        case .downloading, .loading, .notLoaded, .deferredByBackoff:
            outcome = .working
        }
        return nil
    }
}

/// What the Preparing screen says.
struct PrepareTripPresentation: Equatable, Sendable {
    enum Button: Equatable, Sendable { case retry, download }

    var title: String
    var detail: String
    var note: String?
    var showsProgress: Bool
    var progress: Double?
    var symbol: String
    var primaryButton: Button?
    var isReady: Bool

    static func make(trip: PrepareTrip, model: ReadinessModelState, now: Date) -> PrepareTripPresentation {
        switch trip.outcome {
        case .ready:
            return ready(host: trip.hostAppName)
        case let .failed(failure):
            return Self(title: "Couldn't load the speech model", detail: failureDetail(failure), note: nil,
                        showsProgress: false, progress: nil, symbol: "exclamationmark.triangle.fill",
                        primaryButton: .retry, isReady: false)
        case .needsDownload:
            return Self(title: "The speech model isn't downloaded", detail: "Download it to dictate with Muesli.",
                        note: nil, showsProgress: false, progress: nil, symbol: "arrow.down.circle",
                        primaryButton: .download, isReady: false)
        case .working:
            return working(model: model, now: now)
        }
    }

    private static let loadNote = "The first load after an update can take a few minutes. Keep Muesli open until it finishes."

    private static func working(model: ReadinessModelState, now: Date) -> Self {
        switch model {
        case let .downloading(progress):
            let detail = progress.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? "Starting the download…"
            return Self(title: "Downloading the speech model", detail: detail, note: nil,
                        showsProgress: true, progress: progress, symbol: "arrow.down.circle",
                        primaryButton: nil, isReady: false)
        case let .loading(since, progress):
            let elapsed = KeyboardReadinessPresentation.elapsedText(now.timeIntervalSince(since))
            return Self(title: "Getting Muesli ready", detail: "Loading the speech model, \(elapsed)", note: loadNote,
                        showsProgress: true, progress: progress, symbol: "waveform", primaryButton: nil, isReady: false)
        default:
            return Self(title: "Getting Muesli ready", detail: "Starting the speech model…", note: loadNote,
                        showsProgress: true, progress: nil, symbol: "waveform", primaryButton: nil, isReady: false)
        }
    }

    private static func ready(host: String?) -> Self {
        if let host {
            return Self(title: "Ready", detail: "Switch back to \(host)",
                        note: "Tap Record on the Muesli keyboard to start dictating.", showsProgress: false,
                        progress: nil, symbol: "checkmark.circle.fill", primaryButton: nil, isReady: true)
        }
        return Self(title: "Ready", detail: "Swipe back to your app",
                    note: "Swipe right along the bottom edge of the screen, or tap the app name in the top corner.",
                    showsProgress: false, progress: nil, symbol: "checkmark.circle.fill", primaryButton: nil, isReady: true)
    }

    private static func failureDetail(_ failure: ReadinessModelFailure) -> String {
        switch failure {
        case .downloadFailed: "The download didn't finish. Check your connection and try again."
        case .loadFailed: "The model didn't load. Try again."
        case .loadInterrupted: "The load was interrupted. Try again."
        case .unknown: "Something went wrong. Try again."
        }
    }
}
