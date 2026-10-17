import Foundation
import XCTest
@testable import DiagnosticsKit

/// A clock the test moves by hand, so no test reads the wall clock.
final class ManualClock: DiagnosticsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

final class MemoryStateStore: DiagnosticsStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: DiagnosticsUploadState?
    private(set) var saveCount = 0

    func load() -> DiagnosticsUploadState? { lock.withLock { state } }
    func save(_ state: DiagnosticsUploadState) { lock.withLock { self.state = state; saveCount += 1 } }
    func clear() { lock.withLock { state = nil } }
}

/// Answers sends from a script, then with `fallback`, and records every request.
final class ScriptedTransport: DiagnosticsTransport, @unchecked Sendable {
    struct Sent: Equatable {
        var batchID: String
        var target: DiagnosticsTargetRecord
        var envelope: DiagnosticsEnvelope
    }

    private let lock = NSLock()
    private var script: [DiagnosticsTransportResult]
    private var fallback: DiagnosticsTransportResult
    private var log: [Sent] = []

    init(_ script: [DiagnosticsTransportResult] = [], fallback: DiagnosticsTransportResult = .status(200)) {
        self.script = script
        self.fallback = fallback
    }

    var sent: [Sent] { lock.withLock { log } }

    func setFallback(_ result: DiagnosticsTransportResult) { lock.withLock { fallback = result } }

    func send(body: Data, batchID: String, target: DiagnosticsTargetRecord) async -> DiagnosticsTransportResult {
        let envelope = try? JSONDecoder().decode(DiagnosticsEnvelope.self, from: body)
        return lock.withLock {
            if let envelope { log.append(Sent(batchID: batchID, target: target, envelope: envelope)) }
            return script.isEmpty ? fallback : script.removeFirst()
        }
    }
}

/// Holds a send open until the test lets it finish, so a second pass can arrive meanwhile.
final class GatedTransport: DiagnosticsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sending = false
    private var continuation: CheckedContinuation<Void, Never>?

    func send(body: Data, batchID: String, target: DiagnosticsTargetRecord) async -> DiagnosticsTransportResult {
        lock.withLock { sending = true }
        await withCheckedContinuation { continuation in lock.withLock { self.continuation = continuation } }
        return .status(200)
    }

    func waitUntilSending() async {
        while !lock.withLock({ sending && continuation != nil }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() { lock.withLock { continuation?.resume(); continuation = nil } }
}

enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let request = UUID(uuidString: "04FCC3FC-0000-4000-8000-000000000001")!
    static let endpointURL = "https://studio.tail13013.ts.net/v1/diagnostics"
    static let device = DiagnosticsDeviceInfo(
        deviceID: "11111111-2222-4333-8444-555555555555",
        appVersion: "0.1.7", appBuild: "9", iosVersion: "26.0", deviceModel: "iPhone18,1", thermalState: "nominal"
    )

    /// One log line as the writer renders it.
    static func line(
        _ offset: TimeInterval,
        _ event: String = "recording.started",
        process: String = "Muesli",
        _ detail: [String: String] = [:]
    ) -> String {
        DiagnosticsLogFormat.line(date: t0.addingTimeInterval(offset), process: process, event: event, detail: detail)
    }

    static func log(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

    static func numbered(_ count: Int, from start: Int = 0) -> String {
        (start..<start + count).map { line(Double($0) * 0.001, "recording.started", ["elapsed_ms": String($0)]) }
            .joined(separator: "\n") + "\n"
    }

    static func engine(
        store: MemoryStateStore = MemoryStateStore(),
        transport: ScriptedTransport = ScriptedTransport(),
        clock: ManualClock = ManualClock(),
        config: DiagnosticsEngineConfig = .standard
    ) -> DiagnosticsUploadEngine {
        DiagnosticsUploadEngine(store: store, transport: transport, clock: clock, deviceInfo: { device }, config: config)
    }
}
