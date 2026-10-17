import CloudKit
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var privacySettings: some View {
        if isDiagnosticsScreenPresented {
            diagnosticsScreen
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                syncPrivacySettings
                MuesliSurface {
                    SettingsNavigationRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: DiagnosticsShippingCopy.sectionTitle,
                        detail: "Send the event log to your own server, or copy the keyboard log."
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            isDiagnosticsScreenPresented = true
                        }
                    }
                    .padding(MuesliTheme.spacing16)
                }
            }
        }
    }

    /// Diagnostics is a sub-screen of Privacy and Sync, one level below the section like the section is below the list.
    var diagnosticsScreen: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isDiagnosticsScreenPresented = false
                }
            } label: {
                Label(SettingsSection.syncPrivacy.title, systemImage: "chevron.left")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)

            DiagnosticsShippingSettings()
            CopyKeyboardDiagnosticsRow()
        }
    }

    var syncPrivacySettings: some View {
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

    func refreshAppleSyncSettings() {
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
    func enablePrivateICloudSyncFromQR() -> Bool {
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

    func iCloudStatus() async -> (label: String, isAvailable: Bool) {
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
