import Foundation

enum TypingPage: Sendable, Equatable {
    case letters
    case numbers
    case symbols
}

enum TypingKeyAction: Sendable, Equatable {
    /// Types exactly this text. Letter keys already carry the case they show.
    case character(String)
    case shift
    case backspace
    case space
    case returnKey
    case globe
    case record
    case switchPage(TypingPage)
    /// Empty width that indents a row (the middle letter row).
    case spacer
}

struct TypingKey: Sendable, Equatable, Identifiable {
    let id: String
    let action: TypingKeyAction
    let label: String
    /// Share of the row width. Every row's weights sum to `TypingLayout.rowWeight`.
    let weight: Double
    /// Painted in the accent colour (an action return key).
    let isProminent: Bool
    /// A character key painted like a function key, not a letter (the "@" and "." of an email or URL field).
    let isSpecial: Bool

    init(
        id: String, action: TypingKeyAction, label: String, weight: Double = 1,
        isProminent: Bool = false, isSpecial: Bool = false
    ) {
        self.id = id
        self.action = action
        self.label = label
        self.weight = weight
        self.isProminent = isProminent
        self.isSpecial = isSpecial
    }
}

enum TypingLayout {
    static let rowWeight = 10.0

    /// The letter keys, top row first. The one source for the key positions autocorrect measures distance by.
    static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let numberRows = ["1234567890", "-/:;()$&@\"", ""]
    private static let symbolRows = ["[]{}#%^*+=", "_\\|~<>\u{20AC}\u{00A3}\u{00A5}\u{2022}", ""]
    private static let punctuationRow = [".", ",", "?", "!", "'"]

    static func rows(
        page: TypingPage,
        uppercase: Bool,
        traits: TypingTraits,
        showsGlobe: Bool
    ) -> [[TypingKey]] {
        switch page {
        case .letters:
            [
                characters(letterRows[0], page: page, uppercase: uppercase),
                [spacer("l-lead")] + characters(letterRows[1], page: page, uppercase: uppercase) + [spacer("l-trail")],
                [TypingKey(id: "shift", action: .shift, label: "shift", weight: 1.5)]
                    + characters(letterRows[2], page: page, uppercase: uppercase)
                    + [backspace],
                bottomRow(page: page, traits: traits, showsGlobe: showsGlobe),
            ]
        case .numbers:
            [
                characters(numberRows[0], page: page, uppercase: false),
                characters(numberRows[1], page: page, uppercase: false),
                [TypingKey(id: "to-symbols", action: .switchPage(.symbols), label: "#+=", weight: 1.5)]
                    + punctuationKeys(page: page) + [backspace],
                bottomRow(page: page, traits: traits, showsGlobe: showsGlobe),
            ]
        case .symbols:
            [
                characters(symbolRows[0], page: page, uppercase: false),
                characters(symbolRows[1], page: page, uppercase: false),
                [TypingKey(id: "to-numbers", action: .switchPage(.numbers), label: "123", weight: 1.5)]
                    + punctuationKeys(page: page) + [backspace],
                bottomRow(page: page, traits: traits, showsGlobe: showsGlobe),
            ]
        }
    }

    private static var backspace: TypingKey {
        TypingKey(id: "backspace", action: .backspace, label: "delete", weight: 1.5)
    }

    private static func spacer(_ id: String) -> TypingKey {
        TypingKey(id: id, action: .spacer, label: "", weight: 0.5)
    }

    private static func characters(_ source: String, page: TypingPage, uppercase: Bool) -> [TypingKey] {
        source.map { character in
            let text = uppercase ? String(character).uppercased() : String(character)
            return TypingKey(id: "\(page)-\(character)", action: .character(text), label: text)
        }
    }

    private static func punctuationKeys(page: TypingPage) -> [TypingKey] {
        punctuationRow.map {
            TypingKey(id: "\(page)-\($0)", action: .character($0), label: $0, weight: 1.4)
        }
    }

    private static func bottomRow(page: TypingPage, traits: TypingTraits, showsGlobe: Bool) -> [TypingKey] {
        let toggle: TypingKey = page == .letters
            ? TypingKey(id: "to-numbers", action: .switchPage(.numbers), label: "123", weight: 1.3)
            : TypingKey(id: "to-letters", action: .switchPage(.letters), label: "ABC", weight: 1.3)
        var row = [toggle]
        if showsGlobe { row.append(TypingKey(id: "globe", action: .globe, label: "globe", weight: 1)) }
        row.append(TypingKey(id: "record", action: .record, label: "record", weight: 1.1))

        let extras = traits.variant == .email || traits.variant == .url ? ["@", "."] : []
        let returnKey = TypingKey(
            id: "return", action: .returnKey, label: traits.returnKey.title,
            weight: 1.9, isProminent: traits.returnKey.isProminent
        )
        let extraKeys = extras.map {
            TypingKey(id: "extra-\($0)", action: .character($0), label: $0, weight: 0.8, isSpecial: true)
        }
        let fixed = row.map(\.weight).reduce(0, +) + extraKeys.map(\.weight).reduce(0, +) + returnKey.weight
        let space = TypingKey(id: "space", action: .space, label: "space", weight: rowWeight - fixed)
        return row + [space] + extraKeys + [returnKey]
    }
}
