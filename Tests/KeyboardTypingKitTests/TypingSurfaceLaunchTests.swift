import XCTest
@testable import KeyboardTypingKit

/// Which page the keyboard opens on: the remembered one, unless setup verification needs the Dictate page.
final class TypingSurfaceLaunchTests: XCTestCase {
    private func launch(
        _ stored: String?, verification: Bool = false, dictating: Bool = false
    ) -> TypingSurface {
        TypingSurface.atLaunch(stored: stored, hasPendingSetupVerification: verification, isDictationActive: dictating)
    }

    func testFirstLaunchOpensOnType() {
        XCTAssertEqual(launch(nil), .type)
    }

    func testRememberedDictateOpensOnDictate() {
        XCTAssertEqual(launch("dictate"), .dictate)
    }

    func testRememberedTypeOpensOnType() {
        XCTAssertEqual(launch("type"), .type)
    }

    func testPendingSetupVerificationForcesDictateOverARememberedType() {
        XCTAssertEqual(launch("type", verification: true), .dictate)
        XCTAssertEqual(launch(nil, verification: true), .dictate)
    }

    func testARunningDictationNeverForcesAPage() {
        XCTAssertEqual(launch("type", dictating: true), .type)
        XCTAssertEqual(launch("dictate", dictating: true), .dictate)
        XCTAssertEqual(launch("type", verification: true, dictating: true), .type)
    }

    func testACorruptedStoredValueOpensOnType() {
        for junk in ["", " ", "Dictate", "DICTATE", "dictate\n", "0", "1", "true", "\u{0}"] {
            XCTAssertEqual(launch(junk), .type, "\(junk.debugDescription)")
        }
    }

    /// A later build may store a page this one does not know. The older build opens on Type and does not crash.
    func testAnUnknownValueFromANewerBuildOpensOnType() {
        XCTAssertEqual(launch("emoji"), .type)
        XCTAssertEqual(launch("dictate-v2"), .type)
    }

    func testStoredValuesRoundTrip() {
        for surface in [TypingSurface.type, .dictate] {
            XCTAssertEqual(TypingSurface(storedValue: surface.storedValue), surface)
        }
        XCTAssertNil(TypingSurface(storedValue: "nope"))
    }
}

/// Whether the globe asks the system to track the touch (tap = next keyboard, long press = the list) or advances
/// on a plain tap.
final class TypingGlobeKeyTests: XCTestCase {
    func testWhenTheSystemNeedsTheKeyTheSystemTracksTheTouch() {
        XCTAssertEqual(TypingGlobeKey.route(needsInputModeSwitchKey: true), .systemTracking)
    }

    /// The system draws its own globe then, and the list is on that one. Ours still switches on a tap.
    func testWhenTheSystemDrawsItsOwnGlobeATapStillAdvances() {
        XCTAssertEqual(TypingGlobeKey.route(needsInputModeSwitchKey: false), .advanceOnTap)
    }

    func testWithNoAnswerATapAdvances() {
        XCTAssertEqual(TypingGlobeKey.route(needsInputModeSwitchKey: nil), .advanceOnTap)
    }
}
