import XCTest
@testable import DictationPolicyKit

final class HostAppReturnTests: XCTestCase {
    private let launch = URL(string: "muesli://dictate?request=9B2A1C54-0000-4000-8000-000000000001&action=start")!

    func testKnownHostWithSettingOnReturnsItsScheme() {
        let url = HostAppReturn.returnURL(forHost: "com.apple.mobilenotes", enabled: true)
        XCTAssertEqual(url?.scheme, "mobilenotes")
    }

    func testUnknownHostDoesNothing() {
        XCTAssertNil(HostAppReturn.returnURL(forHost: "com.example.unlisted", enabled: true))
    }

    func testSettingOffDoesNothingEvenForAKnownHost() {
        XCTAssertNil(HostAppReturn.returnURL(forHost: "net.whatsapp.WhatsApp", enabled: false))
    }

    func testMissingHostDoesNothing() {
        XCTAssertNil(HostAppReturn.returnURL(forHost: nil, enabled: true))
    }

    func testSafariHasNoReturnTarget() {
        XCTAssertNil(HostAppReturn.returnURL(forHost: "com.apple.mobilesafari", enabled: true))
    }

    func testMuesliNeverReturnsToItself() {
        let table = HostAppReturn.table.first!.bundleID
        XCTAssertNil(HostAppReturn.returnURL(forHost: table, enabled: true, ownBundleIDs: [table]))
    }

    func testMalformedIdsAreRejected() {
        for bad in ["", " ", "nodots", "a..b", ".com.apple", "com.apple.", "com.apple.notes/../x",
                    "com.apple.notes?x=1", "com.apple.notes\n", String(repeating: "a.", count: 100)] {
            XCTAssertNil(HostAppReturn.returnURL(forHost: bad, enabled: true), "\(bad)")
            XCTAssertEqual(HostAppReturn.appendingHost(bad, to: launch), launch, "\(bad)")
        }
    }

    func testHostSurvivesALaunchURLRoundTrip() {
        let url = HostAppReturn.appendingHost("com.tinyspeck.chatlyio", to: launch)
        XCTAssertEqual(HostAppReturn.hostBundleID(in: url), "com.tinyspeck.chatlyio")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "request" }?.value, "9B2A1C54-0000-4000-8000-000000000001")
        XCTAssertEqual(items.first { $0.name == "action" }?.value, "start")
    }

    func testOldURLWithoutHostStillParsesAndYieldsNoHost() {
        XCTAssertNil(HostAppReturn.hostBundleID(in: launch))
        XCTAssertNil(HostAppReturn.returnURL(forHost: HostAppReturn.hostBundleID(in: launch), enabled: true))
    }

    func testAppendingTwiceKeepsOneHostItem() {
        let once = HostAppReturn.appendingHost("com.apple.mobilemail", to: launch)
        let twice = HostAppReturn.appendingHost("com.apple.MobileSMS", to: once)
        let hosts = (URLComponents(url: twice, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "host" }
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(HostAppReturn.hostBundleID(in: twice), "com.apple.MobileSMS")
    }

    func testEveryTableEntryHasAUniqueBundleIDAndAUsableScheme() {
        let ids = HostAppReturn.table.map { $0.bundleID.lowercased() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for entry in HostAppReturn.table {
            XCTAssertNotNil(entry.url.scheme)
            XCTAssertNotNil(HostAppReturn.sanitized(entry.bundleID))
        }
    }
}
