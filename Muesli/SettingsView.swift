import SwiftUI

/// The Settings shell: the root list, navigation between sections, deep links, and the state the sections share.
/// Each section's rows live in their own `SettingsView` extension file.
struct SettingsView: View {
    @Bindable var coordinator: DictationCoordinator
    var openSyncPrivacyRequest: UUID?
    var openInputRequest: UUID?
    var isActive = true
    var onSelectSection: ((AppSection) -> Void)?

    @AppStorage(MuesliPreferences.liveActivitiesForDictationsKey) var liveActivitiesForDictations = true
    @AppStorage(MuesliPreferences.liveActivitiesForMeetingsKey) var liveActivitiesForMeetings = true
    @AppStorage(MuesliPreferences.liveActivitiesForKeyboardMicKey) var liveActivitiesForKeyboardMic = KeyboardMicCardPolicy.keyboardMicSwitchDefault
    @AppStorage(MuesliPreferences.keyboardSessionModeKey) var keyboardSessionMode = true
    @AppStorage(MuesliPreferences.keyboardLayoutKey) var keyboardLayout = KeyboardLayout.fallback.storedValue
    @AppStorage(MuesliPreferences.keyboardAutocorrectKey) var keyboardAutocorrect = true
    @AppStorage(MuesliPreferences.keyboardLiveTypingKey) var keyboardLiveTyping = true
    @AppStorage(MuesliPreferences.keyboardMicAutoOffMinutesKey) var keyboardMicAutoOffMinutes = KeyboardMicAutoOff.defaultMinutes
    @AppStorage(MuesliPreferences.recordingMicrophonePreferenceKey) var microphonePreference = RecordingMicrophonePreference.automatic.rawValue
    @AppStorage(MuesliPreferences.keepDictationAudioRecordingsKey) var keepDictationAudioRecordings = false
    @AppStorage(MuesliPreferences.longVoiceNoteModeEnabledKey) var longVoiceNoteModeEnabled = true
    @AppStorage(MuesliPreferences.longVoiceNoteThresholdSecondsKey) var longVoiceNoteThresholdSeconds = 60
    @AppStorage(MuesliPreferences.keepMeetingAudioRecordingsKey) var keepMeetingAudioRecordings = false
    @AppStorage(MuesliPreferences.meetingSummariesEnabledKey) var meetingSummariesEnabled = false
    @AppStorage(MuesliPreferences.meetingSummaryBackendKey) var meetingSummaryBackend = MeetingSummaryBackend.defaultBackend.rawValue
    @AppStorage(MuesliPreferences.openRouterModelKey) var openRouterModel = MeetingSummaryBackend.defaultOpenRouterModel
    @AppStorage(MuesliPreferences.chatGPTModelKey) var chatGPTModel = MeetingSummaryBackend.defaultChatGPTModel
    @AppStorage(MuesliPreferences.customLLMBaseURLKey) var customLLMBaseURL = ""
    @AppStorage(MuesliPreferences.customLLMModelKey) var customLLMModel = ""
    @AppStorage(MuesliPreferences.remoteProcessingEnabledKey) var remoteProcessingEnabled = false
    @State var customLLMAPIKey = ""
    @AppStorage(MuesliPreferences.meetingTemplateKey) var meetingTemplate = MeetingTemplatePreset.general.rawValue
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) var iCloudSyncEnabled = false
    @State var keyboardSetupStatus = KeyboardSetupStatus.unknown
    @State var openRouterAPIKey = ""
    @State var summaryStatusText: String?
    @State var chatGPTSignedIn = false
    @State var appleSyncSnapshot = AppleSyncAccountSnapshot.checking
    @State var appleSyncStatusText: String?
    @State var selectedSettingsSection: SettingsSection?
    @State var isDiagnosticsScreenPresented = false
    @State var isSyncQRCodeScannerPresented = false
    @State var isApplyingQRCodeSyncEnable = false
    @State var modelPendingRemoval: LocalTranscriptionModel?
    @State var isModelRemovalConfirmationPresented = false
    @State var modelBeingRemoved: LocalTranscriptionModel?
    @State var modelRemovalErrorMessage: String?
    @State var isActionButtonOnboardingPresented = false


    var body: some View {
        NavigationStack {
            settingsContent
                .background(MuesliTheme.backgroundBase)
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    refreshVisibleSettingsIfNeeded()
                    openRequestedSyncPrivacySection()
                    openRequestedInputSection()
                }
                .onChange(of: isActive) { _, active in
                    guard active else { return }
                    refreshVisibleSettingsIfNeeded()
                    openRequestedSyncPrivacySection()
                    openRequestedInputSection()
                }
                .onChange(of: openSyncPrivacyRequest) { _, _ in
                    openRequestedSyncPrivacySection()
                }
                .onChange(of: openInputRequest) { _, _ in
                    openRequestedInputSection()
                }
                .onChange(of: selectedSettingsSection) { _, _ in
                    isDiagnosticsScreenPresented = false
                }
                .sheet(isPresented: $isSyncQRCodeScannerPresented) {
                    SyncQRCodeScannerView(
                        isSyncAlreadyEnabled: iCloudSyncEnabled,
                        onOpenSyncURL: { url in
                            coordinator.handleOpenURL(url)
                        },
                        onEnableSyncURL: { _ in
                            enablePrivateICloudSyncFromQR()
                        }
                    )
                }
                .onChange(of: liveActivitiesForDictations) { _, _ in
                    coordinator.applyLiveActivityPreferences()
                }
                .onChange(of: liveActivitiesForKeyboardMic) { _, _ in
                    coordinator.applyLiveActivityPreferences()
                }
                .onChange(of: liveActivitiesForMeetings) { _, _ in
                    coordinator.applyLiveActivityPreferences()
                }
                .onChange(of: microphonePreference) { _, newValue in
                    guard isActive else { return }
                    coordinator.refreshAudioInputRoute()
                    AppTelemetry.signal("recording_microphone_preference_changed", parameters: ["preference": newValue])
                }
                .onChange(of: openRouterAPIKey) { _, newValue in
                    saveOpenRouterAPIKey(newValue)
                }
                .onChange(of: customLLMAPIKey) { _, newValue in
                    saveCustomLLMAPIKey(newValue)
                }
                .onChange(of: iCloudSyncEnabled) { _, enabled in
                    if enabled && isApplyingQRCodeSyncEnable {
                        isApplyingQRCodeSyncEnable = false
                        return
                    }
                    AppTelemetry.signal(
                        "icloud_sync_toggled",
                        parameters: ["enabled": enabled ? "true" : "false"]
                    )
                    appleSyncStatusText = enabled
                        ? "Private iCloud sync is on. Open Muesli on your Mac to see the same text history."
                        : "iCloud sync is off. Your data stays local on this iPhone."
                    if enabled {
                        AppTelemetry.signal("bridge_enable_started", parameters: ["platform": "ios", "source": "settings"])
                        coordinator.syncICloudTextIfEnabled(reason: "settings_toggle")
                    } else {
                        coordinator.disableICloudTextSync()
                    }
                    refreshAppleSyncSettings()
                }
        }
        .fullScreenCover(isPresented: $isActionButtonOnboardingPresented) {
            ActionButtonOnboardingView(coordinator: coordinator)
        }
        .alert(
            modelPendingRemoval.map { "Remove \($0.shortName)?" } ?? "Remove model?",
            isPresented: $isModelRemovalConfirmationPresented,
            presenting: modelPendingRemoval
        ) { model in
            Button("Remove Download", role: .destructive) {
                removeDownloadedModel(model)
                modelPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                modelPendingRemoval = nil
            }
        } message: { model in
            Text(modelRemovalConfirmationMessage(for: model))
        }
    }

    @ViewBuilder
    var settingsContent: some View {
        if let selectedSettingsSection {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    detailHeader(for: selectedSettingsSection)
                    settingsSectionContent(selectedSettingsSection)
                }
                .padding(MuesliTheme.spacing20)
            }
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(edgeBackSwipe)
                    .accessibilityHidden(true)
            }
            // VoiceOver's two-finger scrub goes back, like the edge swipe does for touch.
            .accessibilityAction(.escape, closeSettingsSection)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    settingsHeader

                    ForEach(SettingsSection.rootGroups) { group in
                        SettingsGroup(title: group.title, spacing: MuesliTheme.spacing4, inset: MuesliTheme.spacing12) {
                            ForEach(group.sections) { section in
                                SettingsSectionRow(section: section) {
                                    openSettingsSection(section)
                                }
                                if section != group.sections.last {
                                    Divider().overlay(MuesliTheme.surfaceBorder)
                                }
                            }
                        }
                    }
                }
                .padding(MuesliTheme.spacing20)
            }
        }
    }

    func closeSettingsSection() {
        withAnimation(.snappy(duration: 0.22)) {
            selectedSettingsSection = nil
        }
    }

    func openSettingsSection(_ section: SettingsSection) {
        withAnimation(.snappy(duration: 0.22)) {
            selectedSettingsSection = section
        }
    }

    /// Settings subareas are not a navigation stack, so the system back swipe does not exist for them.
    /// A swipe that starts on the strip along the left edge and travels right goes back to the Settings list.
    var edgeBackSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.translation.width > 60,
                      abs(value.translation.height) < value.translation.width / 2 else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    selectedSettingsSection = nil
                }
            }
    }

    var settingsHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Settings")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Voice notes, meetings, local models, and privacy.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    func detailHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    selectedSettingsSection = nil
                }
            } label: {
                Label("Settings", systemImage: "chevron.left")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(minHeight: SettingsAccessibility.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Settings")
            .accessibilityHint("Returns to the list of settings sections")
            .accessibilityIdentifier("settings.back")

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(section.title)
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(section.detail)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    func settingsSectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .keyboard:
            keyboardSettings
        case .input:
            voiceNoteSettings
        case .meetings:
            meetingSettings
        case .models:
            modelSettings
        case .dictionary:
            DictionarySettingsContent()
        case .aiServices:
            aiServicesSettings
        case .syncPrivacy:
            privacySettings
        case .appearance:
            AppearanceSettingsContent()
        case .about:
            AboutSettingsContent()
        }
    }

    func refreshVisibleSettingsIfNeeded() {
        guard isActive else { return }
        refreshKeyboardStatus()
        refreshSummarySettings()
        refreshAppleSyncSettings()
    }

    func openRequestedSyncPrivacySection() {
        guard openSyncPrivacyRequest != nil else { return }
        selectedSettingsSection = SettingsSection.syncPrivacyRequestTarget
        isDiagnosticsScreenPresented = false
        coordinator.syncSetupRequestID = nil
    }

    func openRequestedInputSection() {
        guard openInputRequest != nil else { return }
        selectedSettingsSection = SettingsSection.inputRequestTarget
        coordinator.inputSettingsNavigationRequestID = nil
    }

}

