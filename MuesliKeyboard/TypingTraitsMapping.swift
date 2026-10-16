import UIKit

/// The host field's traits, as the typing logic sees them. Every property on `UITextInputTraits` is optional, so a
/// host that sets nothing gets the plain defaults.
extension TypingTraits {
    init(_ traits: UITextInputTraits) {
        self.init()
        autocapitalization = Self.autocapitalization(traits.autocapitalizationType)
        returnKey = Self.returnKey(traits.returnKeyType)
        variant = Self.variant(traits.keyboardType)
        appearance = Self.appearance(traits.keyboardAppearance)
        isSecure = traits.isSecureTextEntry ?? false
        enablesReturnKeyAutomatically = traits.enablesReturnKeyAutomatically ?? false
        suggestionsDisabled = traits.autocorrectionType == .no || traits.spellCheckingType == .no
    }

    static func autocapitalization(_ type: UITextAutocapitalizationType?) -> TypingAutocapitalization {
        switch type {
        case .some(.none): .none
        case .some(.words): .words
        case .some(.allCharacters): .allCharacters
        default: .sentences
        }
    }

    static func returnKey(_ type: UIReturnKeyType?) -> TypingReturnKey {
        switch type {
        case .go: .go
        case .google: .google
        case .join: .join
        case .next: .next
        case .route: .route
        case .search: .search
        case .send: .send
        case .yahoo: .yahoo
        case .done: .done
        case .emergencyCall: .emergencyCall
        case .continue: .continue
        default: .default
        }
    }

    static func variant(_ type: UIKeyboardType?) -> TypingKeyboardVariant {
        switch type {
        case .emailAddress: .email
        case .URL, .webSearch: .url
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .namePhonePad, .asciiCapableNumberPad: .numeric
        default: .standard
        }
    }

    static func appearance(_ appearance: UIKeyboardAppearance?) -> TypingAppearance {
        switch appearance {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
    }
}
