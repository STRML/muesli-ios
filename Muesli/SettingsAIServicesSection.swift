import SwiftUI

extension SettingsView {
    var aiServicesSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            SettingsGroup(title: "Your server") {
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

                if selectedSummaryBackend == .customLLM {
                    Text(remoteProcessingEnabled
                        ? "Any OpenAI-compatible server, for example your own over Tailscale. Notes, titles and dictation recordings are sent only to this address. Quill uses the same server."
                        : "Any OpenAI-compatible server, for example your own over Tailscale. Notes and titles are sent only to this address. Quill uses the same server.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                customLLMFields

                if selectedSummaryBackend == .customLLM,
                   RemoteTranscriptionPolicy.showsCheckbox(
                       endpointConfigured: CustomLLMEndpoint.transcriptionsURL(from: customLLMBaseURL) != nil
                   ) {
                    // Outside the summaries switch: it is about dictation, not notes.
                    RemoteProcessingRow(isOn: $remoteProcessingEnabled, baseURL: customLLMBaseURL, apiKey: customLLMAPIKey)
                }

                if !isCustomLLMReady {
                    Text("Quill stays off until a server URL and model are set.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup(title: "Summary provider") {
                if let reason = SettingsPresentation.summaryProviderDisabledReason(summariesEnabled: meetingSummariesEnabled) {
                    Text(reason)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.summaryProvider.disabledReason")
                }

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
                } else if selectedSummaryBackend == .chatGPT {
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
            }

            if let summaryStatusText {
                Text(summaryStatusText)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var isCustomLLMReady: Bool {
        CustomLLMEndpoint.chatCompletionsURL(from: customLLMBaseURL) != nil
            && !customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    var customLLMFields: some View {
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

    var selectedSummaryBackend: MeetingSummaryBackend {
        MeetingSummaryBackend(rawValue: meetingSummaryBackend) ?? .defaultBackend
    }

    func refreshSummarySettings() {
        openRouterAPIKey = MeetingSummaryClient.storedOpenRouterAPIKey()
        customLLMAPIKey = MeetingSummaryClient.storedCustomLLMAPIKey()
        chatGPTSignedIn = ChatGPTAuthManager.shared.isAuthenticated
    }

    func saveOpenRouterAPIKey(_ apiKey: String) {
        do {
            try MeetingSummaryClient.saveOpenRouterAPIKey(apiKey)
            summaryStatusText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenRouter key cleared."
                : "OpenRouter key saved in Keychain."
        } catch {
            summaryStatusText = error.localizedDescription
        }
    }

    func saveCustomLLMAPIKey(_ apiKey: String) {
        do {
            try MeetingSummaryClient.saveCustomLLMAPIKey(apiKey)
            summaryStatusText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Custom server key cleared."
                : "Custom server key saved in Keychain."
        } catch {
            summaryStatusText = error.localizedDescription
        }
    }

    func toggleChatGPTSignIn() {
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
}

/// Opt-in for sending recordings to the Custom LLM server for transcription, with a probe of that route.
struct RemoteProcessingRow: View {
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
                        .frame(minWidth: SettingsAccessibility.minimumTapTarget, minHeight: SettingsAccessibility.minimumTapTarget)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("settings.remoteProcessing.test")
                }
            }
        }
        .onChange(of: baseURL) { _, _ in status = nil }
    }

    var statusColor: Color {
        guard case .reachable = status else { return MuesliTheme.textTertiary }
        return MuesliTheme.success
    }

    func runTest() async {
        isTesting = true
        defer { isTesting = false }
        status = await RemoteTranscriptionService.test(baseURL: baseURL, apiKey: apiKey)
    }
}

/// The Custom LLM model: a dropdown of what the server lists, or a text field when it cannot be asked.
struct CustomLLMModelRow: View {
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

    var loadID: String { "\(baseURL)\u{1F}\(apiKey)\u{1F}\(refreshCount)" }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "cpu")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
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

    func load() async {
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
