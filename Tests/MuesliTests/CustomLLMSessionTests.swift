import XCTest
@testable import Muesli

final class CustomLLMSessionTests: XCTestCase {
    private let studio = URL(string: "https://studio.example.ts.net/v1/chat/completions")!

    func testRedirectsStayOnTheSameSchemeHostAndPort() {
        XCTAssertTrue(CustomLLMSession.allowsRedirect(
            from: studio, to: URL(string: "https://STUDIO.example.ts.net/v2/chat/completions")
        ))
        XCTAssertTrue(CustomLLMSession.allowsRedirect(
            from: studio, to: URL(string: "https://studio.example.ts.net:443/v1/chat/completions/")
        ))
    }

    func testRedirectsToAnotherHostSchemeOrPortAreRefused() {
        XCTAssertFalse(CustomLLMSession.allowsRedirect(
            from: studio, to: URL(string: "https://elsewhere.example.com/v1/chat/completions")
        ))
        XCTAssertFalse(CustomLLMSession.allowsRedirect(
            from: studio, to: URL(string: "https://studio.example.ts.net.evil.example/v1/chat/completions")
        ))
        XCTAssertFalse(CustomLLMSession.allowsRedirect(
            from: studio, to: URL(string: "http://studio.example.ts.net/v1/chat/completions")
        ))
        XCTAssertFalse(CustomLLMSession.allowsRedirect(
            from: studio, to: URL(string: "https://studio.example.ts.net:8443/v1/chat/completions")
        ))
        XCTAssertFalse(CustomLLMSession.allowsRedirect(from: studio, to: nil))
        XCTAssertFalse(CustomLLMSession.allowsRedirect(from: nil, to: studio))
    }

    /// Drives the real session factory against a stub server that answers 307 to another host.
    func testACrossHostRedirectNeverReachesTheOtherHost() async {
        RedirectingStubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingStubProtocol.self]
        let session = CustomLLMSession.make(configuration: configuration)
        var request = URLRequest(url: studio)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("transcript".utf8)

        let response = try? await session.data(for: request).1 as? HTTPURLResponse

        XCTAssertEqual(RedirectingStubProtocol.requestedHosts(), ["studio.example.ts.net"])
        if let response {
            XCTAssertEqual(response.statusCode, 307, "the refused redirect comes back as the 307 itself")
        }
    }
}

private final class RedirectingStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []
    static let elsewhere = URL(string: "https://elsewhere.example.com/v1/chat/completions")!

    static func reset() { lock.withLock { hosts = [] } }
    static func requestedHosts() -> [String] { lock.withLock { hosts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.hosts.append(url.host ?? "") }

        let isStudio = url.host == "studio.example.ts.net"
        let response = HTTPURLResponse(
            url: url,
            statusCode: isStudio ? 307 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: isStudio ? ["Location": Self.elsewhere.absoluteString] : [:]
        )!
        if isStudio {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.elsewhere), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
