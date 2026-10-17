import SwiftUI

/// The "Diagnostics" section of About: the opt-in toggle, where it sends, how the last upload went, Send now and
/// Reset device ID, and a plain statement of what is and is not sent.
struct DiagnosticsShippingSettings: View {
    @AppStorage(MuesliPreferences.diagnosticsShippingEnabledKey) private var enabled = false
    @AppStorage(MuesliPreferences.diagnosticsAcknowledgedHostKey) private var acknowledgedHost = ""
    @AppStorage(MuesliPreferences.customLLMBaseURLKey) private var baseURL = ""
    @AppStorage(MuesliPreferences.diagnosticsEndpointURLKey) private var endpointOverride = ""
    @ObservedObject private var shipper = DiagnosticsShipper.shared

    private var resolution: DiagnosticsServerResolution {
        DiagnosticsServerResolver.resolve(override: endpointOverride, aiSummariesBaseURL: baseURL)
    }

    private var server: ResolvedDiagnosticsServer? { resolution.server }

    private var publicWarning: String? {
        guard let server, !server.looksPrivate else { return nil }
        return RemoteTranscriptionPolicy.publicEndpointWarningText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(DiagnosticsShippingCopy.sectionTitle.uppercased())
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textTertiary)
                .tracking(0.8)
                .padding(.leading, MuesliTheme.spacing4)

            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsToggleRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: DiagnosticsShippingCopy.toggleTitle,
                        detail: DiagnosticsShippingCopy.toggleDetail,
                        isOn: $enabled
                    )
                    .accessibilityIdentifier("settings.diagnostics.toggle")

                    SettingsTextFieldRow(
                        icon: "link",
                        title: DiagnosticsShippingCopy.serverFieldTitle,
                        placeholder: DiagnosticsShippingCopy.serverFieldPlaceholder,
                        text: $endpointOverride
                    )
                    .keyboardType(.URL)
                    .accessibilityIdentifier("settings.diagnostics.endpointField")

                    destination

                    if let publicWarning, let host = server?.host {
                        Label(publicWarning, systemImage: "exclamationmark.triangle")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.diagnostics.publicWarning")
                        SettingsToggleRow(
                            icon: "checkmark.shield",
                            title: DiagnosticsShippingCopy.publicEndpointAcknowledgement,
                            detail: "Nothing is sent to \(host) until you turn this on.",
                            isOn: acknowledgementBinding(for: host)
                        )
                        .accessibilityIdentifier("settings.diagnostics.acknowledge")
                    }

                    if let guide = URL(string: DiagnosticsShippingCopy.receiverGuideURL) {
                        Link(destination: guide) {
                            rowLabel(DiagnosticsShippingCopy.receiverGuideTitle, icon: "book", trailing: nil)
                        }
                        .accessibilityIdentifier("settings.diagnostics.receiverGuide")
                    }

                    if enabled {
                        Divider().overlay(MuesliTheme.surfaceBorder)
                        statusRows
                        buttons
                    }

                    Divider().overlay(MuesliTheme.surfaceBorder)
                    note(DiagnosticsShippingCopy.whatIsSent)
                    note(DiagnosticsShippingCopy.whatIsNotSent)
                        .accessibilityIdentifier("settings.diagnostics.notSent")
                }
                .padding(MuesliTheme.spacing16)
            }
        }
        .onChange(of: enabled) { _, _ in shipper.settingsChanged() }
        .onChange(of: baseURL) { _, _ in shipper.settingsChanged() }
        .onChange(of: endpointOverride) { _, _ in shipper.settingsChanged() }
    }

    /// The full address the batches are posted to, and where it came from. Never just a host.
    @ViewBuilder
    private var destination: some View {
        switch resolution {
        case .resolved(let server):
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(DiagnosticsShippingCopy.sendsToTitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Text(server.url.absoluteString)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.diagnostics.endpoint")
                note(server.source == .ownField ? DiagnosticsShippingCopy.fromOwnField : DiagnosticsShippingCopy.fromAISummaries)
            }
        case .invalidOverride:
            Label(DiagnosticsShippingCopy.invalidOverride, systemImage: "exclamationmark.circle")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.diagnostics.invalidOverride")
        case .none:
            note(DiagnosticsShippingCopy.noEndpoint)
                .accessibilityIdentifier("settings.diagnostics.endpoint")
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "clock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
            Text("Last upload")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Group {
                if let last = shipper.status.lastUploadAt {
                    Text(last, style: .relative) + Text(" ago")
                } else {
                    Text("Never")
                }
            }
            .font(MuesliTheme.callout())
            .foregroundStyle(MuesliTheme.textSecondary)
            .accessibilityIdentifier("settings.diagnostics.lastUpload")
        }
        SettingsRow(icon: "tray.full", title: "Waiting to send", value: "\(shipper.status.queuedEvents) events")
            .accessibilityIdentifier("settings.diagnostics.queue")
        if let problem = problemText {
            Label(problem, systemImage: "exclamationmark.circle")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.diagnostics.problem")
        }
        if let message = shipper.lastMessage {
            note(message)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            Task { await shipper.sendNow() }
        } label: {
            rowLabel("Send now", icon: "paperplane", trailing: shipper.isSending ? "Sending..." : nil)
        }
        .buttonStyle(.plain)
        .disabled(shipper.isSending)
        .accessibilityIdentifier("settings.diagnostics.sendNow")
        note(DiagnosticsShippingCopy.sendNowDetail)

        Button {
            Task { await shipper.resetDeviceID() }
        } label: {
            rowLabel("Reset device ID", icon: "arrow.triangle.2.circlepath", trailing: nil)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.diagnostics.resetDeviceID")
        note(DiagnosticsShippingCopy.resetDetail)
    }

    private var problemText: String? {
        switch shipper.status.stopped {
        case .keyRejected: DiagnosticsShippingCopy.keyRejected
        case .routeMissing: DiagnosticsShippingCopy.routeMissing
        case nil: shipper.status.lastError.map { "Last attempt failed (\($0)). Muesli keeps the events and retries." }
        }
    }

    private func acknowledgementBinding(for host: String) -> Binding<Bool> {
        Binding(
            get: { acknowledgedHost.lowercased() == host },
            set: { newValue in
                acknowledgedHost = newValue ? host : ""
                shipper.settingsChanged()
            }
        )
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowLabel(_ title: String, icon: String, trailing: String?) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }
}
