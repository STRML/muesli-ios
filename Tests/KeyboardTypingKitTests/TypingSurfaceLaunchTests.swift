import XCTest
@testable import KeyboardTypingKit

/// Which page the keyboard opens on: the remembered one, unless setup verification needs the Dictate page.
final class TypingSurfaceLaunchTests: XCTestCase {
    private func launch(
        _ stored: String?, layout: KeyboardLayout = .full, verification: Bool = false, dictating: Bool = false
    ) -> TypingSurface {
        TypingSurface.atLaunch(
            layout: layout, stored: stored, hasPendingSetupVerification: verification, isDictationActive: dictating)
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

    // MARK: Minimal layout: the Dictate page is the keyboard

    /// N1-N3: whatever was remembered, whatever is stored, Minimal opens on Dictate.
    func testMinimalAlwaysOpensOnDictate() {
        for stored in [nil, "type", "dictate", "", "Dictate", "emoji"] as [String?] {
            XCTAssertEqual(launch(stored, layout: .minimal), .dictate, "\(String(describing: stored))")
        }
    }

    /// N4: setup verification and a running dictation change nothing under Minimal; there is no other page.
    func testMinimalIgnoresSetupVerificationAndARunningDictation() {
        XCTAssertEqual(launch("type", layout: .minimal, verification: true), .dictate)
        XCTAssertEqual(launch("type", layout: .minimal, dictating: true), .dictate)
        XCTAssertEqual(launch("type", layout: .minimal, verification: true, dictating: true), .dictate)
    }

    /// N5: the per-render rule too, not only the launch rule.
    func testMinimalResolvesToDictateWhateverIsSelected() {
        for selected in [TypingSurface.type, .dictate] {
            for verification in [false, true] {
                for dictating in [false, true] {
                    XCTAssertEqual(
                        TypingSurface.resolve(
                            layout: .minimal, selected: selected,
                            hasPendingSetupVerification: verification, isDictationActive: dictating),
                        .dictate)
                }
            }
        }
    }

    /// N6: Full is the rule PR 22 shipped, whatever the layout argument's spelling.
    func testFullKeepsTheRememberedPageRules() {
        XCTAssertEqual(launch("dictate", layout: .full), .dictate)
        XCTAssertEqual(launch("type", layout: .full), .type)
        XCTAssertEqual(launch("type", layout: .full, verification: true), .dictate)
        XCTAssertEqual(launch("type", layout: .full, dictating: true), .type)
    }

    /// N7: only Full has a Type page to show, choose or remember.
    func testOnlyFullOffersTheTypePage() {
        XCTAssertTrue(KeyboardLayout.full.offersTypePage)
        XCTAssertFalse(KeyboardLayout.minimal.offersTypePage)
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
