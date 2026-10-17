import Foundation
import XCTest
@testable import RemoteTranscriptionKit

/// Thread-safe counter and flag boxes for stubs that run on any executor.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.lock(); isSet = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
}

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

struct StubFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Sleeps for `seconds`, and notes when the sleep was cut short by cancellation.
func cancellableSleep(_ seconds: Double, cancelled: Flag? = nil) async throws {
    do {
        try await Task.sleep(for: .seconds(seconds))
    } catch {
        cancelled?.set()
        throw error
    }
}

/// A loopback stand-in for the user's endpoint. Each instance owns a unique host and its own handler, so tests
/// do not share state. Requests never leave the process.
final class MockServer: @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        let allowsExpensive: Bool
        let allowsConstrained: Bool

        var path: String { url.path }
        var bodyText: String { String(decoding: body, as: UTF8.self) }
    }

    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var delay: TimeInterval = 0
        var failure: URLError.Code?
        var redirectTo: URL?
        var never = false

        static func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> Reply {
            Reply(status: status, body: Data(text.utf8), delay: delay)
        }
        static func status(_ code: Int, delay: TimeInterval = 0) -> Reply { Reply(status: code, delay: delay) }
        static func fail(_ code: URLError.Code) -> Reply { Reply(failure: code) }
        static let blackhole = Reply(never: true)
    }

    let host = "\(UUID().uuidString.lowercased()).mock.test"
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var cancelledCount = 0
    private var handler: @Sendable (Recorded) -> Reply = { _ in .status(404) }

    init() { MockRegistry.register(self) }
    deinit { MockRegistry.unregister(host: host) }

    var baseURL: String { "https://\(host)/v1" }
    var transcriptionsURL: URL { URL(string: "https://\(host)/v1/audio/transcriptions")! }

    func respond(_ handler: @escaping @Sendable (Recorded) -> Reply) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func respondAlways(_ reply: Reply) { respond { _ in reply } }

    var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }
    var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancelledCount }

    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return RemoteTranscriptionClient.makeSession(configuration: configuration)
    }

    func client(apiKey: String = "test-key", model: String = RemoteTranscriptionPolicy.asrModel) -> RemoteTranscriptionClient {
        RemoteTranscriptionClient(endpoint: transcriptionsURL, apiKey: apiKey, model: model, session: makeSession())
    }

    fileprivate func handle(_ request: Recorded) -> Reply {
        lock.lock()
        recorded.append(request)
        let current = handler
        lock.unlock()
        return current(request)
    }

    fileprivate func noteCancelled() { lock.lock(); cancelledCount += 1; lock.unlock() }
}

enum MockRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: MockServer] = [:]

    static func register(_ server: MockServer) {
        lock.lock(); servers[server.host] = server; lock.unlock()
    }
    static func unregister(host: String) {
        lock.lock(); servers[host] = nil; lock.unlock()
    }
    static func server(for host: String?) -> MockServer? {
        guard let host else { return nil }
        lock.lock(); defer { lock.unlock() }
        return servers[host]
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false
    private var server: MockServer?

    override class func canInit(with request: URLRequest) -> Bool {
        MockRegistry.server(for: request.url?.host) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = MockRegistry.server(for: request.url?.host), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.server = server
        let recorded = MockServer.Recorded(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request),
            allowsExpensive: request.allowsExpensiveNetworkAccess,
            allowsConstrained: request.allowsConstrainedNetworkAccess
        )
        let reply = server.handle(recorded)
        if reply.never { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            deliver(reply, for: url)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let wasStopped = stopped
        stopped = true
        stateLock.unlock()
        if !wasStopped { server?.noteCancelled() }
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    private func deliver(_ reply: MockServer.Reply, for url: URL) {
        guard !isStopped else { return }
        if let code = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil
        ) else { return }
        if let target = reply.redirectTo {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A recording on disk, removed when the test ends.
func makeAudioFile(bytes: Int = 4096, ext: String = "m4a", fill: UInt8 = 0x41, test: XCTestCase) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-asr-test-\(UUID().uuidString)")
        .appendingPathExtension(ext)
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: fill, count: bytes))
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// A sleeper for the orchestrator's `sleep` seam. Every wait it is asked for is recorded and parked until the test
/// releases it by its delay, so what the orchestrator schedules and what it waits out is asserted exactly, with no
/// dependence on how loaded the machine is. A cancelled wait throws, as `Task.sleep` does.
final class ManualSleeper: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let delay: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var nextID = 0
    private var waiters: [Waiter] = []
    private var cancelledEarly: Set<Int> = []
    private var requestedDelays: [TimeInterval] = []
    private var releasedDelays: [TimeInterval] = []

    /// Every delay asked for, in request order.
    var requested: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return requestedDelays }
    /// Every delay the test let elapse, in release order.
    var released: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return releasedDelays }
    /// Delays parked right now.
    var pending: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return waiters.map(\.delay) }

    @Sendable func sleep(_ delay: TimeInterval) async throws {
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            nextID += 1
            requestedDelays.append(delay)
            return nextID
        }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledEarly.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, delay: delay, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                cancelledEarly.insert(id)
                lock.unlock()
                return
            }
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Lets every parked wait of this delay elapse.
    func release(_ delay: TimeInterval) {
        lock.lock()
        let due = waiters.filter { $0.delay == delay }
        waiters.removeAll { $0.delay == delay }
        if !due.isEmpty { releasedDelays.append(delay) }
        lock.unlock()
        due.forEach { $0.continuation.resume() }
    }

    /// Suspends until a wait of this delay is parked. Spins on `Task.yield`, so it follows the scheduler, not a timer.
    func waitUntilPending(_ delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("a \(delay)s wait to be scheduled", file: file, line: line) { pending.contains(delay) }
    }
}

/// Yields until `condition` holds. The 30 s cap only turns a hang into a failure; a passing run never gets near it,
/// and nothing in a passing run depends on how long it took.
func eventually(
    _ what: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () -> Bool
) async {
    let giveUp = ContinuousClock.now + .seconds(30)
    while !condition() {
        if ContinuousClock.now > giveUp {
            XCTFail("timed out waiting for \(what)", file: file, line: line)
            return
        }
        await Task.yield()
    }
}

/// Holds an async stub until the test opens it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    func open() {
        lock.lock(); isOpen = true; let toResume = parked; parked = []; lock.unlock()
        toResume.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume() } else { parked.append(continuation); lock.unlock() }
        }
    }

    /// Waits for the gate to open and fails the test, instead of hanging it, if that takes 30 s. Event-driven: the
    /// opening resumes the waiter directly, so there is no poll to starve and no state change to miss. On timeout the
    /// watchdog opens the gate itself, because a continuation parked in `wait()` ignores task cancellation.
    func waitOrFail(_ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let timedOut = Flag()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask {
                guard (try? await Task.sleep(for: .seconds(30))) != nil else { return }
                timedOut.set()
                self.open()
            }
            await group.next()
            group.cancelAll()
        }
        if timedOut.value { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    }
}
