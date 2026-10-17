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

/// Whether our own globe key is drawn at all: only when the system says it draws none (Apple's
/// `needsInputModeSwitchKey`). Otherwise the system's globe, under the keyboard, is the only one.
final class TypingGlobeKeyTests: XCTestCase {
    func testTheGlobeIsShownWhenTheSystemNeedsOurKey() {
        XCTAssertTrue(TypingGlobeKey.isShown(needsInputModeSwitchKey: true))
    }

    func testTheGlobeIsHiddenWhenTheSystemDrawsItsOwn() {
        XCTAssertFalse(TypingGlobeKey.isShown(needsInputModeSwitchKey: false))
    }

    func testTheGlobeIsHiddenWhileTheAnswerIsUnknown() {
        XCTAssertFalse(TypingGlobeKey.isShown(needsInputModeSwitchKey: nil))
    }

    func testTheDecisionFollowsAnAnswerThatChangesAfterTheFirstRead() {
        let reads: [Bool?] = [nil, true, false, true, nil]
        XCTAssertEqual(reads.map { TypingGlobeKey.isShown(needsInputModeSwitchKey: $0) }, [false, true, false, true, false])
    }
}
