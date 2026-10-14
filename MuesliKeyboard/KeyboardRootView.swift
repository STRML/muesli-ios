import SwiftUI

struct KeyboardRootView: View {
    /// Room for the control row, a one-line status and two rows of keys.
    static let preferredHeight: CGFloat = 252

    /// Three slots that never move: a side button, the primary pill, a side button. Only their content changes.
    private static let controlHeight: CGFloat = 64
    private static let sideButtonWidth: CGFloat = 64
    private static let statusBodyHeight: CGFloat = 40
    private static let dismissRowHeight: CGFloat = 20

    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: 5) {
            keyboardDeck
            helperKeys
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.top, 4)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity)
        .frame(height: Self.preferredHeight, alignment: .bottom)
        .transaction { transaction in
            if !controller.isLaunchSettled {
                transaction.animation = nil
            }
        }
        .background(
            LinearGradient(
                colors: [
                    MuesliTheme.backgroundRaised.opacity(0.98),
                    MuesliTheme.backgroundDeep.opacity(0.99)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // iOS temporarily hosts third-party keyboards at full-screen and at
        // an intermediate height. Keep those extra host regions transparent;
        // only the final keyboard envelope should paint Muesli's surface.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var isActive: Bool { controller.showsActiveWaveform }

    private var keyboardDeck: some View {
        VStack(spacing: 6) {
            dismissRow

            if controller.hasPendingSetupVerification, !isActive {
                verifyRow
            } else {
                controlRow
                statusBody
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .muesliKeyboardDeckSurface()
        .animation(.snappy(duration: 0.22), value: isActive)
        .animation(.snappy(duration: 0.22), value: controller.primaryButtonRole)
    }

    /// Just the dismiss chevron. A drag handle here suggested the panel could be swiped down; it cannot.
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
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
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
            sideLabel(
                "wand.and.stars",
                "Fix",
                tint: controller.canRewrite ? MuesliTheme.accent : MuesliTheme.textTertiary
            )
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityLabel("Fix text")
        .accessibilityHint("Say what to change in the selected text, or the text before the cursor")
        .accessibilityIdentifier("keyboard.fix")
    }

    /// Fix keeps its slot while listening so the row stays balanced and nothing moves. It only reports the mode:
    /// lit while the recording is an edit instruction, dim while it is plain dictation.
    private var fixIndicator: some View {
        let editing = controller.activeRewrite != nil
        return sideLabel("wand.and.stars", "Fix", tint: editing ? Color.white : MuesliTheme.textTertiary)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(editing ? MuesliTheme.accent : Color.clear)
            )
            .opacity(editing ? 1 : 0.55)
            .allowsHitTesting(false)
            .accessibilityLabel(editing ? "Editing by voice" : "Fix unavailable while dictating")
    }

    /// In the slot Fix occupies, so a thumb that learned one layout finds the right control in the other.
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

    @ViewBuilder
    private var primaryPill: some View {
        if controller.opensMuesliFromPrimaryButton, let launchURL = controller.launchURL {
            Link(destination: launchURL) { pillLabel }
                .simultaneousGesture(TapGesture().onEnded {
                    controller.primaryLaunchAction()
                })
                .buttonStyle(KeyboardPressStyle())
                .allowsHitTesting(!controller.isPrimaryButtonDisabled)
        } else {
            Button {
                controller.primaryAction()
            } label: {
                pillLabel
            }
            .buttonStyle(KeyboardPressStyle())
            // A disabled button is auto-dimmed, which made a working pill look empty. Block taps instead.
            .allowsHitTesting(!controller.isPrimaryButtonDisabled)
        }
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
                Image(systemName: controller.primaryButtonIcon)
                    .font(.system(size: 24, weight: .semibold))
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
                if let edit = controller.activeRewrite, controller.dictationPhase != .transcribing {
                    editTarget(edit.original)
                } else {
                    caption(activeCaption)
                }
            } else if controller.canUndoRewrite {
                undoButton
            } else {
                readyCaption
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.statusBodyHeight)
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

    private var readyCaption: some View {
        VStack(spacing: 3) {
            Text(controller.modelChipTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
            Text(controller.canRewrite
                 ? "Select text, then tap Fix to edit it by voice"
                 : "Set up a Custom LLM in Muesli to edit by voice")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
    }

    private var undoButton: some View {
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

                KeyboardTextKey("ABC") { controller.switchInputMode() }
                    .frame(maxWidth: 66)

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
private struct KeyboardPressStyle: ButtonStyle {
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

private extension View {
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

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        KeyboardTextKeyLabel(title: nil, systemImage: systemImage)
            .muesliKeyboardKeySurface()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startRepeatingIfNeeded() }
                    .onEnded { _ in stopRepeating() }
            )
            .onDisappear {
                stopRepeating()
            }
    }

    private func startRepeatingIfNeeded() {
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

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
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
        .frame(minHeight: 38)
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
