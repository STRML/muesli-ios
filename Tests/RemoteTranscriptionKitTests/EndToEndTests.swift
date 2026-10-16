import XCTest
@testable import RemoteTranscriptionKit

/// Orchestrator, client and loopback stub together: what actually crosses the wire.
final class EndToEndTests: XCTestCase {
    private let secret = "SECRET-KEY-do-not-log"
    private let timing = RemoteTranscriptionTiming(probeThreshold: 0.25, resultBudget: 1.5, unresolvedProbeGrace: 0.05)
    private let eligible = RemoteRequestContext(settingEnabled: true, endpointConfigured: true)

    private func orchestrator(for server: MockServer, log: LogSink = LogSink()) -> RemoteTranscriptionOrchestrator {
        let client = server.client(apiKey: secret)
        let cache = RemoteProbeCache(ttl: 30, probe: { [timing] in await client.probe(timeout: timing.probeThreshold) })
        return RemoteTranscriptionOrchestrator(
            timing: timing,
            probe: { await cache.outcome() },
            upload: { try await client.transcribe(audioURL: $0) },
            prewarm: { await cache.prewarm() },
            log: { log.append($0) }
        )
    }

    private func routeServer() -> MockServer {
        let server = MockServer()
        server.respond { request in
            request.bodyText.contains("name=\"file\"")
                ? .json(#"{"text":"the remote words"}"#)
                : .status(400)
        }
        return server
    }

    func testAFastServerTranscribesTheRecordingAndItsTextWins() async throws {
        let server = routeServer()
        let audio = makeAudioFile(test: self)
        let slowLocal: @Sendable () async throws -> String = {
            try await Task.sleep(for: .milliseconds(150))
            return "on device words"
        }
        let outcome = try await orchestrator(for: server).transcribe(audioURL: audio, context: eligible, local: slowLocal)
        XCTAssertEqual(outcome, .init(text: "the remote words", source: .remote))
        XCTAssertEqual(server.requests.count, 2, "one probe, one upload")
    }

    func testRow03EndpointWithoutARouteGetsOneProbeAndNoRecording() async throws {
        let server = MockServer()
        server.respondAlways(.status(404))
        let audio = makeAudioFile(test: self)
        let outcome = try await orchestrator(for: server).transcribe(
            audioURL: audio, context: eligible, local: { "on device words" }
        )
        XCTAssertEqual(outcome, .init(text: "on device words", source: .onDevice))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.filter { $0.bodyText.contains("name=\"file\"") }.count, 0)
    }

    func testRow09ASlowProbeOnAnyLinkSendsNoRecording() async throws {
        let server = MockServer()
        server.respond { _ in .status(400, delay: 0.6) }
        let audio = makeAudioFile(test: self)
        let outcome = try await orchestrator(for: server).transcribe(
            audioURL: audio, context: eligible, local: { "on device words" }
        )
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertEqual(server.requests.count, 1, "the probe only")
    }

    func testRow13ARedirectingServerNeverReceivesOrForwardsTheRecording() async throws {
        let elsewhere = MockServer()
        elsewhere.respondAlways(.json(#"{"text":"stolen"}"#))
        let server = MockServer()
        server.respondAlways(MockServer.Reply(status: 307, redirectTo: elsewhere.transcriptionsURL))
        let audio = makeAudioFile(test: self)
        let outcome = try await orchestrator(for: server).transcribe(
            audioURL: audio, context: eligible, local: { "on device words" }
        )
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertTrue(elsewhere.requests.isEmpty)
    }

    func testRow05UploadFailureAfterAFastProbeUsesOnDeviceTextAndNeverLogsTheKey() async throws {
        let server = MockServer()
        server.respond { request in
            request.bodyText.contains("name=\"file\"") ? .fail(.networkConnectionLost) : .status(400)
        }
        let log = LogSink()
        let audio = makeAudioFile(test: self)
        let outcome = try await orchestrator(for: server, log: log).transcribe(
            audioURL: audio, context: eligible, local: { "on device words" }
        )
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertEqual(server.requests.count, 2, "one probe, one upload attempt, no retry")
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertFalse(log.lines.joined().contains(secret))
        XCTAssertFalse(log.lines.joined().contains(server.host))
    }

    func testSettingOffSendsNoRequestAtAll() async throws {
        let server = routeServer()
        let audio = makeAudioFile(test: self)
        let orchestrator = orchestrator(for: server)
        let off = RemoteRequestContext(settingEnabled: false, endpointConfigured: true)
        await orchestrator.prewarmIfEligible(context: off)
        let outcome = try await orchestrator.transcribe(audioURL: audio, context: off, local: { "on device words" })
        XCTAssertEqual(outcome.source, .onDevice)
        XCTAssertTrue(server.requests.isEmpty, "not even a probe")
    }
}
