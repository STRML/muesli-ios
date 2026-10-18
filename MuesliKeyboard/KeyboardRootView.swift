import SwiftUI

struct KeyboardRootView: View {
    /// The one height of the keyboard, for the Type and the Dictate page alike (see `TypingMetrics`).
    static let preferredHeight = CGFloat(TypingMetrics.preferredHeight)
    /// How far the surface paints above `preferredHeight` when the host region is taller.
    static let surfaceOverscan: CGFloat = 32

    /// Three slots that never move: a side button, the primary pill, a side button. Only their content changes.
    private static let controlHeight: CGFloat = 64
    private static let sideButtonWidth: CGFloat = 64
    private static let statusBodyHeight: CGFloat = 40
    private static let dismissRowHeight: CGFloat = 14

    @Bindable var controller: KeyboardController

    var body: some View {
        Group {
            switch controller.surface {
            case .type:
                KeyboardTypePage(controller: controller)
                    .padding(.horizontal, MuesliTheme.spacing8 - KeyboardTypePage.sideBleed)
                    .padding(.top, CGFloat(TypingMetrics.topInset))
                    .padding(.bottom, CGFloat(TypingMetrics.bottomInset))
            case .dictate:
                dictatePage
                    .padding(.horizontal, MuesliTheme.spacing8)
                    .padding(.top, 4)
                    .padding(.bottom, 5)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.preferredHeight, alignment: .bottom)
        .transaction { transaction in
            if !controller.isLaunchSettled {
                transaction.animation = nil
            }
        }
        .background(alignment: .bottom) {
            // The surface reaches a little above the envelope, so a host region a few points taller than the
            // keyboard shows Muesli's color at its top edge and not iOS's own backdrop as a second gray band.
            LinearGradient(
                colors: [
                    MuesliTheme.backgroundRaised.opacity(0.98),
                    MuesliTheme.backgroundDeep.opacity(0.99)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.preferredHeight + Self.surfaceOverscan)
        }
        // iOS temporarily hosts third-party keyboards at full-screen and at
        // an intermediate height. Keep those extra host regions transparent;
        // only the final keyboard envelope (plus the small overscan above)
        // should paint Muesli's surface.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The original dictation panel: Start, Model and Quill, status, live preview and helper keys. It fills the
    /// shared height, so the helper keys take whatever the taller Type page leaves them.
    private var dictatePage: some View {
        VStack(spacing: 5) {
            keyboardDeck
            helperKeys
        }
    }

    private var isActive: Bool { controller.showsActiveWaveform }

    private var keyboardDeck: some View {
        VStack(spacing: 6) {
            if controller.hasPendingSetupVerification, !isActive {
                verifyRow
            } else {
                controlRow
                statusBody
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6 + Self.dismissRowHeight)
        .padding(.bottom, 8)
        .overlay(alignment: .topTrailing) { dismissRow }
        .muesliKeyboardDeckSurface()
        .animation(.snappy(duration: 0.22), value: isActive)
        .animation(.snappy(duration: 0.22), value: controller.primaryButtonRole)
    }

    /// Just the dismiss chevron, in the deck's top padding so it takes no row of its own.
    /// A drag handle here suggested the panel could be swiped down; it cannot.
    private var dismissRow: some View {
        HStack {
            Spacer()
            Button {
                controller.dismissKeyboard()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 44, height: Self.dismissRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss keyboard")
        }
        .frame(height: Self.dismissRowHeight)
    }

    // MARK: Control row

    private var controlRow: some View {
        HStack(spacing: 10) {
            Group {
                if isActive { cancelButton } else { modelButton }
            }
            .frame(width: Self.sideButtonWidth, height: Self.controlHeight)

            primaryPill

            Group {
                if isActive { fixIndicator } else { fixButton }
            }
            .frame(width: Self.sideButtonWidth, height: Self.controlHeight)
        }
        .frame(height: Self.controlHeight)
    }

    private func sideLabel(_ icon: String, _ title: String, tint: Color) -> some View {
        sideLabel(Image(systemName: icon).font(.system(size: 22, weight: .semibold)), title, tint: tint)
    }

    /// The Mac's Quill feather, so the key and the Mac's Quill look like the same feature.
    private func quillLabel(tint: Color) -> some View {
        sideLabel(
            Image("QuillIcon").resizable().scaledToFit().frame(width: 24, height: 24),
            "Quill",
            tint: tint
        )
    }

    private func sideLabel(_ icon: some View, _ title: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            icon
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint)
        .frame(width: Self.sideButtonWidth, height: Self.controlHeight)
        .keyboardGlassSurface()
    }

    private var modelButton: some View {
        transcriptionModelMenu {
            sideLabel("slider.horizontal.3", "Model", tint: MuesliTheme.textPrimary)
        }
    }

    /// Voice editing: say what to change and the selection, or the text just written, is rewritten.
    private var fixButton: some View {
        Button {
            controller.startRewrite()
        } label: {
            quillLabel(tint: controller.canRewrite ? MuesliTheme.accent : MuesliTheme.textTertiary)
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityLabel("Quill")
        .accessibilityHint("Say what to change in the selected text, or the text before the cursor")
        .accessibilityIdentifier("keyboard.quill")
    }

    /// Quill keeps its slot while listening so the row stays balanced and nothing moves. It only reports the mode:
    /// lit while the recording is an edit instruction, dim while it is plain dictation.
    private var fixIndicator: some View {
        let editing = controller.activeRewrite != nil
        return quillLabel(tint: editing ? Color.white : MuesliTheme.textTertiary)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(editing ? MuesliTheme.accent : Color.clear)
            )
            .opacity(editing ? 1 : 0.55)
            .allowsHitTesting(false)
            .accessibilityLabel(editing ? "Editing by voice" : "Quill unavailable while dictating")
    }

    /// In the slot Quill occupies, so a thumb that learned one layout finds the right control in the other.
    private var cancelButton: some View {
        Button(action: controller.cancelActiveDictation) {
            sideLabel("xmark", "Cancel", tint: MuesliTheme.textPrimary)
        }
        .buttonStyle(KeyboardPressStyle())
        .opacity(controller.canCancelActiveDictation ? 1 : 0.4)
        .disabled(!controller.canCancelActiveDictation)
        .accessibilityLabel("Cancel recording")
        .accessibilityIdentifier("keyboard.cancel")
    }

    private func modelMenuItem(_ model: KeyboardTranscriptionModelOption) -> some View {
        let isSelected = model.rawValue == controller.modelCatalog?.selectedRawValue
        let title = "\(model.displayName) · \(model.capabilityLabel)"
        return Button {
            controller.selectTranscriptionModel(model)
        } label: {
            Label(title, systemImage: isSelected ? "checkmark" : "circle")
        }
        .disabled(!controller.canSelectTranscriptionModel)
    }

    private func transcriptionModelMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Section("Transcription model") {
                ForEach(controller.readyTranscriptionModels) { model in
                    modelMenuItem(model)
                }
            }

            if let settingsURL = controller.settingsURL {
                Divider()
                Link(destination: settingsURL) {
                    Label("Manage downloaded models…", systemImage: "gearshape")
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Transcription model")
        .accessibilityValue(controller.modelChipTitle)
    }

    // MARK: Primary pill

    private var primaryPill: some View {
        KeyboardPrimaryActionControl(controller: controller) { pillLabel }
    }

    private var pillLabel: some View {
        pillContent
            .foregroundStyle(controller.isPrimaryButtonDisabled && !isActive ? MuesliTheme.textTertiary : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: Self.controlHeight)
            .keyboardPrimarySurface(muted: controller.isPrimaryButtonDisabled && !isActive)
    }

    @ViewBuilder
    private var pillContent: some View {
        if isActive {
            switch controller.dictationPhase {
            case .recording where controller.isConnectionLost:
                // No audio is arriving: say so, and make the pill the way back instead of a stop that does nothing.
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 22, weight: .semibold))
                    Text("Reconnect")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
                .accessibilityLabel(controller.readinessPresentation.accessibilityLabel)
            case .recording:
                // Listening is shown by the pill itself: the live level, not a label. Tap it to insert.
                MuesliInlineWaveformView(
                    mode: controller.waveformMode,
                    color: .white,
                    level: controller.waveformLevel,
                    style: .monochrome,
                    barCount: 24,
                    spacing: 3,
                    framesPerSecond: 30,
                    refreshDriver: .inputLevel
                )
                .frame(height: 30)
                .padding(.horizontal, 18)
                .accessibilityLabel("Listening. Tap to insert")
            default:
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(busyTitle)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }
        } else {
            HStack(spacing: 10) {
                KeyboardReadinessSymbol(controller: controller, size: 24)
                Text(primaryActionTitle)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }

    private var busyTitle: String {
        switch controller.dictationPhase {
        case .transcribing:
            controller.activeRewrite != nil ? "Rewriting…" : "Writing…"
        default:
            "Starting…"
        }
    }

    // MARK: Status body

    @ViewBuilder
    private var statusBody: some View {
        Group {
            if isActive {
                KeyboardDictationStatusView(controller: controller)
            } else if controller.canUndoRewrite {
                KeyboardUndoEditButton(controller: controller)
            } else if controller.readinessPresentation.needsAttention {
                KeyboardReadinessBadge(controller: controller)
            } else {
                readyCaption
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.statusBodyHeight)
    }

    private var readyCaption: some View {
        VStack(spacing: 3) {
            Text(controller.modelChipTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
            Text(controller.canRewrite
                 ? "Select text, then tap Quill to edit it by voice"
                 : "Set up a Custom LLM in Muesli to edit by voice")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
            if let banner = controller.remoteProcessingBanner {
                Text(banner)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .accessibilityIdentifier("keyboard.remoteProcessingBanner")
            }
        }
    }

    private var verifyRow: some View {
        VStack(spacing: 5) {
            Button(action: controller.verifyKeyboardSetup) {
                Label("Verify Muesli Keyboard", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(MuesliTheme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("keyboard.verifySetup")

            Text(controller.setupVerificationDetail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(height: Self.controlHeight + 8 + Self.statusBodyHeight)
    }

    private var helperKeys: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                KeyboardTextKey(".") { controller.insertTextKey(".") }
                KeyboardTextKey(",") { controller.insertTextKey(",") }
                KeyboardTextKey("?") { controller.insertTextKey("?") }
                KeyboardTextKey("!") { controller.insertTextKey("!") }
                KeyboardTextKey("'") { controller.insertTextKey("'") }
                KeyboardRepeatingTextKey(systemImage: "delete.left", accessibilityLabel: "Delete") {
                    controller.deleteBackward()
                }
            }

            HStack(spacing: 5) {
                if let settingsURL = controller.settingsURL {
                    Link(destination: settingsURL) {
                        KeyboardTextKeyLabel(systemImage: "gearshape.fill")
                    }
                    .buttonStyle(.plain)
                    .muesliKeyboardKeySurface()
                    .accessibilityLabel("Muesli settings")
                    .frame(maxWidth: 58)
                }

                if controller.typing.showsGlobe {
                    KeyboardTextKeyLabel(systemImage: "globe")
                        .muesliKeyboardKeySurface()
                        .overlay(KeyboardGlobeTouchOverlay(controller: controller))
                        .frame(maxWidth: 58)
                }

                // Minimal has no typing keyboard to go back to; the space key takes the width.
                if controller.layout.offersTypePage {
                    KeyboardTextKey("ABC") { controller.showTypePage() }
                        .frame(maxWidth: 66)
                        .accessibilityHint("Back to the typing keyboard")
                }

                KeyboardTextKey("space") { controller.insertSpace() }

                KeyboardTextKey("return") { controller.insertReturn() }
                    .frame(maxWidth: 96)

                KeyboardTextKey(":") { controller.insertTextKey(":") }
                    .frame(maxWidth: 58)
            }
        }
    }

    private var primaryActionTitle: String {
        switch controller.primaryButtonRole {
        case .record:
            "Start"
        case .stop:
            controller.statusText == "Stopping" ? "Stopping" : "Stop"
        case .openMuesliRequested:
            "Start"
        default:
            controller.primaryButtonTitle
        }
    }
}

/// Presses in slightly, like a physical key, instead of dimming.
struct KeyboardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// The primary action: a lit, slightly domed surface with a bright top edge and a coloured shadow.
private struct KeyboardPrimarySurface: ViewModifier {
    let muted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let fill = muted
            ? [MuesliTheme.surfacePrimary, MuesliTheme.surfacePrimary.opacity(0.8)]
            : [Color(hex: 0x7DB1FF), Color(hex: 0x4F83F5), Color(hex: 0x3D66DB)]
        content
            .background(shape.fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom)))
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(muted ? 0.10 : 0.30), Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                ))
                .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(muted ? 0.20 : 0.55), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: muted ? .clear : Color(hex: 0x3D66DB).opacity(0.38), radius: 14, x: 0, y: 8)
    }
}

/// Secondary controls: frosted glass with a hairline highlight, so the primary action is the only colour.
private struct KeyboardGlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(.thinMaterial))
            .background(shape.fill(Color.white.opacity(0.10)))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.50), Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
    }
}

