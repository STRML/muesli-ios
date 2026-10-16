import Foundation

// The host field's text-input traits, mirrored as plain enums so the typing logic builds and tests on a Mac.
// MuesliKeyboard/TypingTraitsMapping.swift maps UITextInputTraits onto these.

enum TypingAutocapitalization: Sendable, Equatable {
    case none
    case words
    case sentences
    case allCharacters
}

enum TypingReturnKey: Sendable, Equatable, CaseIterable {
    case `default`, go, google, join, next, route, search, send, yahoo, done, emergencyCall, `continue`

    var title: String {
        switch self {
        case .default: "return"
        case .go: "go"
        case .google, .search, .yahoo: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "emergency"
        case .continue: "continue"
        }
    }

    /// Every label except plain "return" is an action, and the system keyboard paints those in the accent colour.
    var isProminent: Bool { self != .default }
}

enum TypingKeyboardVariant: Sendable, Equatable {
    case standard
    case email
    case url
    /// Number pad, phone pad, decimal pad, numbers and punctuation: opens on the numbers page.
    case numeric
}

enum TypingAppearance: Sendable, Equatable {
    case unspecified
    case light
    case dark
}

struct TypingTraits: Sendable, Equatable {
    var autocapitalization: TypingAutocapitalization = .sentences
    var returnKey: TypingReturnKey = .default
    var variant: TypingKeyboardVariant = .standard
    var appearance: TypingAppearance = .unspecified
    var isSecure = false
    var enablesReturnKeyAutomatically = false
    /// The field asked for no autocorrection or spell checking.
    var suggestionsDisabled = false

    /// Secure fields never have their text read. iOS forces the system keyboard for them, so this only guards
    /// a late trait update.
    var allowsSuggestions: Bool { !isSecure && !suggestionsDisabled }

    var initialPage: TypingPage { variant == .numeric ? .numbers : .letters }
}
