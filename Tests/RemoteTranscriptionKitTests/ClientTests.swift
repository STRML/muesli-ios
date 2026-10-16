import XCTest
@testable import RemoteTranscriptionKit

/// HTTP behaviour against a loopback stub: rows 3, 5, 7, 9, 11, 13 and the server contract.
final class ClientTests: XCTestCase {
    private let secret = "SECRET-KEY-do-not-log"

    // MARK: Probe

    func testRow03ProbeReportsNoRouteForNotFoundAndMethodNotAllowed() async {
        for status in [404, 405] {
            let server = MockServer()
            server.respondAlways(.status(status))
            let outcome = await server.client().probe(timeout: 1)
            XCTAssertEqual(outcome, .noRoute, "HTTP \(status)")
        }
    }

    func testRow03ProbeReportsKeyRejectedForUnauthorized() async {
        let server = MockServer()
        server.respondAlways(.status(401))
        let outcome = await server.client().probe(timeout: 1)
        XCTAssertEqual(outcome, .keyRejected)
    }

    func testProbeTreatsAnAnsweredBadRequestAsAReachableRoute() async {
        let server = MockServer()
        server.respondAlways(.status(400))
        guard case .reachable(let latency) = await server.client().probe(timeout: 1) else {
            return XCTFail("a 400 for an empty form means the route exists")
        }
        XCTAssertGreaterThan(latency, 0)
    }

    func testProbeSendsNoAudioAndTheBearerKeyToTheTranscriptionRoute() async throws {
        let server = MockServer()
        server.respondAlways(.status(400))
        _ = await server.client(apiKey: secret).probe(timeout: 1)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(secret)")
        XCTAssertFalse(request.bodyText.contains("name=\"file\""), "the probe must not carry a recording")
    }

    func testRow09ProbeRunsOnCellularAndLowDataMode() async throws {
        let server = MockServer()
        server.respondAlways(.status(400))
        _ = await server.client().probe(timeout: 1)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(request.allowsExpensive, "cellular must not block the probe")
        XCTAssertTrue(request.allowsConstrained, "Low Data Mode must not block the probe")
    }

    func testRow04ProbeGivesUpAtItsTimeoutWhenTheServerNeverAnswers() async {
        let server = MockServer()
        server.respondAlways(.blackhole)
        // The blackhole never answers, so getting `.timedOut` back at all proves the probe gave up on its own.
        let outcome = await server.client().probe(timeout: 0.15)
        XCTAssertEqual(outcome, .timedOut)
        await eventually("URLSession to deliver stopLoading after the cancel") { server.cancelled >= 1 }
        XCTAssertEqual(server.cancelled, 1, "the abandoned probe must be cancelled, not left running")
    }

    func testRow13ChangedCertificateOrHostReadsAsUnreachableWithoutRetrying() async {
        for code in [URLError.Code.serverCertificateUntrusted, .cannotFindHost, .secureConnectionFailed] {
            let server = MockServer()
            server.respondAlways(.fail(code))
            let outcome = await server.client().probe(timeout: 1)
            XCTAssertEqual(outcome, .unreachable, "\(code)")
            XCTAssertEqual(server.requests.count, 1, "one attempt, no retry loop or prompt")
        }
    }

    func testRow13ARedirectToAnotherHostIsRefusedAndNothingIsSentThere() async {
        let elsewhere = MockServer()
        elsewhere.respondAlways(.status(200))
        let server = MockServer()
        server.respondAlways(MockServer.Reply(status: 307, redirectTo: elsewhere.transcriptionsURL))
        let outcome = await server.client().probe(timeout: 0.5)
        XCTAssertTrue([RemoteProbeOutcome.unreachable, .noRoute, .timedOut].contains(outcome), "\(outcome)")
        XCTAssertTrue(elsewhere.requests.isEmpty, "a redirect must never carry the request to another host")
    }

    // MARK: Upload