extension View {
    func keyboardPrimarySurface(muted: Bool = false) -> some View {
        modifier(KeyboardPrimarySurface(muted: muted))
    }

    func keyboardGlassSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(KeyboardGlassSurface(cornerRadius: cornerRadius))
    }
}

private struct KeyboardIconKey: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeyboardIconLabel(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct KeyboardIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MuesliTheme.surfacePrimary.opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct KeyboardTextKey: View {
    let title: String?
    let systemImage: String?
    let accessibilityLabel: String?
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = nil
        self.accessibilityLabel = title
        self.action = action
    }

    init(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.title = nil
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            KeyboardTextKeyLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .muesliKeyboardKeySurface()
        .accessibilityLabel(accessibilityLabel ?? title ?? systemImage ?? "")
    }
}

private struct KeyboardRepeatingTextKey: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        KeyboardTextKeyLabel(title: nil, systemImage: systemImage)
            .muesliKeyboardKeySurface()
            .accessibilityLabel(accessibilityLabel)
            .holdToRepeat(action)
    }
}

private struct KeyboardTextKeyLabel: View {
    var title: String?
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 23, weight: .semibold))
            } else {
                Text(title ?? "")
                    .font(.system(size: textSize, weight: .medium))
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(MuesliTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 38, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var textSize: CGFloat {
        switch title {
        case "space", "return":
            15
        case "ABC":
            16
        default:
            22
        }
    }
}

private extension View {
    func muesliKeyboardDeckSurface() -> some View {
        modifier(MuesliKeyboardDeckSurfaceModifier())
    }

    func muesliKeyboardKeySurface(tint: Color? = nil) -> some View {
        modifier(MuesliKeyboardKeySurfaceModifier(tint: tint))
    }
}

private struct MuesliKeyboardDeckSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        content
            .background {
                shape.fill(.regularMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: Color(hex: 0x02060C).opacity(0.26), radius: 16, x: 0, y: 8)
    }
}

