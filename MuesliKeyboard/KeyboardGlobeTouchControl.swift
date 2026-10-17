import SwiftUI
import UIKit

/// The transparent touch surface over the globe key. SwiftUI buttons cannot hand UIKit the `UIEvent` that
/// `handleInputModeList(from:with:)` needs, so the globe's touches are taken here and routed by the controller:
/// the system tracks them (tap = next keyboard, long press = the list), or a plain tap advances.
@MainActor
final class KeyboardGlobeTouchControl: UIControl {
    private weak var controller: KeyboardController?

    init(controller: KeyboardController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Next keyboard"
        accessibilityIdentifier = "keyboard.globe"
        addTarget(self, action: #selector(touched(_:forEvent:)), for: .allTouchEvents)
        addAction(UIAction { [weak self] _ in self?.controller?.globeTapped() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func touched(_ sender: UIControl, forEvent event: UIEvent?) {
        controller?.globeTouchTracked(from: sender, with: event)
    }

    override func accessibilityActivate() -> Bool {
        controller?.switchInputMode()
        return true
    }
}

/// The overlay on a globe key's painted face. It takes the touches; the face underneath is not hit-tested.
struct KeyboardGlobeTouchOverlay: UIViewRepresentable {
    let controller: KeyboardController

    func makeUIView(context: Context) -> KeyboardGlobeTouchControl {
        KeyboardGlobeTouchControl(controller: controller)
    }

    func updateUIView(_ uiView: KeyboardGlobeTouchControl, context: Context) {}
}
