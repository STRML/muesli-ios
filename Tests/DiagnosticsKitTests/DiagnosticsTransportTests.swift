import XCTest
@testable import DiagnosticsKit

/// A URLProtocol that answers from a closure and records what it was asked. No socket is opened.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int)
        case failure(URLError.Code)
        case never
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var retryAfter: String?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var reply: Reply = .status(200)

    static func reset(_ reply: Reply) {
        lock.withLock { requests = []; bodies = []; self.reply = reply }
    }

    static var seen: [(request: URLRequest, body: Data)] {
        lock.withLock { Array(zip(requests, bodies)).map { ($0, $1) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        } else {
            body = request.httpBody ?? Data()
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.requests.append(request)
            Self.bodies.append(body)
            return Self.reply
        }
        switch reply {
        case .status(let code):
            let headers = Self.retryAfter.map { ["Retry-After": $0] }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .never:
            break
        }
    }

    override func stopLoading() {}
}

final class DiagnosticsTransportTests: XCTestCase {
    private let target = DiagnosticsTargetRecord(
        endpoint: "https://studio.tail13013.ts.net/v1/diagnostics",
        keyFingerprint: DiagnosticsKeyFingerprint.of("studio-key")
    )

    private func transport(key: String = "studio-key") -> DiagnosticsURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DiagnosticsURLSessionTransport(session: URLSession(configuration: configuration), currentKey: { key })
    }

    func testPostsTheBodyToTheExactTargetWithTheBearerKeyAndTheBatchIDAsIdempotencyKey() async {
        StubURLProtocol.reset(.status(200))
        let body = Data(#"{"schema":1}"#.utf8)
        let result = await transport().send(body: body, batchID: "B-1", target: target)
        XCTAssertEqual(result, .status(200))
        let seen = StubURLProtocol.seen
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].request.url?.absoluteString, target.endpoint)
        XCTAssertEqual(seen[0].request.httpMethod, "POST")
        XCTAssertEqual(seen[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer studio-key")
        XCTAssertEqual(seen[0].request.value(forHTTPHeaderField: "Idempotency-Key"), "B-1")
        XCTAssertEqual(seen[0].request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(seen[0].body, body)
    }

    func testNoKeyMeansNoAuthorizationHeader() async {
        StubURLProtocol.reset(.status(200))
        let keyless = DiagnosticsTargetRecord(endpoint: target.endpoint, keyFingerprint: DiagnosticsKeyFingerprint.of(""))
        _ = await transport(key: "  ").send(body: Data(), batchID: "B", target: keyless)
        XCTAssertNil(StubURLProtocol.seen.first?.request.value(forHTTPHeaderField: "Authorization"))
    }

    func testStatusesPassThroughForTheEngineToClassify() async {
        for status in [200, 401, 404, 503] {
            StubURLProtocol.reset(.status(status))
            let result = await transport().send(body: Data(), batchID: "B", target: target)
            XCTAssertEqual(result, .status(status))
        }
    }

    func testRetryAfterOnA429OrA503IsPassedOnInSeconds() async {
        defer { StubURLProtocol.retryAfter = nil }
        StubURLProtocol.retryAfter = "45"
        for status in [429, 503] {
            StubURLProtocol.reset(.status(status))
            let result = await transport().send(body: Data(), batchID: "B", target: target)
            XCTAssertEqual(result, .deferred(status: status, retryAfter: 45))
        }
        StubURLProtocol.reset(.status(401))
        let other = await transport().send(body: Data(), batchID: "B", target: target)
        XCTAssertEqual(other, .status(401), "only 429 and 503 carry a wait")
        StubURLProtocol.retryAfter = "Wed, 21 Oct 2026 07:28:00 GMT"
        StubURLProtocol.reset(.status(429))
        let dated = await transport().send(body: Data(), batchID: "B", target: target)
        XCTAssertEqual(dated, .status(429), "an HTTP date is not understood; the normal backoff applies")
    }

    func testOfflineAndTimeoutAreNetworkFailuresCarryingTheURLErrorCode() async {
        StubURLProtocol.reset(.failure(.notConnectedToInternet))
        var result = await transport().send(body: Data(), batchID: "B", target: target)
        XCTAssertEqual(result, .networkFailure(code: URLError.notConnectedToInternet.rawValue))
        StubURLProtocol.reset(.failure(.timedOut))
        result = await transport().send(body: Data(), batchID: "B", target: target)
        XCTAssertEqual(result, .networkFailure(code: URLError.timedOut.rawValue))
    }

    func testAKeyThatChangedSincePassBeganSendsNothing() async {
        StubURLProtocol.reset(.status(200))
        let result = await transport(key: "a-different-key").send(body: Data(), batchID: "B", target: target)
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(StubURLProtocol.seen.isEmpty, "the old queue must not go out under new credentials")
    }

    func testAPlainHTTPTargetSendsNothing() async {
        StubURLProtocol.reset(.status(200))
        let insecure = DiagnosticsTargetRecord(endpoint: "http://studio.tail13013.ts.net/v1/diagnostics", keyFingerprint: target.keyFingerprint)
        let result = await transport().send(body: Data(), batchID: "B", target: insecure)
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(StubURLProtocol.seen.isEmpty)
    }

    func testCancellingTheTaskCancelsTheRequestWithoutCountingAFailure() async {
        StubURLProtocol.reset(.never)
        let transport = transport()
        let target = target
        let task = Task { await transport.send(body: Data(), batchID: "B", target: target) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    func testTheKeyFingerprintIsStableShortAndNotTheKey() {
        let fingerprint = DiagnosticsKeyFingerprint.of("studio-key")
        XCTAssertEqual(fingerprint, DiagnosticsKeyFingerprint.of("  studio-key\n"))
        XCTAssertNotEqual(fingerprint, DiagnosticsKeyFingerprint.of("studio-key2"))
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertFalse(fingerprint.contains("studio"))
    }
}