private struct MuesliKeyboardKeySurfaceModifier: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let keyTint = tint ?? Color.white

        content
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill(keyTint.opacity(tint == nil ? 0.035 : 0.10))
            }
            .overlay(shape.strokeBorder(keyTint.opacity(tint == nil ? 0.10 : 0.22), lineWidth: 1))
            .shadow(color: Color(hex: 0x02060C).opacity(0.28), radius: 4, x: 0, y: 2)
            .contentShape(shape)
    }
}

/// One line of what the streaming model has heard, newest words kept visible by truncating from the left. Gray and
/// display only. The final text lands after the final pass, either replacing the words typed live into the field
/// or inserted once when live typing is off or the host cannot take it, and this strip then clears.
struct KeyboardLivePreviewStrip: View {
    let preview: KeyboardLivePreview
    let recordingStartedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase: CGFloat = -1

    private var isFinalizing: Bool { preview.phase == .finalizing }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isFinalizing ? MuesliTheme.textTertiary : MuesliTheme.recording)
                .frame(width: 7, height: 7)
            if !isFinalizing {
                TimelineView(.periodic(from: recordingStartedAt ?? .now, by: 1)) { context in
                    Text(KeyboardLivePreview.elapsedLabel(from: recordingStartedAt, to: context.date))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
            Text(preview.text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isFinalizing ? 0.45 : 1)
                .overlay { if isFinalizing && !reduceMotion { shimmer } }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(MuesliTheme.textPrimary.opacity(0.07), in: Capsule())
        .animation(.easeOut(duration: 0.2), value: isFinalizing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinalizing ? "Finishing your text" : "Hearing: \(preview.text)")
        .accessibilityIdentifier("keyboard.livePreview")
    }

    private var shimmer: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.35), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.4)
            .offset(x: shimmerPhase * proxy.size.width)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { shimmerPhase = 1.2 }
            }
        }
        .allowsHitTesting(false)
        .mask(
            Text(preview.text)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}