/// The sections of Settings. `input` is Voice Notes: the case keeps its name because the Long Voice Note deep link
/// targets it. The keyboard has its own `keyboard` case.
enum SettingsSection: String, CaseIterable, Identifiable {
    case keyboard
    case input
    case meetings
    case models
    case dictionary
    case aiServices
    case syncPrivacy
    case appearance
    case about

    var id: String { rawValue }

    /// Where the long voice note deep link (`openLongVoiceNoteSettings`) lands: the section with the Long Voice Note rows.
    static let inputRequestTarget = SettingsSection.input
    static let syncPrivacyRequestTarget = SettingsSection.syncPrivacy

    /// The root list: sections in groups, in the order they are shown. Every section appears in exactly one group.
    static let rootGroups = [
        SettingsRootGroup(title: "Capture", sections: [.keyboard, .input, .meetings]),
        SettingsRootGroup(title: "Text", sections: [.models, .dictionary]),
        SettingsRootGroup(title: "AI and Privacy", sections: [.aiServices, .syncPrivacy]),
        SettingsRootGroup(title: "App", sections: [.appearance, .about]),
    ]

    var title: String {
        switch self {
        case .keyboard:
            "Keyboard"
        case .input:
            "Voice Notes"
        case .meetings:
            "Meetings"
        case .models:
            "Models"
        case .dictionary:
            "Dictionary"
        case .aiServices:
            "AI Services"
        case .syncPrivacy:
            "Privacy and Sync"
        case .appearance:
            "Appearance"
        case .about:
            "About"
        }
    }

