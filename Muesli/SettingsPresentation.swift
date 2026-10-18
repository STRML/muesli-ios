import Foundation

/// Allow Full Access as far as Settings can tell. `unknown` means the keyboard has not been confirmed yet, so no
/// claim is made either way.
enum KeyboardFullAccess: Equatable {
    case granted
    case missing
    case unknown
}

/// What the keyboard status row shows, and the Full Access state behind it.
enum KeyboardSetupStatus: Equatable {
    case unknown
    case enabled
    case needsFirstUse
    case fullAccessNeeded
    case notConfirmed

    static func resolve(hasOpenAccess: Bool, enabledConfirmed: Bool, fullAccessConfirmed: Bool) -> KeyboardSetupStatus {
        if hasOpenAccess { return .enabled }
        if enabledConfirmed && fullAccessConfirmed { return .needsFirstUse }
        if enabledConfirmed { return .fullAccessNeeded }
        return .notConfirmed
    }

    var label: String {
        switch self {
        case .unknown: "Unknown"
        case .enabled: "Enabled"
        case .needsFirstUse: "Needs first use"
        case .fullAccessNeeded: "Full Access needed"
        case .notConfirmed: "Not confirmed"
        }
    }

    var fullAccess: KeyboardFullAccess {
        switch self {
        case .enabled, .needsFirstUse: .granted
        case .fullAccessNeeded: .missing
        case .unknown, .notConfirmed: .unknown
        }
    }
}

/// The sentences Settings computes from real settings: where data goes, and why a row is unavailable.
/// Pure functions, so each claim is tested against the setting that makes it true.
enum SettingsPresentation {
    /// Where meeting transcripts and notes go for summaries.
    enum SummaryDestination: Equatable {
        case none
        case yourServer
        case openRouter
        case chatGPT
    }

    enum TypingFeature {
        case autocorrect
        case liveTyping
    }

    /// A Custom backend with no usable server sends nothing: the summarizer throws before any request.
    static func summaryDestination(
        summariesEnabled: Bool,
        backend: MeetingSummaryBackend,
        yourServerConfigured: Bool
    ) -> SummaryDestination {
        guard summariesEnabled else { return .none }
        switch backend {
        case .customLLM: return yourServerConfigured ? .yourServer : .none
        case .openRouter: return .openRouter
        case .chatGPT: return .chatGPT
        }
    }

    /// The same decision the recorder makes, so the screen cannot say "on device" while audio can leave.
    static func isRemoteProcessingActive(stored: Bool, endpointConfigured: Bool, backend: MeetingSummaryBackend) -> Bool {
        RemoteTranscriptionPolicy.isSettingActive(
            stored: stored,
            endpointConfigured: endpointConfigured,
            summaryBackendIsCustomLLM: backend == .customLLM
        )
    }

    /// The facts above, read from the stored settings.
    static var currentRemoteProcessingActive: Bool { MuesliPreferences.isRemoteProcessingActive }

    static var currentSummaryDestination: SummaryDestination {
        summaryDestination(
            summariesEnabled: MuesliPreferences.meetingSummariesEnabled,
            backend: MuesliPreferences.meetingSummaryBackend,
            yourServerConfigured: MuesliPreferences.isVoiceRewriteConfigured
        )
    }

    // MARK: Where data goes

    static func executionLabel(remoteProcessingActive: Bool) -> String {
        remoteProcessingActive ? "On device, or your server" : "On device"
    }

    static func aboutProcessing(remoteProcessingActive: Bool, summaryDestination: SummaryDestination) -> String {
        let speech = executionLabel(remoteProcessingActive: remoteProcessingActive)
        switch summaryDestination {
        case .none: return speech
        case .yourServer: return "\(speech); summaries on your server"
        case .openRouter: return "\(speech); summaries sent to OpenRouter"
        case .chatGPT: return "\(speech); summaries sent to OpenAI"
        }
    }

    static func localFirstDetail(remoteProcessingActive: Bool, summaryDestination: SummaryDestination) -> String {
        var sentences = [
            remoteProcessingActive
                ? "Speech models run on this iPhone. Remote processing is on, so your recordings also go to your server when it answers quickly."
                : "Voice recordings and downloaded speech models stay on this iPhone.",
        ]
        switch summaryDestination {
        case .none: break
        case .yourServer: sentences.append("Meeting transcripts and notes go to your server for summaries.")
        case .openRouter: sentences.append("Meeting transcripts and notes go to OpenRouter for summaries.")
        case .chatGPT: sentences.append("Meeting transcripts and notes go to OpenAI through your ChatGPT account for summaries.")
        }
        sentences.append("Only text is eligible for private iCloud sync when you enable it.")
        return sentences.joined(separator: " ")
    }

    // MARK: Why a row is unavailable

    static func summaryProviderDisabledReason(summariesEnabled: Bool) -> String? {
        summariesEnabled ? nil : "Turn on Meeting Summaries (under Meetings) to use these."
    }

    static func syncNowDisabledReason(syncEnabled: Bool) -> String? {
        syncEnabled ? nil : "Turn on Sync with Mac first"
    }

    static let meetingTemplateNote = "Used when summaries are on."

    /// Without Allow Full Access the keyboard cannot read the app's switch and keeps its default, so the switch
    /// does nothing. Said only when the screen knows Full Access is missing.
    static func typingSwitchNote(_ feature: TypingFeature, access: KeyboardFullAccess) -> String? {
        guard access == .missing else { return nil }
        let behaviour = switch feature {
        case .autocorrect: "keeps autocorrect on"
        case .liveTyping: "keeps live typing on"
        }
        return "Allow Full Access is off, so the keyboard ignores this switch and \(behaviour)."
    }
}

/// VoiceOver wording and sizes shared by the Settings rows.
enum SettingsAccessibility {
    /// Apple's minimum tap target, in points.
    static let minimumTapTarget: CGFloat = 44

    /// One spoken label for a row: the title, then the detail. The switch or menu adds its own value.
    static func label(title: String, detail: String) -> String {
        detail.isEmpty ? title : "\(title). \(detail)"
    }
}
