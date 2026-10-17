import SwiftUI

/// The "Diagnostics" section of About: the opt-in toggle, where it sends, how the last upload went, Send now and
/// Reset device ID, and a plain statement of what is and is not sent.
struct DiagnosticsShippingSettings: View {
    @AppStorage(MuesliPreferences.diagnosticsShippingEnabledKey) private var enabled = false
    @AppStorage(MuesliPreferences.diagnosticsAcknowledgedHostKey) private var acknowledgedHost = ""
    @AppStorage(MuesliPreferences.customLLMBaseURLKey) private var baseURL = ""
    @ObservedObject private var shipper = DiagnosticsShipper.shared

    private var endpointHost: String? {
        CustomLLMEndpoint.diagnosticsURL(from: baseURL)?.host?.lowercased()
    }

    private var publicWarning: String? {
        endpointHost == nil ? nil : RemoteTranscriptionPolicy.publicEndpointWarning(baseURL: baseURL)
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

                    SettingsRow(
                        icon: "link",
                        title: "Server",
                        value: endpointHost ?? "Not set"
                    )
                    .accessibilityIdentifier("settings.diagnostics.endpoint")

                    if endpointHost == nil {
                        note(DiagnosticsShippingCopy.noEndpoint)
                    }

                    if let publicWarning, let host = endpointHost {
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