    func testTranscribeFollowsTheServerContract() async throws {
        let server = MockServer()
        server.respondAlways(.json(#"{"text":"  hello from the studio \n"}"#))
        let audio = makeAudioFile(bytes: 2048, ext: "m4a", fill: 0x5A, test: self)
        let text = try await server.client(apiKey: secret).transcribe(audioURL: audio)
        XCTAssertEqual(text, "hello from the studio")

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(secret)")
        let contentType = try XCTUnwrap(request.headers["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = request.bodyText
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nqwen3-asr-1.7b"), body)
        // No language field: the server detects it, as the on-device models do, so a non-English dictation is not forced
        // through English decoding.
        XCTAssertFalse(body.contains("name=\"language\""), body)
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.m4a\""))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(request.body.range(of: Data(repeating: 0x5A, count: 2048)) != nil, "the recording bytes travel intact")
        XCTAssertFalse(body.contains(audio.lastPathComponent), "the local file name stays on the phone")
    }

    func testTranscribeOmitsTheAuthorizationHeaderWhenThereIsNoKey() async throws {
        let server = MockServer()
        server.respondAlways(.json(#"{"text":"ok"}"#))
        let audio = makeAudioFile(test: self)
        _ = try await server.client(apiKey: "  ").transcribe(audioURL: audio)
        XCTAssertNil(server.requests.first?.headers["Authorization"])
    }

    func testRow05UploadThatFailsMidWayThrowsOnceAndIsNotRetried() async {
        let server = MockServer()
        server.respondAlways(.fail(.networkConnectionLost))
        let audio = makeAudioFile(test: self)
        do {
            _ = try await server.client().transcribe(audioURL: audio)
            XCTFail("expected a failure")
        } catch let error as RemoteTranscriptionError {
            XCTAssertEqual(error, .transport(URLError.networkConnectionLost.rawValue))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRow07EmptyOrGarbageResponsesAreRejected() async {
        let garbage = [
            "not json at all", #"{"text":""}"#, #"{"text":"   \n"}"#, #"{"text":"..."}"#,
            #"{"text":5}"#, "{}", "[]", #"{"error":"boom"}"#,
        ]
        for body in garbage {
            let server = MockServer()
            server.respondAlways(.json(body))
            let audio = makeAudioFile(test: self)
            do {
                let text = try await server.client().transcribe(audioURL: audio)
                XCTFail("accepted \(body) as \(text)")
            } catch let error as RemoteTranscriptionError {
                XCTAssertEqual(error, .unusableResponse, body)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testServerRefusalsSurfaceTheirStatusAndNothingElse() async {
        for status in [413, 429, 500, 503] {
            let server = MockServer()
            server.respondAlways(.status(status))
            let audio = makeAudioFile(test: self)
            do {
                _ = try await server.client().transcribe(audioURL: audio)
                XCTFail("HTTP \(status) accepted")
            } catch let error as RemoteTranscriptionError {
                XCTAssertEqual(error, .httpStatus(status))
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRecordingOverTheServerLimitIsNeverSent() async throws {
        let server = MockServer()
        server.respondAlways(.json(#"{"text":"ok"}"#))
        let audio = makeAudioFile(bytes: 16, test: self)
        let handle = try FileHandle(forWritingTo: audio)
        try handle.truncate(atOffset: UInt64(RemoteTranscriptionPolicy.maxUploadBytes + 1))
        try handle.close()
        do {
            _ = try await server.client().transcribe(audioURL: audio)
            XCTFail("an oversized recording was uploaded")
        } catch let error as RemoteTranscriptionError {
            XCTAssertEqual(error, .fileTooLarge)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testMissingRecordingIsNeverSent() async {
        let server = MockServer()
        server.respondAlways(.json(#"{"text":"ok"}"#))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).m4a")
        do {
            _ = try await server.client().transcribe(audioURL: missing)
            XCTFail("expected a failure")
        } catch let error as RemoteTranscriptionError {
            XCTAssertEqual(error, .unreadableAudio)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testRow11CancellingAnUploadStopsItAndLeavesTheRecordingUntouched() async throws {
        let server = MockServer()
        server.respondAlways(.blackhole)
        let audio = makeAudioFile(bytes: 4096, fill: 0x7E, test: self)
        let before = try Data(contentsOf: audio)
        let client = server.client()
        let task = Task { try await client.transcribe(audioURL: audio) }
        await eventually("the upload to reach the server") { !server.requests.isEmpty }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {}
        await eventually("URLSession to deliver stopLoading after the cancel") { server.cancelled >= 1 }
        XCTAssertEqual(server.cancelled, 1, "no orphan upload keeps running")
        XCTAssertEqual(try Data(contentsOf: audio), before, "the saved recording is never modified")
    }

    func testTheKeyNeverAppearsInAnErrorsLogCategory() {
        let errors: [RemoteTranscriptionError] = [
            .fileTooLarge, .unreadableAudio, .httpStatus(500), .unusableResponse, .transport(-1005),
        ]
        for error in errors {
            XCTAssertFalse(error.logCategory.isEmpty)
            XCTAssertFalse(error.logCategory.contains(secret))
            XCTAssertFalse(error.logCategory.contains("http"))
        }
    }
}
