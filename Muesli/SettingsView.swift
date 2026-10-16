import CloudKit
import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: DictationCoordinator
    var openSyncPrivacyRequest: UUID?
    var openInputRequest: UUID?
    var isActive = true
    var onSelectSection: ((AppSection) -> Void)?

    @AppStorage(MuesliPreferences.liveActivitiesForDictationsKey) private var liveActivitiesForDictations = true
    @AppStorage(MuesliPreferences.liveActivitiesForMeetingsKey) private var liveActivitiesForMeetings = true
    @AppStorage(MuesliPreferences.keyboardSessionModeKey) private var keyboardSessionMode = true
    @AppStorage(MuesliPreferences.keyboardMicAutoOffMinutesKey) private var keyboardMicAutoOffMinutes = KeyboardMicAutoOff.defaultMinutes
    @AppStorage(MuesliPreferences.recordingMicrophonePreferenceKey) private var microphonePreference = RecordingMicrophonePreference.automatic.rawValue
    @AppStorage(MuesliPreferences.keepDictationAudioRecordingsKey) private var keepDictationAudioRecordings = false
    @AppStorage(MuesliPreferences.longVoiceNoteModeEnabledKey) private var longVoiceNoteModeEnabled = true
    @AppStorage(MuesliPreferences.longVoiceNoteThresholdSecondsKey) private var longVoiceNoteThresholdSeconds = 60
    @AppStorage(MuesliPreferences.keepMeetingAudioRecordingsKey) private var keepMeetingAudioRecordings = false
    @AppStorage(MuesliPreferences.meetingSummariesEnabledKey) private var meetingSummariesEnabled = false
    @AppStorage(MuesliPreferences.meetingSummaryBackendKey) private var meetingSummaryBackend = MeetingSummaryBackend.defaultBackend.rawValue
    @AppStorage(MuesliPreferences.openRouterModelKey) private var openRouterModel = MeetingSummaryBackend.defaultOpenRouterModel
    @AppStorage(MuesliPreferences.chatGPTModelKey) private var chatGPTModel = MeetingSummaryBackend.defaultChatGPTModel
    @AppStorage(MuesliPreferences.customLLMBaseURLKey) private var customLLMBaseURL = ""
    @AppStorage(MuesliPreferences.customLLMModelKey) private var customLLMModel = ""
    @AppStorage(MuesliPreferences.remoteProcessingEnabledKey) private var remoteProcessingEnabled = false
    @State private var customLLMAPIKey = ""
    @AppStorage(MuesliPreferences.meetingTemplateKey) private var meetingTemplate = MeetingTemplatePreset.general.rawValue
    @AppStorage(MuesliPreferences.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @State private var keyboardStatusText = "Unknown"
    @State private var openRouterAPIKey = ""
    @State private var summaryStatusText: String?
    @State private var chatGPTSignedIn = false
    @State private var appleSyncSnapshot = AppleSyncAccountSnapshot.checking
    @State private var appleSyncStatusText: String?
    @State private var selectedSettingsSection: SettingsSection?
    @State private var isSyncQRCodeScannerPresented = false
    @State private var isApplyingQRCodeSyncEnable = false
    @State private var modelPendingRemoval: LocalTranscriptionModel?
    @State private var isModelRemovalConfirmationPresented = false
    @State private var modelBeingRemoved: LocalTranscriptionModel?
    @State private var modelRemovalErrorMessage: String?
    @State private var isActionButtonOnboardingPresented = false


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
    private var settingsContent: some View {
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
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    settingsHeader

                    if #available(iOS 18.0, *), ActionButtonHardware.isSupported {
                        MuesliSurface {
                            SettingsNavigationRow(
                                icon: "button.programmable",
                                title: "Action Button",
                                detail: "Dictation and meeting-note shortcuts."
                            ) { isActionButtonOnboardingPresented = true }
                            .padding(MuesliTheme.spacing16)
                        }
                    }

                    MuesliSurface {
                        VStack(spacing: MuesliTheme.spacing4) {
                            ForEach(SettingsSection.allCases) { section in
                                SettingsSectionRow(section: section) {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSettingsSection = section
                                    }
                                }
                                if section != SettingsSection.allCases.last {
                                    Divider().overlay(MuesliTheme.surfaceBorder)
                                }
                            }
                        }
                        .padding(MuesliTheme.spacing12)
                    }
                }
                .padding(MuesliTheme.spacing20)
            }
        }
    }

    /// Settings subareas are not a navigation stack, so the system back swipe does not exist for them.
    /// A swipe that starts on the strip along the left edge and travels right goes back to the Settings list.
    private var edgeBackSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.translation.width > 60,
                      abs(value.translation.height) < value.translation.width / 2 else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    selectedSettingsSection = nil
                }
            }
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Settings")
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Voice notes, meetings, local models, and privacy.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private func detailHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    selectedSettingsSection = nil
                }
            } label: {
                Label("Settings", systemImage: "chevron.left")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)

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
    private func settingsSectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .about:
            AboutSettingsContent()
        case .appearance:
            appearanceSettings
        case .input:
            inputSettings
        case .dictionary:
            DictionarySettingsContent()
        case .meetings:
            meetingSettings
        case .models:
            modelSettings
        case .syncPrivacy:
            syncPrivacySettings
        case .aiSummaries:
            aiSummarySettings
        case .quill:
            quillSettings
        }
    }

    private var appearanceSettings: some View {
        AppearanceSettingsContent()
    }

    private var inputSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsRow(icon: "keyboard", title: "Keyboard Extension", value: keyboardStatusText)
                    if #available(iOS 18.0, *), ActionButtonHardware.isSupported {
                        Divider().overlay(MuesliTheme.surfaceBorder)
                        SettingsNavigationRow(
                            icon: "button.programmable",
                            title: "Action Button",
                            detail: "Set up or reconfigure dictation and meeting-note shortcuts."
                        ) {
                            isActionButtonOnboardingPresented = true
                            AppTelemetry.signal("action_button_settings_opened")
                        }
                    }
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                        HStack {
                            Text("Open Muesli Settings")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.accent)
                        .padding(.top, MuesliTheme.spacing4)
                    }
                }
                .padding(MuesliTheme.spacing16)
            }

            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsToggleRow(
                        icon: "keyboard.badge.ellipsis",
                        title: "Turn mic off after each dictation",
                        detail: keyboardSessionModeDetail,
                        isOn: keyboardSessionBinding
                    )
                    if coordinator.isKeyboardMicOn {
                        Button("Turn mic off", systemImage: "mic.slash.fill") {
                            Task { await coordinator.turnOffKeyboardMic() }
                        }
                        .frame(minHeight: 44)
                    }
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsKeyboardMicAutoOffRow(
                        minutes: keyboardMicAutoOffBinding,
                        isAvailable: keyboardSessionMode
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsMicrophonePicker(selection: $microphonePreference)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsToggleRow(
                        icon: "waveform.badge.mic",
                        title: "Voice Note Live Activities",
                        detail: "Show keyboard and in-app voice note progress on the Dynamic Island and Lock Screen.",
                        isOn: $liveActivitiesForDictations
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsToggleRow(
                        icon: "waveform.circle",
                        title: "Save Voice Note Audio",
                        detail: "Keep original voice note audio locally on this iPhone for playback and troubleshooting. Audio does not sync.",
                        isOn: $keepDictationAudioRecordings
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    LongVoiceNoteSettingsRow(
                        isEnabled: $longVoiceNoteModeEnabled,
                        thresholdSeconds: $longVoiceNoteThresholdSeconds
                    )
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    private var keyboardSessionBinding: Binding<Bool> {
        Binding(get: { !keyboardSessionMode }, set: { stopAfterEach in
            coordinator.setKeyboardSessionModeEnabled(!stopAfterEach)
        })
    }

    private var keyboardMicAutoOffBinding: Binding<Int> {
        Binding(
            get: { keyboardMicAutoOffMinutes },
            set: { minutes in
                keyboardMicAutoOffMinutes = minutes
                coordinator.setKeyboardMicAutoOffMinutes(minutes)
            }
        )
    }

    private var keyboardSessionModeDetail: String {
        "On: the mic turns off as soon as a dictation ends, and the next keyboard dictation has to open Muesli to start it. Off: the mic stays ready between dictations, so the keyboard starts instantly, until you turn it off in Muesli, on the Lock Screen or in the Dynamic Island, or it turns off by itself (see below)."
    }

    private var meetingSettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsToggleRow(
                    icon: "waveform.path.ecg.rectangle",
                    title: "Save Meeting Audio",
                    detail: "Keep the original meeting recording after delayed transcription finishes. Queued recordings are always kept until transcription completes.",
                    isOn: $keepMeetingAudioRecordings
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "person.2.wave.2",
                    title: "Meeting Live Activities",
                    detail: "Show active meeting recordings while Muesli is recording in the background.",
                    isOn: $liveActivitiesForMeetings
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsMeetingTemplatePicker(selection: $meetingTemplate)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    SettingsRow(
                        icon: "checkmark.seal",
                        title: "Active Model",
                        value: coordinator.selectedTranscriptionModel.shortName,
                        valueColor: MuesliTheme.textSecondary
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    TranscriptionModelSelector(
                        selection: $coordinator.selectedTranscriptionModel,
                        preparation: coordinator.modelPreparation,
                        onSelect: coordinator.selectTranscriptionModel
                    )
                    if coordinator.livePreviewDownloadOffer != .hidden {
                        Divider().overlay(MuesliTheme.surfaceBorder)
                        LivePreviewDownloadRow(
                            offer: coordinator.livePreviewDownloadOffer,
                            onDownload: coordinator.downloadLivePreviewModel
                        )
                    }
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(
                        icon: "cpu",
                        title: "Runtime",
                        value: coordinator.selectedTranscriptionModel.family == .whisper
                            ? "WhisperKit / CoreML"
                            : "FluidAudio / CoreML"
                    )
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(icon: "textformat", title: "Language", value: coordinator.selectedTranscriptionModel.capabilityLabel)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsRow(icon: "iphone", title: "Execution", value: "On device")
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text(coordinator.modelPreparation.status)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.modelPreparation.detail)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress = coordinator.modelPreparation.progress,
                       coordinator.modelPreparation.isPreparing {
                        ProgressView(value: progress)
                            .tint(MuesliTheme.accent)
                    }
                    if coordinator.modelPreparation.phase == .failed {
                        Button {
                            coordinator.prepareModel()
                        } label: {
                            Label("Retry Download", systemImage: "arrow.clockwise")
                                .font(MuesliTheme.headline())
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .foregroundStyle(.white)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(MuesliTheme.spacing16)
            }

            downloadedModelsSettings
        }
    }

    private var downloadedModelsSettings: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Label("Downloaded Models", systemImage: "internaldrive")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Remove models you no longer use to reclaim local storage.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let modelRemovalErrorMessage {
                    Label(modelRemovalErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if downloadedTranscriptionModels.isEmpty {
                    Text("No transcription models are stored locally.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.vertical, MuesliTheme.spacing4)
                } else {
                    ForEach(Array(downloadedTranscriptionModels.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Divider().overlay(MuesliTheme.surfaceBorder)
                        }
                        downloadedModelRow(model)
                    }
                }

                if !coordinator.canRemoveDownloadedModels,
                   modelBeingRemoved == nil,
                   !downloadedTranscriptionModels.isEmpty {
                    Text("Finish the current recording, transcription, or model download before removing a model.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private func downloadedModelRow(_ model: LocalTranscriptionModel) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: model.family == .whisper ? "waveform" : "waveform.path.ecg")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 34, height: 34)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                HStack(spacing: MuesliTheme.spacing4) {
                    Text(model.displayName)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    if model == coordinator.selectedTranscriptionModel {
                        Text("Active")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.accent)
                            .padding(.horizontal, MuesliTheme.spacing8)
                            .padding(.vertical, 2)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(Capsule())
                    }
                }
                Text(model.estimatedSizeLabel)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Spacer(minLength: MuesliTheme.spacing8)

            if modelBeingRemoved == model {
                ProgressView()
                    .tint(MuesliTheme.destructive)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Removing \(model.displayName)")
            } else {
                Button {
                    modelRemovalErrorMessage = nil
                    modelPendingRemoval = model
                    isModelRemovalConfirmationPresented = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MuesliTheme.destructive)
                        .frame(width: 36, height: 36)
                        .background(MuesliTheme.destructive.opacity(0.10))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.canRemoveDownloadedModels)
                .accessibilityLabel("Remove \(model.displayName)")
                .accessibilityIdentifier("model.remove.\(model.rawValue)")
            }
        }
    }

    private var downloadedTranscriptionModels: [LocalTranscriptionModel] {
        LocalTranscriptionModel.allCases.filter { model in
            model.isDownloaded
                || (model == coordinator.selectedTranscriptionModel && coordinator.modelPreparation.isReady)
        }
    }

    private func modelRemovalConfirmationMessage(for model: LocalTranscriptionModel) -> String {
        let storage = "This permanently removes \(model.displayName) from this iPhone and frees its local storage."
        guard model == coordinator.selectedTranscriptionModel else { return storage }
        return "\(storage) It remains selected but unavailable until you select it again to download it."
    }

    private func removeDownloadedModel(_ model: LocalTranscriptionModel) {
        modelBeingRemoved = model
        modelRemovalErrorMessage = nil
        Task {
            do {
                try await coordinator.removeDownloadedModel(model)
            } catch {
                modelRemovalErrorMessage = error.localizedDescription
            }
            modelBeingRemoved = nil
        }
    }

    private var syncPrivacySettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsToggleRow(
                    icon: "icloud",
                    title: "Sync with Mac",
                    detail: "Sync voice note text, meeting transcripts, notes, and summaries through your private iCloud account. Audio is never synced.",
                    isOn: $iCloudSyncEnabled
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsRow(
                    icon: "icloud",
                    title: "iCloud",
                    value: appleSyncSnapshot.iCloudStatusLabel,
                    iconColor: appleSyncSnapshot.isICloudAvailable ? MuesliTheme.success : MuesliTheme.accent,
                    valueColor: appleSyncSnapshot.isICloudAvailable ? MuesliTheme.success : MuesliTheme.textTertiary
                )

                Button {
                    isSyncQRCodeScannerPresented = true
                    AppTelemetry.signal("bridge_qr_scan_started", parameters: ["platform": "ios", "source": "settings"])
                } label: {
                    Label("Scan Mac QR", systemImage: "qrcode.viewfinder")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(MuesliTheme.accent)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.syncICloudTextIfEnabled(reason: "settings_manual")
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .font(MuesliTheme.headline())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(iCloudSyncEnabled ? .white : MuesliTheme.textTertiary)
                        .background(iCloudSyncEnabled ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(!iCloudSyncEnabled)

                Text(appleSyncStatusText ?? appleSyncSnapshot.detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let syncStatus = coordinator.iCloudSyncStatusText {
                    Text(syncStatus)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var aiSummarySettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsToggleRow(
                    icon: "sparkles",
                    title: "Meeting Summaries",
                    detail: "Generate structured notes after local transcription and speaker diarization.",
                    isOn: $meetingSummariesEnabled
                )

                Divider().overlay(MuesliTheme.surfaceBorder)

                Picker("Summary Backend", selection: $meetingSummaryBackend) {
                    ForEach(MeetingSummaryBackend.allCases) { backend in
                        Text(backend.label).tag(backend.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!meetingSummariesEnabled)

                if let note = selectedSummaryBackend.cloudDestinationNote {
                    Text(note)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if selectedSummaryBackend == .openRouter {
                    SettingsTextFieldRow(
                        icon: "key",
                        title: "OpenRouter API Key",
                        placeholder: "sk-or-...",
                        text: $openRouterAPIKey,
                        isSecure: true
                    )
                    .disabled(!meetingSummariesEnabled)

                    SettingsModelPickerRow(
                        icon: "cpu",
                        title: "OpenRouter Model",
                        selection: $openRouterModel,
                        presets: SummaryModelPreset.openRouterModels
                    )
                    .disabled(!meetingSummariesEnabled)
                } else if selectedSummaryBackend == .customLLM {
                    Text(remoteProcessingEnabled
                        ? "Any OpenAI-compatible server, for example your own over Tailscale. Notes, titles and dictation recordings are sent only to this address. Quill uses the same server."
                        : "Any OpenAI-compatible server, for example your own over Tailscale. Notes and titles are sent only to this address. Quill uses the same server.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    customLLMFields
                        .disabled(!meetingSummariesEnabled)

                    if RemoteTranscriptionPolicy.showsCheckbox(
                        endpointConfigured: CustomLLMEndpoint.transcriptionsURL(from: customLLMBaseURL) != nil
                    ) {
                        // Outside the summaries switch: it is about dictation, not notes.
                        RemoteProcessingRow(isOn: $remoteProcessingEnabled, baseURL: customLLMBaseURL, apiKey: customLLMAPIKey)
                    }
                } else {
                    SettingsRow(
                        icon: "person.crop.circle.badge.checkmark",
                        title: "ChatGPT",
                        value: chatGPTSignedIn ? "Signed in" : "Not signed in",
                        iconColor: chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent,
                        valueColor: chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.textTertiary
                    )

                    Button(action: toggleChatGPTSignIn) {
                        Label(
                            chatGPTSignedIn ? "Signed in · Sign Out" : "Sign In with ChatGPT",
                            systemImage: chatGPTSignedIn ? "checkmark.circle.fill" : "person.crop.circle"
                        )
                            .font(MuesliTheme.headline())
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(.white)
                            .background(chatGPTSignedIn ? MuesliTheme.success : MuesliTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)
                    .disabled(!meetingSummariesEnabled)

                    SettingsModelPickerRow(
                        icon: "cpu",
                        title: "ChatGPT Model",
                        selection: $chatGPTModel,
                        presets: SummaryModelPreset.chatGPTModels,
                        preserveCustomValue: false,
                        fallbackSelection: MeetingSummaryBackend.defaultChatGPTModel
                    )
                    .disabled(!meetingSummariesEnabled)
                }

                if let summaryStatusText {
                    Text(summaryStatusText)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var isCustomLLMReady: Bool {
        CustomLLMEndpoint.chatCompletionsURL(from: customLLMBaseURL) != nil
            && !customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var customLLMFields: some View {
        SettingsTextFieldRow(
            icon: "link",
            title: "Server URL",
            placeholder: "https://host.example.ts.net/v1",
            text: $customLLMBaseURL
        )
        .keyboardType(.URL)

        SettingsTextFieldRow(
            icon: "key",
            title: "API Key (optional)",
            placeholder: "Bearer token",
            text: $customLLMAPIKey,
            isSecure: true
        )

        CustomLLMModelRow(model: $customLLMModel, baseURL: customLLMBaseURL, apiKey: customLLMAPIKey)
    }

    private var quillSettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Text("Select text, or put the cursor after it, tap Quill on the Muesli keyboard and say what to change. Quill rewrites the selection, or the last paragraph before the cursor. Undo restores it.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(MuesliTheme.surfaceBorder)

                SettingsRow(
                    icon: "server.rack",
                    title: "Writing model source",
                    value: "Custom LLM",
                    iconColor: isCustomLLMReady ? MuesliTheme.success : MuesliTheme.accent
                )

                Text("The same server Meeting Summaries use when set to Custom. Text is sent only to this address. Editing it here changes it there.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                customLLMFields

                if let summaryStatusText {
                    Text(summaryStatusText)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !isCustomLLMReady {
                    Text("Quill stays off until a server URL and model are set.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private func refreshKeyboardStatus() {
        let store = SharedStore()
        let extensionStatus = try? store.keyboardExtensionStatus()
        let confirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        let fullAccessConfirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.fullAccessConfirmed)

        if extensionStatus?.hasOpenAccess == true {
            keyboardStatusText = "Enabled"
        } else if confirmed && fullAccessConfirmed {
            keyboardStatusText = "Needs first use"
        } else if confirmed {
            keyboardStatusText = "Full Access needed"
        } else {
            keyboardStatusText = "Not confirmed"
        }
    }

    private var selectedSummaryBackend: MeetingSummaryBackend {
        MeetingSummaryBackend(rawValue: meetingSummaryBackend) ?? .defaultBackend
    }

    private func refreshSummarySettings() {
        openRouterAPIKey = MeetingSummaryClient.storedOpenRouterAPIKey()
        customLLMAPIKey = MeetingSummaryClient.storedCustomLLMAPIKey()
        chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
    }

    private func refreshVisibleSettingsIfNeeded() {
        guard isActive else { return }
        refreshKeyboardStatus()
        refreshSummarySettings()
        refreshAppleSyncSettings()
    }

    private func saveOpenRouterAPIKey(_ apiKey: String) {
        do {
            try MeetingSummaryClient.saveOpenRouterAPIKey(apiKey)
            summaryStatusText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenRouter key cleared."
                : "OpenRouter key saved in Keychain."
        } catch {
            summaryStatusText = error.localizedDescription
        }
    }

    private func saveCustomLLMAPIKey(_ apiKey: String) {
        do {
            try MeetingSummaryClient.saveCustomLLMAPIKey(apiKey)
            summaryStatusText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Custom server key cleared."
                : "Custom server key saved in Keychain."
        } catch {
            summaryStatusText = error.localizedDescription
        }
    }

    private func toggleChatGPTSignIn() {
        if chatGPTSignedIn {
            ChatGPTAuthManager.shared.signOut()
            chatGPTSignedIn = false
            summaryStatusText = "Signed out of ChatGPT."
            return
        }

        Task {
            do {
                try await ChatGPTAuthManager.shared.signIn()
                chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                summaryStatusText = "Signed in to ChatGPT."
            } catch {
                chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
                summaryStatusText = error.localizedDescription
            }
        }
    }

    private func refreshAppleSyncSettings() {
        Task {
            guard isActive else { return }
            appleSyncSnapshot = await AppleSyncAccountManager.shared.snapshot()
            guard isActive else { return }
            if iCloudSyncEnabled && !appleSyncSnapshot.isICloudAvailable {
                appleSyncStatusText = "Sign in to iCloud on this iPhone before enabling Muesli sync."
            } else if iCloudSyncEnabled {
                if let remoteDeviceName = MuesliBridgeDeviceIdentity.remoteDeviceDisplayName {
                    appleSyncStatusText = "Private iCloud sync is on with \(remoteDeviceName)."
                } else {
                    appleSyncStatusText = "Private iCloud sync is on. Your Muesli text history follows this iPhone and Mac."
                }
            } else {
                appleSyncStatusText = nil
            }
        }
    }

    @discardableResult
    private func enablePrivateICloudSyncFromQR() -> Bool {
        guard appleSyncSnapshot.isICloudAvailable else {
            appleSyncStatusText = "Sign in to iCloud on this iPhone, then scan the Mac QR again."
            return false
        }
        AppTelemetry.signal("bridge_enable_started", parameters: ["platform": "ios", "source": "settings_qr"])
        if !iCloudSyncEnabled {
            isApplyingQRCodeSyncEnable = true
        }
        iCloudSyncEnabled = true
        appleSyncStatusText = "Syncing your text history through private iCloud..."
        coordinator.syncICloudTextIfEnabled(reason: "settings_qr")
        refreshAppleSyncSettings()
        return true
    }

    private func openRequestedSyncPrivacySection() {
        guard openSyncPrivacyRequest != nil else { return }
        selectedSettingsSection = .syncPrivacy
        coordinator.syncSetupRequestID = nil
    }

    private func openRequestedInputSection() {
        guard openInputRequest != nil else { return }
        selectedSettingsSection = .input
        coordinator.inputSettingsNavigationRequestID = nil
    }

}

enum SettingsSection: String, CaseIterable, Identifiable {
    case input
    case meetings
    case dictionary
    case models
    case aiSummaries
    case quill
    case syncPrivacy
    case appearance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input:
            "Voice Notes"
        case .meetings:
            "Meetings"
        case .dictionary:
            "Dictionary"
        case .models:
            "Models"
        case .aiSummaries:
            "AI Summaries"
        case .quill:
            "Quill"
        case .syncPrivacy:
            "Sync & Privacy"
        case .appearance:
            "Appearance"
        case .about:
            "About"
        }
    }

    var detail: String {
        switch self {
        case .input:
            "Recording retention, live activities, keyboard setup, and voice note sessions."
        case .meetings:
            "Recording, audio retention, live activities, and note templates."
        case .dictionary:
            "Filler word removal, custom phrases, names, and acronyms."
        case .models:
            "Choose and automatically download local Parakeet or Whisper models."
        case .aiSummaries:
            "Meeting summary providers, auth, and model selection."
        case .quill:
            "Tap Quill on the keyboard and say what to change. Uses your Custom LLM server."
        case .syncPrivacy:
            "Private iCloud sync between this iPhone and your Mac."
        case .appearance:
            "Color theme, light and dark mode, and app accent."
        case .about:
            "Version, source code, privacy, and open-source acknowledgements."
        }
    }

    var icon: String {
        switch self {
        case .input:
            "keyboard"
        case .meetings:
            "person.2.wave.2"
        case .dictionary:
            "character.book.closed"
        case .models:
            "cpu"
        case .aiSummaries:
            "sparkles"
        case .quill:
            "pencil.and.outline"
        case .syncPrivacy:
            "icloud"
        case .appearance:
            "paintpalette"
        case .about:
            "info.circle"
        }
    }

}

private struct LongVoiceNoteSettingsRow: View {
    @Binding var isEnabled: Bool
    @Binding var thresholdSeconds: Int
    @State private var customText = ""
    @FocusState private var isCustomFieldFocused: Bool

    private let commonValues = [30, 60, 90, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            SettingsToggleRow(
                icon: "waveform.path.ecg",
                title: "Long Voice Note Mode",
                detail: "Open Long Voice Note after longer recordings.",
                isOn: $isEnabled
            )

            if isEnabled {
                HStack(spacing: MuesliTheme.spacing12) {
                    Text("Switch after")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)

                    Spacer()

                    Menu {
                        ForEach(commonValues, id: \.self) { value in
                            Button(MuesliPreferences.longVoiceNoteThresholdLabel(value)) {
                                thresholdSeconds = value
                                customText = String(value)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(MuesliPreferences.longVoiceNoteThresholdLabel(thresholdSeconds))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(minHeight: 44)
                    }
                }

                HStack(spacing: MuesliTheme.spacing8) {
                    TextField("Seconds", text: $customText)
                        .keyboardType(.numberPad)
                        .focused($isCustomFieldFocused)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .frame(height: 44)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                        .onSubmit(commitCustomValue)

                    Stepper("Threshold seconds", value: $thresholdSeconds, in: 30...600, step: 5)
                        .labelsHidden()
                }

                Text("30 seconds to 10 minutes")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .onAppear {
            thresholdSeconds = MuesliPreferences.clampedLongVoiceNoteThreshold(thresholdSeconds)
            customText = String(thresholdSeconds)
        }
        .onChange(of: thresholdSeconds) { _, value in
            let clamped = MuesliPreferences.clampedLongVoiceNoteThreshold(value)
            if thresholdSeconds != clamped {
                thresholdSeconds = clamped
                return
            }
            customText = String(clamped)
            signalThresholdChanged(clamped)
        }
        .onChange(of: isEnabled) { _, enabled in
            AppTelemetry.signal(
                "long_voice_note_mode_toggled",
                parameters: ["enabled": enabled ? "true" : "false"]
            )
        }
        .onChange(of: customText) { _, value in
            guard value.count > 4 else { return }
            customText = String(value.prefix(4))
        }
        .onChange(of: isCustomFieldFocused) { _, focused in
            if !focused {
                commitCustomValue()
            }
        }
    }

    private func commitCustomValue() {
        let value = Int(customText) ?? thresholdSeconds
        thresholdSeconds = MuesliPreferences.clampedLongVoiceNoteThreshold(value)
        customText = String(thresholdSeconds)
    }

    private func signalThresholdChanged(_ seconds: Int) {
        AppTelemetry.signal(
            "long_voice_note_threshold_changed",
            parameters: ["threshold_bucket": MuesliPreferences.longVoiceNoteThresholdLabel(seconds)]
        )
    }
}

private struct AppearanceSettingsContent: View {
    @AppStorage(MuesliPreferences.appearanceModeKey) private var appearanceMode = MuesliAppearanceMode.system.rawValue
    @AppStorage(MuesliPreferences.accentThemeKey) private var accentTheme = MuesliAccentTheme.blue.rawValue

    private var selectedAppearanceMode: MuesliAppearanceMode {
        MuesliAppearanceMode(rawValue: appearanceMode) ?? .system
    }

    private var selectedAccentTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(rawValue: accentTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsAppearanceModePicker(selection: $appearanceMode)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsAccentThemePicker(selection: $accentTheme)
                }
                .padding(MuesliTheme.spacing16)
            }

            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    Text("Preview")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    appearancePreviewSurface
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    private var appearancePreviewSurface: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                MuesliTheme.accent
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(selectedAccentTheme.label)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(selectedAppearanceMode.label) appearance")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: MuesliTheme.spacing8) {
                previewMetric("3", "streak", tint: Color(hex: 0xFF9F2D))
                previewMetric("152", "WPM", tint: MuesliTheme.success)
                previewRecorderButton
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func previewMetric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MuesliTheme.headline())
                .monospacedDigit()
                .foregroundStyle(MuesliTheme.textPrimary)
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
    }

    private var previewRecorderButton: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
            Text("Record")
                .font(MuesliTheme.captionMedium())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(MuesliTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
    }
}

private struct SettingsSectionRow: View {
    let section: SettingsSection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(section.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(section.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, MuesliTheme.spacing4)
            }
            .padding(.horizontal, MuesliTheme.spacing4)
            .padding(.vertical, MuesliTheme.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Offers the Parakeet Realtime model that streams the keyboard's live preview beside the selected model.
private struct LivePreviewDownloadRow: View {
    let offer: LivePreviewDownloadOffer
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            Spacer()
            if case .downloading(let progress) = offer {
                if let progress {
                    ProgressView(value: progress).frame(width: 56)
                } else {
                    ProgressView()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if case .available = offer { onDownload() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.livePreviewDownload")
    }

    private var title: String {
        switch offer {
        case .available(let size): "Download live preview model (\(size))"
        case .downloading: "Downloading live preview model"
        case .waitingForOtherDownload, .hidden: "Live preview model"
        }
    }

    private var detail: String {
        switch offer {
        case .waitingForOtherDownload: "Available after the current download finishes"
        default: "Shows words in the keyboard while you speak. Your selected model still writes the text."
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    var iconColor = MuesliTheme.accent
    var valueColor = MuesliTheme.textTertiary

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(valueColor)
        }
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(MuesliTheme.accent)
        }
    }
}

/// When the ready keyboard mic turns itself off. Its own row, because it is a separate choice from the toggle
/// above: that one decides whether the mic stays ready at all.
private struct SettingsKeyboardMicAutoOffRow: View {
    @Binding var minutes: Int
    let isAvailable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "timer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Turn mic off when idle")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Picker("Turn mic off when idle", selection: $minutes) {
                ForEach(KeyboardMicAutoOff.choices, id: \.self) { choice in
                    Text(KeyboardMicAutoOff.label(forMinutes: choice)).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(MuesliTheme.accent)
            .disabled(!isAvailable)
        }
        .opacity(isAvailable ? 1 : 0.5)
    }

    private var detail: String {
        guard isAvailable else {
            return "Not needed while the mic turns off after each dictation."
        }
        return "Turns off a ready mic after this long unused, to save battery. Always off when the screen locks."
    }
}

private struct SettingsMicrophonePicker: View {
    @Binding var selection: String

    private var availableOptions: [RecordingMicrophonePreference] {
        let options = AudioInputRouteManager.availablePreferenceOptions()
        guard !options.contains(preference) else { return options }
        return options + [preference]
    }

    private var preference: RecordingMicrophonePreference {
        RecordingMicrophonePreference(rawValue: selection) ?? .automatic
    }

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Microphone")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(preference.detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Picker("Microphone", selection: $selection) {
                ForEach(availableOptions) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(MuesliTheme.accent)
        }
    }
}

struct SettingsTextFieldRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(MuesliTheme.body())
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
    }
}

struct SettingsModelPickerRow: View {
    let icon: String
    let title: String
    @Binding var selection: String
    let presets: [SummaryModelPreset]
    var preserveCustomValue = true
    var fallbackSelection: String?

    private var menuPresets: [SummaryModelPreset] {
        SummaryModelPreset.menuPresets(
            presets,
            currentModel: selection,
            preserveCustomValue: preserveCustomValue
        )
    }

    private var normalizedSelection: String {
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if presets.contains(where: { $0.id == trimmedSelection }) {
            return trimmedSelection
        }
        if preserveCustomValue, !trimmedSelection.isEmpty {
            return trimmedSelection
        }
        return fallbackSelection ?? presets.first?.id ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Picker(title, selection: $selection) {
                ForEach(menuPresets) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .font(MuesliTheme.body())
            .tint(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        let validSelection = normalizedSelection
        guard selection != validSelection else { return }
        selection = validSelection
    }
}

private struct SettingsAppearanceModePicker: View {
    @Binding var selection: String

    private var selectedMode: MuesliAppearanceMode {
        MuesliAppearanceMode(rawValue: selection) ?? .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Color Scheme")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Currently \(selectedMode.label.lowercased()).")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            Picker("Color Scheme", selection: $selection) {
                ForEach(MuesliAppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        guard MuesliAppearanceMode(rawValue: selection) == nil else { return }
        selection = MuesliAppearanceMode.system.rawValue
    }
}

private struct SettingsAccentThemePicker: View {
    @Binding var selection: String

    private var selectedTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(rawValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Accent")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(selectedTheme.label)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                ForEach(MuesliAccentTheme.allCases) { theme in
                    Button {
                        selection = theme.rawValue
                    } label: {
                        MuesliTheme.color(for: theme)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        selectedTheme == theme ? MuesliTheme.textPrimary : MuesliTheme.surfaceBorder,
                                        lineWidth: selectedTheme == theme ? 2 : 1
                                    )
                            }
                            .overlay {
                                if selectedTheme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.label) accent")
                }
            }
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        let resolved = MuesliAccentTheme.resolved(rawValue: selection)
        guard selection != resolved.rawValue else { return }
        selection = resolved.rawValue
    }
}

private struct SettingsMeetingTemplatePicker: View {
    @Binding var selection: String

    private var selectedTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(rawValue: selection) ?? .general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Meeting Template")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(selectedTemplate.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Meeting Template", selection: $selection) {
                ForEach(MeetingTemplatePreset.allCases) { template in
                    Text(template.label).tag(template.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(MuesliTheme.body())
            .tint(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    private func normalizeSelectionIfNeeded() {
        guard MeetingTemplatePreset(rawValue: selection) == nil else { return }
        selection = MeetingTemplatePreset.general.rawValue
    }
}

struct AppleSyncAccountSnapshot: Equatable {
    let iCloudStatusLabel: String
    let detail: String
    let isICloudAvailable: Bool

    static let checking = AppleSyncAccountSnapshot(
        iCloudStatusLabel: "Checking",
        detail: "Checking iCloud status.",
        isICloudAvailable: false
    )
}

@MainActor
final class AppleSyncAccountManager {
    static let shared = AppleSyncAccountManager()

    private init() {}

    func snapshot() async -> AppleSyncAccountSnapshot {
        let cloud = await iCloudStatus()

        let detail: String
        if !cloud.isAvailable {
            detail = "Sign in to iCloud on this iPhone to sync text with your Mac."
        } else {
            detail = "Ready for private iCloud text sync. Voice notes, transcripts, notes, and summaries will sync through your iCloud account."
        }

        return AppleSyncAccountSnapshot(
            iCloudStatusLabel: cloud.label,
            detail: detail,
            isICloudAvailable: cloud.isAvailable
        )
    }

    private func iCloudStatus() async -> (label: String, isAvailable: Bool) {
        // UI tests intentionally use an unsigned app bundle. CloudKit aborts
        // that process before invoking its completion handler because the
        // signed iCloud entitlements are absent.
        if ProcessInfo.processInfo.arguments.contains(MuesliAppConstants.uiTestingLaunchArgument) {
            return ("Unavailable", false)
        }

        return await withCheckedContinuation { continuation in
            CKContainer(identifier: ICloudTextSyncEngine.containerIdentifier)
                .accountStatus { status, error in
                    if error != nil {
                        continuation.resume(returning: ("Unavailable", false))
                        return
                    }
                    switch status {
                    case .available:
                        continuation.resume(returning: ("Available", true))
                    case .noAccount:
                        continuation.resume(returning: ("No iCloud account", false))
                    case .restricted:
                        continuation.resume(returning: ("Restricted", false))
                    case .couldNotDetermine:
                        continuation.resume(returning: ("Unknown", false))
                    case .temporarilyUnavailable:
                        continuation.resume(returning: ("Temporarily unavailable", false))
                    @unknown default:
                        continuation.resume(returning: ("Unknown", false))
                    }
                }
        }
    }
}


/// The Custom LLM model: a dropdown of what the server lists, or a text field when it cannot be asked.
/// Opt-in for sending recordings to the Custom LLM server for transcription, with a probe of that route.
private struct RemoteProcessingRow: View {
    @Binding var isOn: Bool
    let baseURL: String
    let apiKey: String
    @State private var status: RemoteProbeOutcome?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            SettingsToggleRow(
                icon: "waveform.badge.magnifyingglass",
                title: RemoteTranscriptionPolicy.checkboxTitle,
                detail: RemoteTranscriptionPolicy.footnote,
                isOn: $isOn
            )
            .accessibilityIdentifier("settings.remoteProcessing")

            if let warning = RemoteTranscriptionPolicy.publicEndpointWarning(baseURL: baseURL) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.remoteProcessing.publicWarning")
            }

            HStack(spacing: MuesliTheme.spacing12) {
                if let status {
                    Text(status.statusRowText)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("settings.remoteProcessing.status")
                }
                Spacer()
                if isTesting {
                    ProgressView()
                } else {
                    Button("Test") { Task { await runTest() } }
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.accent)
                        .accessibilityIdentifier("settings.remoteProcessing.test")
                }
            }
        }
        .onChange(of: baseURL) { _, _ in status = nil }
    }

    private var statusColor: Color {
        guard case .reachable = status else { return MuesliTheme.textTertiary }
        return MuesliTheme.success
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        status = await RemoteTranscriptionService.test(baseURL: baseURL, apiKey: apiKey)
    }
}

private struct CustomLLMModelRow: View {
    @Binding var model: String
    let baseURL: String
    let apiKey: String

    private enum Listing: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    @State private var listing = Listing.idle
    @State private var refreshCount = 0

    private var loadID: String { "\(baseURL)\u{1F}\(apiKey)\u{1F}\(refreshCount)" }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "cpu")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                Text("Model")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
                if listing == .loading {
                    ProgressView()
                } else {
                    Button {
                        refreshCount += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MuesliTheme.accent)
                    .accessibilityLabel("Refresh model list")
                }
            }

            switch listing {
            case .loaded(let ids):
                Picker("Model", selection: $model) {
                    if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Choose a model").tag("")
                    }
                    ForEach(CustomLLMModelCatalog.pickerChoices(listed: ids, current: model), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .tint(MuesliTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MuesliTheme.spacing12)
                .frame(height: 42)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            case .idle, .loading, .failed:
                TextField("model name on the server", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .frame(height: 42)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                if case .failed(let reason) = listing {
                    Text("Could not list the server's models: \(reason). Type the model name instead.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: loadID) { await load() }
    }

    private func load() async {
        guard CustomLLMModelCatalog.modelsURL(from: baseURL) != nil else {
            listing = .idle
            return
        }
        // Wait out typing in the URL or key field before asking the server.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        listing = .loading
        do {
            let ids = try await CustomLLMModelCatalog.fetch(baseURL: baseURL, apiKey: apiKey)
            guard !Task.isCancelled else { return }
            listing = .loaded(ids)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            listing = .failed(error.localizedDescription)
        }
    }
}
