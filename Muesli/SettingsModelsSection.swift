import SwiftUI

extension SettingsView {
    var modelSettings: some View {
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
                    SettingsRow(
                        icon: "iphone",
                        title: "Execution",
                        value: SettingsPresentation.executionLabel(remoteProcessingActive: SettingsPresentation.currentRemoteProcessingActive)
                    )
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

    var downloadedModelsSettings: some View {
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

    func downloadedModelRow(_ model: LocalTranscriptionModel) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: model.family == .whisper ? "waveform" : "waveform.path.ecg")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 34, height: 34)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .accessibilityHidden(true)

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
                        .frame(width: SettingsAccessibility.minimumTapTarget, height: SettingsAccessibility.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.canRemoveDownloadedModels)
                .accessibilityLabel("Remove \(model.displayName)")
                .accessibilityIdentifier("model.remove.\(model.rawValue)")
            }
        }
    }

    var downloadedTranscriptionModels: [LocalTranscriptionModel] {
        LocalTranscriptionModel.allCases.filter { model in
            model.isDownloaded
                || (model == coordinator.selectedTranscriptionModel && coordinator.modelPreparation.isReady)
        }
    }

    func modelRemovalConfirmationMessage(for model: LocalTranscriptionModel) -> String {
        let storage = "This permanently removes \(model.displayName) from this iPhone and frees its local storage."
        guard model == coordinator.selectedTranscriptionModel else { return storage }
        return "\(storage) It remains selected but unavailable until you select it again to download it."
    }

    func removeDownloadedModel(_ model: LocalTranscriptionModel) {
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
}

/// Offers the Parakeet Realtime model that streams the keyboard's live preview beside the selected model.
struct LivePreviewDownloadRow: View {
    let offer: LivePreviewDownloadOffer
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
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

    var title: String {
        switch offer {
        case .available(let size): "Download live preview model (\(size))"
        case .downloading: "Downloading live preview model"
        case .waitingForOtherDownload, .hidden: "Live preview model"
        }
    }

    var detail: String {
        switch offer {
        case .waitingForOtherDownload: "Available after the current download finishes"
        default: "Shows words in the keyboard while you speak. Your selected model still writes the text."
        }
    }
}
