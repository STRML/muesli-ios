import XCTest
@testable import KeyboardTypingKit

/// Matrix rows L1-L9: keys per page, return key variants and keyboard types, and the one shared height.
final class TypingLayoutTests: XCTestCase {
    private func rows(
        _ page: TypingPage = .letters,
        uppercase: Bool = false,
        traits: TypingTraits = TypingTraits(),
        globe: Bool = true
    ) -> [[TypingKey]] {
        TypingLayout.rows(page: page, uppercase: uppercase, traits: traits, showsGlobe: globe)
    }

    private func row(_ rows: [[TypingKey]], _ index: Int) -> [TypingKey] {
        rows.indices.contains(index) ? rows[index] : []
    }

    private func labels(_ row: [TypingKey]) -> [String] {
        row.filter { if case .spacer = $0.action { false } else { true } }.map(\.label)
    }

    // L1
    func testLettersPageIsQwertyInLowercase() {
        let rows = rows()
        XCTAssertEqual(rows.count, TypingMetrics.rowCount)
        XCTAssertEqual(labels(rows[0]), ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
        XCTAssertEqual(labels(rows[1]), ["a", "s", "d", "f", "g", "h", "j", "k", "l"])
        XCTAssertEqual(Array(labels(rows[2]).dropFirst().dropLast()), ["z", "x", "c", "v", "b", "n", "m"])
        XCTAssertEqual(rows[2].first?.action, .shift)
        XCTAssertEqual(rows[2].last?.action, .backspace)
    }

    func testShiftedLettersAreUppercaseAndInsertUppercase() {
        let rows = rows(uppercase: true)
        XCTAssertEqual(labels(rows[0]).first, "Q")
        XCTAssertEqual(rows[0].first?.action, .character("Q"))
    }

    // L2
    func testNumbersAndSymbolsPages() {
        let numbers = rows(.numbers)
        XCTAssertEqual(labels(numbers[0]), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertEqual(labels(numbers[1]), ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])
        XCTAssertEqual(numbers[2].first?.action, .switchPage(.symbols))
        XCTAssertEqual(Array(labels(numbers[2]).dropFirst().dropLast()), [".", ",", "?", "!", "'"])
        XCTAssertEqual(numbers[2].last?.action, .backspace)

        let symbols = rows(.symbols)
        XCTAssertEqual(labels(symbols[0]), ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])
        XCTAssertEqual(labels(symbols[1]), ["_", "\\", "|", "~", "<", ">", "\u{20AC}", "\u{00A3}", "\u{00A5}", "\u{2022}"])
        XCTAssertEqual(symbols[2].first?.action, .switchPage(.numbers))
    }

    // L3
    func testBottomRowHasToggleGlobeRecordSpaceReturn() {
        let bottom = rows()[3]
        XCTAssertEqual(bottom.map(\.action), [
            .switchPage(.numbers), .globe, .record, .space, .returnKey
        ])
        XCTAssertEqual(bottom[0].label, "123")
        XCTAssertEqual(rows(.numbers)[3][0].action, .switchPage(.letters))
        XCTAssertEqual(rows(.numbers)[3][0].label, "ABC")
        XCTAssertEqual(rows(.symbols)[3][0].action, .switchPage(.letters))
    }

    func testTheGlobeKeyIsOmittedWhenTheSystemDrawsOne() {
        XCTAssertFalse(rows(globe: false)[3].contains { $0.action == .globe })
    }

    // L3b
    func testEmailAndUrlFieldsGetAtAndDotKeys() throws {
        for variant in [TypingKeyboardVariant.email, .url] {
            var traits = TypingTraits()
            traits.variant = variant
            let bottom = rows(traits: traits)[3]
            XCTAssertTrue(bottom.contains { $0.action == .character("@") }, "\(variant) needs @")
            XCTAssertTrue(bottom.contains { $0.action == .character(".") }, "\(variant) needs .")
            let space = try XCTUnwrap(bottom.firstIndex { $0.action == .space })
            let at = try XCTUnwrap(bottom.firstIndex { $0.action == .character("@") })
            XCTAssertLessThan(space, at, "extras sit right of space")
        }
        XCTAssertFalse(rows()[3].contains { $0.action == .character("@") })
    }

    // L4
    func testReturnKeyTitleAndStyleFollowTheReturnKeyType() throws {
        let expected: [(TypingReturnKey, String, Bool)] = [
            (.default, "return", false), (.go, "go", true), (.google, "search", true), (.join, "join", true),
            (.next, "next", true), (.route, "route", true), (.search, "search", true), (.send, "send", true),
            (.yahoo, "search", true), (.done, "done", true), (.emergencyCall, "emergency", true),
            (.continue, "continue", true),
        ]
        XCTAssertEqual(expected.count, TypingReturnKey.allCases.count, "every return key type has a row")
        for (kind, title, prominent) in expected {
            var traits = TypingTraits()
            traits.returnKey = kind
            let key = try XCTUnwrap(rows(traits: traits)[3].last)
            XCTAssertEqual(key.action, .returnKey)
            XCTAssertEqual(key.label, title, "\(kind)")
            XCTAssertEqual(key.isProminent, prominent, "\(kind)")
            XCTAssertEqual(kind.title, title)
        }
    }

