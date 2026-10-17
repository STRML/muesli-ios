import SwiftUI

/// The large recording panel that fills the key area above the bottom row of the Full keyboard's Type page while a
/// dictation records or transcribes. While it records, the whole panel is one button: a tap anywhere stops and
/// saves, through the same controller entry point and guard as the strip pill and the Record key. While it
/// transcribes (or a stop or cancel is on its way) it shows the state and takes no taps.
struct KeyboardRecordingPanelView: View {
    let controller: KeyboardController
    let panel: TypingRecordingPanel

    private var isEdit: Bool { controller.activeRewrite != nil }

    var body: some View {
        if panel.isTappable {
            Button(action: controller.stopFromStatusPill) {
                content
            }
            .buttonStyle(KeyboardRecordingPanelStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(panel.accessibilityLabel(isEdit: isEdit))
            .accessibilityHint(panel.accessibilityHint(isEdit: isEdit) ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("keyboard.recordingPanel")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(panel.accessibilityLabel(isEdit: isEdit))
                .accessibilityIdentifier("keyboard.recordingPanel")
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            header
            meter
            heard
            Text(panel.caption(isEdit: isEdit))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(panel.isTappable ? Color.white : MuesliTheme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keyboardPrimarySurface(muted: !panel.isTappable)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var isLive: Bool { panel == .recording || panel == .stopping }

    /// The dot and the timer while the mic is live; nothing once it is not, so a stale clock is never shown.
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if isLive {
                Circle().fill(Color.white).frame(width: 8, height: 8)
                TimelineView(.periodic(from: controller.recordingStartedAt ?? .now, by: 1)) { context in
                    Text(KeyboardLivePreview.elapsedLabel(from: controller.recordingStartedAt, to: context.date))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
        }
        .frame(height: 18)
    }

    /// The live level while recording; a spinner once the mic is off, so a frozen meter never looks live.
    @ViewBuilder
    private var meter: some View {
        Group {
            if isLive {
                MuesliInlineWaveformView(
                    mode: controller.waveformMode,
                    color: .white,
                    level: controller.waveformLevel,
                    style: .monochrome,
                    barCount: 32,
                    spacing: 3,
                    framesPerSecond: 30,
                    refreshDriver: .inputLevel
                )
            } else {
                ProgressView().tint(MuesliTheme.textSecondary)
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }

    /// What the model has heard (newest words, from the left cut), or the text a voice edit will change. A fixed
    /// height, so a word arriving never moves the caption.
    @ViewBuilder
    private var heard: some View {
        Group {
            if let edit = controller.activeRewrite {
                Text(edit.original)
            } else if let preview = controller.recordingPanelPreview {
                Text(preview)
            } else {
                Color.clear
            }
        }
        .font(.system(size: 14, weight: .regular))
        .lineLimit(2)
        .truncationMode(.head)
        .multilineTextAlignment(.center)
        .opacity(panel == .recording ? 0.92 : 0.7)
        .frame(maxWidth: .infinity)
        .frame(height: 36, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// The panel's pressed state: a light wash over the whole panel and a small squeeze, so the press is felt.
private struct KeyboardRecordingPanelStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
