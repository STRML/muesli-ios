import Foundation

struct KeyboardTypingSettings: Codable, Sendable, Equatable {
    var autocorrect: Bool
    static let `default` = KeyboardTypingSettings(autocorrect: true)
}
