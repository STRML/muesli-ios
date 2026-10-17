import Foundation

/// The words, symbols and VoiceOver text for each readiness state. The Type page, the Dictate page and both
/// layouts read this one table, so they cannot show different things for the same state.
struct KeyboardReadinessPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case normal, busy, attention, error }

    /// One line for the strip or the status slot. Nil when there is nothing to say (ready).
    var caption: String?
    var tone: Tone
    /// The Record pill's title, and the SF Symbol for the Record key.
    var recordTitle: String
    var recordSymbol: String
    var showsSpinner: Bool
    var progress: Double?
    var accessibilityLabel: String
    var accessibilityHint: String?
    /// The state is one the user should see: anything but ready and a running dictation.
    var needsAttention: Bool

    static func make(_ readiness: KeyboardReadiness) -> KeyboardReadinessPresentation {
        let escape = readiness.offersEscape
        switch readiness.state {
        case .ready:
            return Self(caption: nil, tone: .normal, recordTitle: "Start", recordSymbol: "mic.fill", showsSpinner: false,
                        accessibilityLabel: "Record", accessibilityHint: nil, needsAttention: false)
        case .checking:
            return Self(caption: "Checking Muesli…", tone: .busy, recordTitle: "Start", recordSymbol: "mic.fill",
                        showsSpinner: false, accessibilityLabel: "Record. Checking Muesli",
                        accessibilityHint: nil, needsAttention: true)
        case .starting:
            return running(escape ? "Muesli isn't answering. Tap to open it" : "Starting…", title: "Starting…", escape: escape)
        case .recording:
            return running(escape ? "Stopping is taking a while. Tap to open Muesli" : "Listening", title: "Stop", escape: escape)
        case .transcribing:
            return running(escape ? "Taking longer than usual. Tap to open Muesli" : "Writing your text", title: "Writing…", escape: escape)
        case .connectionLost:
            return Self(caption: "Lost connection to Muesli. Tap to reconnect", tone: .attention, recordTitle: "Reconnect",
                        recordSymbol: "arrow.up.forward.app", showsSpinner: false,
                        accessibilityLabel: "Lost connection to Muesli. Double tap to open Muesli",
                        accessibilityHint: "Opens Muesli", needsAttention: false)
        case let .needsApp(reason):
            return needsApp(reason)
        case let .loading(stage, progress, elapsed):
            return loading(stage, progress: progress, elapsed: elapsed, escape: escape)
        case let .failed(failure):
            return failed(failure)
        }
    }

    // MARK: States

    private static func running(_ caption: String, title: String, escape: Bool) -> Self {
        Self(caption: caption, tone: escape ? .attention : .busy, recordTitle: title,
             recordSymbol: escape ? "arrow.up.forward.app" : "waveform", showsSpinner: false,
             accessibilityLabel: caption, accessibilityHint: escape ? "Opens Muesli" : nil, needsAttention: false)
    }

    private static func needsApp(_ reason: NeedsAppReason) -> Self {
        let caption: String
        let label: String
        switch reason {
        case .fullAccessOff:
            (caption, label) = ("Turn on Full Access to dictate", "Record unavailable. Turn on Full Access in Settings")
        case .neverOpened:
            (caption, label) = ("Open Muesli to set up dictation", "Open Muesli to set up dictation")
        case .appUpdated:
            (caption, label) = ("Muesli was updated. Open it to continue", "Muesli was updated. Open Muesli to continue")
        case .appNotRunning:
            (caption, label) = ("Open Muesli to start", "Open Muesli to start recording")
        case .loadInterrupted:
            (caption, label) = ("Open Muesli to finish loading", "Open Muesli to finish loading the speech model")
        case .modelMissing:
            (caption, label) = ("Open Muesli to download the model", "Open Muesli to download the speech model")
        case .modelNotLoaded:
            (caption, label) = ("Speech model not loaded. Open Muesli to load it", "Speech model not loaded. Open Muesli to load it")
        case .recovery:
            (caption, label) = ("Open Muesli to finish", "Open Muesli to finish your recording")
        }
        return Self(caption: caption, tone: .attention, recordTitle: "Open Muesli", recordSymbol: "arrow.up.forward.app",
                    showsSpinner: false, accessibilityLabel: label, accessibilityHint: "Opens Muesli", needsAttention: true)
    }

    private static func loading(_ stage: LoadStage, progress: Double?, elapsed: TimeInterval, escape: Bool) -> Self {
        let percent = progress.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" }
        let time = elapsedText(elapsed)
        let caption: String
        let label: String
        switch stage {
        case .downloading:
            caption = ["Downloading speech model", percent].compactMap { $0 }.joined(separator: " ")
            label = "Record. Speech model downloading" + (percent.map { ", \($0)" } ?? "")
        case .preparing:
            if escape {
                caption = "Still loading, \(time). Tap to open Muesli"
            } else {
                let head = ["Loading speech model", percent].compactMap { $0 }.joined(separator: " ")
                caption = "\(head), \(time)"
            }
            label = "Record. Speech model loading, \(time)"
        }
        return Self(caption: caption, tone: escape ? .attention : .busy, recordTitle: "Open Muesli",
                    recordSymbol: "arrow.up.forward.app", showsSpinner: !escape, progress: progress,
                    accessibilityLabel: label, accessibilityHint: "Opens Muesli to finish loading", needsAttention: true)
    }

    private static func failed(_ failure: ReadinessModelFailure) -> Self {
        let caption: String
        switch failure {
        case .downloadFailed: caption = "Model failed to download. Open Muesli"
        case .loadFailed: caption = "Model failed to load. Open Muesli"
        case .loadInterrupted: caption = "Model load was interrupted. Open Muesli"
        case .unknown: caption = "Model failed. Open Muesli"
        }
        return Self(caption: caption, tone: .error, recordTitle: "Open Muesli", recordSymbol: "arrow.up.forward.app",
                    showsSpinner: false, accessibilityLabel: "Record. Speech model failed",
                    accessibilityHint: "Opens Muesli to try again", needsAttention: true)
    }

    private init(
        caption: String?, tone: Tone, recordTitle: String, recordSymbol: String, showsSpinner: Bool,
        progress: Double? = nil, accessibilityLabel: String, accessibilityHint: String?, needsAttention: Bool
    ) {
        self.caption = caption
        self.tone = tone
        self.recordTitle = recordTitle
        self.recordSymbol = recordSymbol
        self.showsSpinner = showsSpinner
        self.progress = progress
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.needsAttention = needsAttention
    }

    /// "40 s", "2 min 5 s", "1 h 2 min". Whole units, rounded down, never negative.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        if total < 3_600 {
            let (minutes, rest) = (total / 60, total % 60)
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
        }
        let (hours, minutes) = (total / 3_600, (total % 3_600) / 60)
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}
