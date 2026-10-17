import XCTest
@testable import Muesli

/// The app's side of the heartbeat: what it writes, when it announces, and that a beat is not news. Rows R29
/// (a probe gets an immediate beat) and R23 (one announcement per change).
///
/// The publisher belongs to the app target, so it speaks the app's own types (`Muesli.SharedStore`), not the copies
/// the keyboard tests compile.
final class AppReadinessPublisherTests: XCTestCase {
    private final class Bus: Muesli.CrossProcessEventPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Muesli.CrossProcessEvent] = []
        var events: [Muesli.CrossProcessEvent] { lock.lock(); defer { lock.unlock() }; return stored }
        func post(_ event: Muesli.CrossProcessEvent) { lock.lock(); stored.append(event); lock.unlock() }
    }

    private var directory: URL!
    private var bus: Bus!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private let boot = Muesli.AppBootIdentity(
        id: UUID(), startedAt: Date(timeIntervalSince1970: 1_799_999_000),
        stamp: Muesli.ReadinessBuildStamp(appVersion: "0.1.7", appBuild: "40", osVersion: "27.0")
    )

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("publisher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bus = Bus()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func publisher(clock: @escaping @Sendable () -> Date) -> Muesli.AppReadinessPublisher {
        Muesli.AppReadinessPublisher(
            store: Muesli.SharedStore(containerURL: directory, eventPoster: bus, bootID: boot.id),
            boot: boot,
            queue: DispatchQueue(label: "test.readiness"),
            clock: clock
        )
    }

    private func read() throws -> Muesli.AppReadinessRecord? {
        try Muesli.SharedStore(containerURL: directory, eventPoster: bus).appReadiness()
    }

    private func announcements() -> Int { bus.events.filter { $0 == .readinessChanged }.count }

    func testStartPublishesTheBootBeforeAnythingElseCanRun() throws {
        let clock = Locked(now)
        let publisher = publisher { clock.value }
        publisher.start(model: .notLoaded, mic: .off)
        defer { publisher.stop() }
        let record = try XCTUnwrap(try read())
        XCTAssertEqual(record.bootID, boot.id)
        XCTAssertEqual(record.stamp, boot.stamp)
        XCTAssertEqual(record.model, .notLoaded)
        XCTAssertEqual(record.heartbeatAt, now)
        XCTAssertEqual(announcements(), 1, "a new boot is news")
    }

    // R23: a beat is not news; a change is.
    func testOnlyAChangeIsAnnouncedAndABeatJustRefreshesTheHeartbeat() throws {
        let clock = Locked(now)
        let publisher = publisher { clock.value }
        publisher.start(model: .notLoaded, mic: .off)
        defer { publisher.stop() }

        clock.mutate { $0 = now.addingTimeInterval(5) }
        publisher.beat(); publisher.flush()
        XCTAssertEqual(try read()?.heartbeatAt, now.addingTimeInterval(5))
        XCTAssertEqual(announcements(), 1)

        publisher.update(model: .loading(since: now, progress: nil), mic: .off); publisher.flush()
        XCTAssertEqual(announcements(), 2)
        publisher.update(model: .loading(since: now, progress: nil), mic: .off); publisher.flush()
        XCTAssertEqual(announcements(), 2, "nothing changed")

        publisher.update(model: .ready, mic: .ready); publisher.flush()
        XCTAssertEqual(announcements(), 3)
        XCTAssertEqual(try read()?.model, .ready)
        XCTAssertEqual(try read()?.mic, .ready)
    }

    func testSmallProgressStepsAreNotAnnounced() throws {
        let clock = Locked(now)
        let publisher = publisher { clock.value }
        publisher.start(model: .downloading(progress: 0.10), mic: .off)
        defer { publisher.stop() }
        publisher.update(model: .downloading(progress: 0.11), mic: .off); publisher.flush()
        publisher.update(model: .downloading(progress: 0.115), mic: .off); publisher.flush()
        XCTAssertEqual(announcements(), 1, "the keyboard re-reads on its own tick")
        XCTAssertEqual(try read()?.model, .downloading(progress: 0.115), "but the record is current")
        publisher.update(model: .downloading(progress: 0.30), mic: .off); publisher.flush()
        XCTAssertEqual(announcements(), 2)
    }

    func testTheBootIdentityNeverChangesWithinAProcess() throws {
        let clock = Locked(now)
        let publisher = publisher { clock.value }
        publisher.start(model: .ready, mic: .ready)
        defer { publisher.stop() }
        publisher.update(model: .notLoaded, mic: .off); publisher.flush()
        XCTAssertEqual(try read()?.bootID, boot.id)
        XCTAssertEqual(try read()?.bootStartedAt, boot.startedAt)
    }

    func testTheHeartbeatCadenceMatchesTheBound() {
        XCTAssertEqual(Muesli.AppLivenessPolicy.heartbeatInterval * 3, Muesli.AppLivenessPolicy.staleAfter)
    }
}
