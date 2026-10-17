import SwiftUI

/// Pieces of the dictation panel that the Type page reuses, so the two pages cannot drift apart.

/// The Start / Stop control. It opens Muesli through its URL when the mic session is not running and acts in
/// place when it is: the Dictate page's pill and the Type page's Record key are both this.
struct KeyboardPrimaryActionControl<Label: View>: View {
    let controller: KeyboardController
    /// True while a press has already acted as something else (the Record key's hold), so its release is no tap.
    var isTapSuppressed: () -> Bool = { false }
    @ViewBuilder let label: () -> Label

    var body: some View {
        if controller.recordKeyMode == .openMuesli, let launchURL = controller.launchURL {
            Link(destination: launchURL) { label() }
                .simultaneousGesture(TapGesture().onEnded {
                    guard !isTapSuppressed() else { return }
                    controller.primaryLaunchAction()
                })
                .buttonStyle(KeyboardPressStyle())
                .allowsHitTesting(!controller.isPrimaryButtonDisabled)
        } else {
            Button {
                guard !isTapSuppressed() else { return }
                controller.primaryAction()
            } label: {
                label()
            }
            .buttonStyle(KeyboardPressStyle())
            // A disabled button is auto-dimmed, which made a working pill look empty. Block taps instead.
            .allowsHitTesting(!controller.isPrimaryButtonDisabled)
        }
    }
}

/// What a running dictation shows in its one status slot: the text a voice edit will change, the live preview,
/// or a caption. The Dictate page's status line and the Type page's strip both show this.
struct KeyboardDictationStatusView: View {
    let controller: KeyboardController

    var body: some View {
        if controller.canStopFromStatusPill {
            stopPill
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let edit = controller.activeRewrite, controller.dictationPhase != .transcribing {
            editTarget(edit.original)
        } else if let preview = controller.livePreview {
            KeyboardLivePreviewStrip(preview: preview, recordingStartedAt: controller.recordingStartedAt)
        } else {
            caption(activeCaption)
        }
    }

    /// While recording the whole pill is the stop key: a tap anywhere on it stops and saves, with a tap area a
    /// full 44 pt tall that reaches a little past the 40 pt strip.
    private var stopPill: some View {
        Button(action: controller.stopFromStatusPill) {
            content
                .frame(maxWidth: .infinity, minHeight: CGFloat(TypingStripPill.minimumHitHeight))
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardStopPillStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stop and save dictation")
        .accessibilityHint("Stops recording and inserts the text")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("keyboard.stopPill")
    }

    /// The text a voice edit will change, highlighted the way a selection is, with what to do next.
    private func editTarget(_ original: String) -> some View {
        VStack(spacing: 4) {
            Text(original)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MuesliTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Speak to edit · tap the pill when you're done")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MuesliTheme.textSecondary)
            .multilineTextAlignment(.center)
    }

    private var activeCaption: String {
        switch controller.dictationPhase {
        case .recording:
            "Listening · tap the pill to insert"
        case .transcribing:
            controller.activeRewrite != nil ? "Applying your edit" : "Writing your text"
        default:
            "Starting"
        }
    }
}

/// The pill's pressed state: a light wash over it and a small squeeze.
private struct KeyboardStopPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Capsule()
                    .fill(MuesliTheme.textPrimary.opacity(configuration.isPressed ? 0.12 : 0))
                    .frame(height: 28)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

struct KeyboardUndoEditButton: View {
    let controller: KeyboardController

    var body: some View {
        Button(action: controller.undoLastRewrite) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                Text("Undo edit")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .keyboardGlassSurface(cornerRadius: 19)
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityIdentifier("keyboard.undo")
    }
}

/// Backspace-style repeat: acts on touch down, then again after a pause and at a steady rate until release.
private struct HoldToRepeat: ViewModifier {
    let action: () -> Void
    @State private var repeatTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in start() }
                    .onEnded { _ in stop() }
            )
            .onDisappear { stop() }
    }

    private func start() {
        guard repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(65))
            }
        }
    }

    private func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

extension View {
    func holdToRepeat(_ action: @escaping () -> Void) -> some View {
        modifier(HoldToRepeat(action: action))
    }
}
