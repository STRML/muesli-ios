import Foundation
import os
import UIKit

/// Binds `DiagnosticsUploadEngine` to the app: the preferences and Keychain key, a state file on disk, `URLSession`,
/// a 15 second loop while diagnostics are on and the app is alive, and a flush when the scene goes to the background.
///
/// This lives in the app process only. The keyboard extension compiles `Shared/` but never this file, so it has no
/// way to upload.
@MainActor
final class DiagnosticsShipper: ObservableObject {
    static let shared = DiagnosticsShipper()

    @Published private(set) var status = DiagnosticsUploadStatus(
        queuedEvents: 0, lastUploadAt: nil, stopped: nil, lastError: nil, retryNotBefore: nil
    )
    @Published private(set) var isSending = false
    @Published private(set) var lastMessage: String?

    private static let logger = Logger(subsystem: MuesliAppConstants.bundleIdentifier, category: "diagnostics-shipping")
    private static let loopInterval: Duration = .seconds(15)

    private let engine: DiagnosticsUploadEngine
    private var loop: Task<Void, Never>?
    private var backgroundFlush: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {
        engine = DiagnosticsUploadEngine(
            store: DiagnosticsFileStateStore(),
            transport: DiagnosticsURLSessionTransport(
                // The remote-transcription session refuses redirects, so a 307 cannot carry the key elsewhere.
                session: RemoteTranscriptionClient.makeSession(),
                currentKey: { MeetingSummaryClient.storedCustomLLMAPIKey() }
            ),
            clock: SystemDiagnosticsClock(),
            deviceInfo: { DiagnosticsShipper.deviceInfo() }
        )
    }

    // MARK: Lifecycle

    /// Call at launch and whenever the toggle, the acknowledgement or the endpoint changes.
    func settingsChanged() {
        guard MuesliPreferences.diagnosticsShippingEnabled else {
            loop?.cancel()
            loop = nil
            Task {
                await engine.disableAndClear()
                status = await engine.status()
            }
            return
        }
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick(.timer)
                    try? await Task.sleep(for: Self.loopInterval)
                }
            }
        }
    }

    /// Called when the scene goes to the background: one last pass, inside a background task so the OS gives it time.
    func sceneDidEnterBackground() {
        guard MuesliPreferences.diagnosticsShippingEnabled, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MuesliDiagnosticsFlush") { [weak self] in
            // Out of time: cancel the request. The engine leaves the batch queued and does not count a failure.
            Task { @MainActor in
                self?.backgroundFlush?.cancel()
                self?.endBackgroundTask()
            }
        }
        backgroundFlush = Task { [weak self] in
            await self?.tick(.background)
            self?.endBackgroundTask()
        }
    }

    /// Send now: queues the whole current log (including what came before diagnostics were turned on), ignores a
    /// wait or a stopped state once, and reports what happened.
    func sendNow() async {
        guard MuesliPreferences.diagnosticsShippingEnabled else { return }
        isSending = true
        defer { isSending = false }
        let report = await tick(.manual, backfill: true)
        lastMessage = Self.message(for: report)
    }

    func resetDeviceID() async {
        MuesliPreferences.resetDiagnosticsDeviceID()
        await engine.resetIdentity()
        status = await engine.status()
        lastMessage = "New device ID created."
    }

    // MARK: A pass

    @discardableResult
    private func tick(_ trigger: DiagnosticsFlushTrigger, backfill: Bool = false) async -> DiagnosticsFlushReport {
        let settings = Self.currentSettings()
        let logText = settings.enabled
            ? await Task.detached(priority: .utility) { KeyboardDiagnosticsLog.exportText() }.value
            : ""
        let report = await engine.run(settings: settings, logText: logText, trigger: trigger, backfill: backfill)
        status = await engine.status()
        if case .failed(let code) = report { Self.logger.notice("upload failed: \(code, privacy: .public)") }
        return report
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: Inputs

    static func currentSettings() -> DiagnosticsRunSettings {
        var endpoint: DiagnosticsEndpoint?
        let resolution = DiagnosticsServerResolver.resolve(
            override: MuesliPreferences.diagnosticsEndpointURL,
            aiSummariesBaseURL: MuesliPreferences.customLLMBaseURL
        )
        if let server = resolution.server {
            endpoint = DiagnosticsEndpoint(
                url: server.url.absoluteString,
                host: server.host,
                looksPrivate: server.looksPrivate,
                keyFingerprint: DiagnosticsKeyFingerprint.of(MeetingSummaryClient.storedCustomLLMAPIKey())
            )
        }
        return DiagnosticsRunSettings(
            enabled: MuesliPreferences.diagnosticsShippingEnabled,
            endpoint: endpoint,
            acknowledgedHost: MuesliPreferences.diagnosticsAcknowledgedHost
        )
    }

    nonisolated static func deviceInfo() -> DiagnosticsDeviceInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return DiagnosticsDeviceInfo(
            deviceID: MuesliPreferences.diagnosticsDeviceID,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            iosVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            deviceModel: model,
            thermalState: thermalLevel(ProcessInfo.processInfo.thermalState).rawValue
        )
    }

    nonisolated static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    private static func message(for report: DiagnosticsFlushReport) -> String {
        switch report {
        case .idle: "Nothing new to send."
        case .busy: "An upload is already in progress. Try again in a moment."
        case .sent(let batches, let events): "Sent \(events) events in \(batches) \(batches == 1 ? "batch" : "batches")."
        case .backingOff: "Waiting to retry."
        case .stopped(.keyRejected): DiagnosticsShippingCopy.keyRejected
        case .stopped(.routeMissing): DiagnosticsShippingCopy.routeMissing
        case .failed(let code): "Could not send (\(code)). Muesli will retry."
        case .blocked(let reason): blockedMessage(reason)
        case .interrupted: "Interrupted. Muesli will retry."
        }
    }

    static func blockedMessage(_ reason: DiagnosticsGate.Reason) -> String {
        switch reason {
        case .toggleOff: "Diagnostics are off."
        case .noEndpoint: DiagnosticsShippingCopy.noEndpoint
        case .publicEndpointNotAcknowledged: "Confirm that you trust this server first."
        }
    }
}

// MARK: - Engine collaborators

struct SystemDiagnosticsClock: DiagnosticsClock {
    func now() -> Date { Date() }
}

/// The queue on disk, in the app's own Application Support (not the app group, so the keyboard cannot read or write
/// it) and excluded from backups. The file is bounded by the engine's 2 MB cap.
final class DiagnosticsFileStateStore: DiagnosticsStateStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL = DiagnosticsFileStateStore.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("upload-state.json")
    }

    func load() -> DiagnosticsUploadState? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DiagnosticsUploadState.self, from: data)
        }
    }

    func save(_ state: DiagnosticsUploadState) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(state) else { return }
            var directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            try? directory.setResourceValues(excluded)
            // Readable after the first unlock, so a background flush works while the phone is locked.
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - System signals worth a log line

/// Memory warnings and thermal changes, recorded whether or not diagnostics are shipped: they are part of the local
/// log either way, and they are the usual suspects when the OS kills a transcription.
enum DiagnosticsSystemObservers {
    @MainActor private static var installed = false

    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            KeyboardDiagnosticsLog.record(DiagnosticsEvents.memoryWarning())
        }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            KeyboardDiagnosticsLog.record(DiagnosticsEvents.thermalState(
                DiagnosticsShipper.thermalLevel(ProcessInfo.processInfo.thermalState)
            ))
        }
    }
}