    var detail: String {
        switch self {
        case .keyboard:
            "Layout, autocorrect, live typing, the mic, and Lock Screen cards."
        case .input:
            "Microphone, saved audio, long notes, and the Action Button."
        case .meetings:
            "Summaries, templates, saved audio, and Live Activities."
        case .models:
            "Choose and automatically download local Parakeet or Whisper models."
        case .dictionary:
            "Filler word removal, custom phrases, names, and acronyms."
        case .aiServices:
            "Your server, summary providers, and Quill."
        case .syncPrivacy:
            "Private iCloud sync between this iPhone and your Mac, and diagnostics."
        case .appearance:
            "Color theme, light and dark mode, and app accent."
        case .about:
            "Version, source code, privacy, and open-source acknowledgements."
        }
    }

    var icon: String {
        switch self {
        case .keyboard:
            "keyboard"
        case .input:
            "waveform"
        case .meetings:
            "person.2.wave.2"
        case .models:
            "cpu"
        case .dictionary:
            "character.book.closed"
        case .aiServices:
            "sparkles"
        case .syncPrivacy:
            "icloud"
        case .appearance:
            "paintpalette"
        case .about:
            "info.circle"
        }
    }

}

struct SettingsRootGroup: Identifiable {
    let title: String
    let sections: [SettingsSection]

    var id: String { title }
}