    // L5
    func testNumericFieldsOpenOnTheNumbersPage() {
        var traits = TypingTraits()
        traits.variant = .numeric
        XCTAssertEqual(traits.initialPage, .numbers)
        XCTAssertEqual(TypingTraits().initialPage, .letters)
    }

    // L6
    func testSecureOrAutocorrectOffFieldsGetNoSuggestions() {
        var traits = TypingTraits()
        XCTAssertTrue(traits.allowsSuggestions)
        traits.isSecure = true
        XCTAssertFalse(traits.allowsSuggestions)
        traits = TypingTraits()
        traits.suggestionsDisabled = true
        XCTAssertFalse(traits.allowsSuggestions)
    }

    // L8
    func testKeyIdentifiersAreUniquePerPage() {
        for page in [TypingPage.letters, .numbers, .symbols] {
            let ids = rows(page).flatMap { $0 }.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(page) has duplicate key ids")
        }
    }

    func testEveryRowFillsTheSameWidth() {
        for page in [TypingPage.letters, .numbers, .symbols] {
            for (index, row) in rows(page).enumerated() {
                XCTAssertEqual(row.map(\.weight).reduce(0, +), TypingLayout.rowWeight, accuracy: 0.001, "\(page) row \(index)")
            }
        }
        var email = TypingTraits()
        email.variant = .email
        XCTAssertEqual(rows(traits: email)[3].map(\.weight).reduce(0, +), TypingLayout.rowWeight, accuracy: 0.001)
        XCTAssertEqual(rows(globe: false)[3].map(\.weight).reduce(0, +), TypingLayout.rowWeight, accuracy: 0.001)
    }

    // L7
    func testPreferredHeightIsTheSumOfItsParts() {
        let rows = Double(TypingMetrics.rowCount)
        let sum = TypingMetrics.topInset + TypingMetrics.stripHeight + TypingMetrics.stripGap
            + rows * TypingMetrics.keyHeight + (rows - 1) * TypingMetrics.rowSpacing + TypingMetrics.bottomInset
        XCTAssertEqual(TypingMetrics.preferredHeight, sum)
        XCTAssertEqual(TypingMetrics.stripHeight, 40)
        XCTAssertEqual(TypingMetrics.preferredHeight, 262)
    }
}

/// Matrix rows P1-P7: which page, strip content and record behaviour the controller state resolves to.
final class TypingPresentationTests: XCTestCase {
    private let suggestion = TypingSuggestion(text: "hello", kind: .completion)

    // P1/P2: the live status/preview takes the strip whenever a dictation is running.
    func testDictationStatusReplacesSuggestions() {
        XCTAssertEqual(
            TypingStripContent.resolve(isDictationActive: true, canUndoRewrite: false, suggestions: [suggestion]),
            .dictationStatus
        )
        XCTAssertEqual(
            TypingStripContent.resolve(isDictationActive: true, canUndoRewrite: true, suggestions: [suggestion]),
            .dictationStatus
        )
    }

    // P3
    func testIdleStripShowsSuggestions() {
        XCTAssertEqual(
            TypingStripContent.resolve(isDictationActive: false, canUndoRewrite: false, suggestions: [suggestion]),
            .suggestions([suggestion])
        )
    }

    // P4: the Undo edit button of a Quill rewrite must stay reachable on the Type page.
    func testUndoEditComesBeforeSuggestions() {
        XCTAssertEqual(
            TypingStripContent.resolve(isDictationActive: false, canUndoRewrite: true, suggestions: [suggestion]),
            .undoEdit
        )
    }

    // P5
    func testIdleStripWithNothingIsEmpty() {
        XCTAssertEqual(
            TypingStripContent.resolve(isDictationActive: false, canUndoRewrite: false, suggestions: []),
            .empty
        )
    }

    // P6: setup verification
    func testPendingVerificationForcesTheDictatePage() {
        XCTAssertEqual(
            TypingSurface.resolve(selected: .type, hasPendingSetupVerification: true, isDictationActive: false),
            .dictate
        )
        XCTAssertEqual(
            TypingSurface.resolve(selected: .type, hasPendingSetupVerification: true, isDictationActive: true),
            .type
        )
        XCTAssertEqual(
            TypingSurface.resolve(selected: .type, hasPendingSetupVerification: false, isDictationActive: false),
            .type
        )
        XCTAssertEqual(
            TypingSurface.resolve(selected: .dictate, hasPendingSetupVerification: false, isDictationActive: false),
            .dictate
        )
    }

    // P7: Record while the mic session is not running opens Muesli, like the Start pill.
    func testRecordOpensMuesliOnlyWhenTheMicSessionIsNotRunning() {
        XCTAssertEqual(TypingRecordKey.mode(opensMuesli: true, hasLaunchURL: true), .openMuesli)
        XCTAssertEqual(TypingRecordKey.mode(opensMuesli: true, hasLaunchURL: false), .action)
        XCTAssertEqual(TypingRecordKey.mode(opensMuesli: false, hasLaunchURL: true), .action)
    }
}
