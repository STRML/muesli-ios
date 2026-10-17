import SwiftUI

/// The typing page: the strip on top (suggestions, or the dictation status while one runs, with the panel key and
/// Quill at its ends) and four rows of keys. Everything it shows about dictation is read from the controller.
struct KeyboardTypePage: View {
    /// The keys' tap areas run to the screen edge; their painted faces are inset by `KeyboardTypeKey.faceInset`.
    static let sideBleed: CGFloat = 5

    @Bindable var controller: KeyboardController

    private var typing: KeyboardTypingModel { controller.typing }
    private var isActive: Bool { controller.showsActiveWaveform }

    var body: some View {
        VStack(spacing: CGFloat(TypingMetrics.stripGap)) {
            strip
                .frame(height: CGFloat(TypingMetrics.stripHeight))
                .padding(.horizontal, Self.sideBleed)
            keyRows
        }
    }

    // MARK: Strip

    private var strip: some View {
        HStack(spacing: 6) {
            leadingSlot
                .frame(width: 40, height: CGFloat(TypingMetrics.stripHeight))
            stripContent
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(TypingMetrics.stripHeight))
                .clipped()
            trailingSlot
                .frame(width: 40, height: CGFloat(TypingMetrics.stripHeight))
        }
    }

    /// Cancel while a dictation runs (the slot Cancel has on the Dictate page), otherwise the way to that page.
    @ViewBuilder
    private var leadingSlot: some View {
        if isActive {
            Button(action: controller.cancelActiveDictation) {
                stripGlyph(Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)), tint: MuesliTheme.textPrimary)
            }
            .buttonStyle(KeyboardPressStyle())
            .opacity(controller.canCancelActiveDictation ? 1 : 0.4)
            .disabled(!controller.canCancelActiveDictation)
            .accessibilityLabel("Cancel recording")
            .accessibilityIdentifier("keyboard.cancel")
        } else {
            Button {
                controller.selectedSurface = .dictate
            } label: {
                stripGlyph(Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .semibold)), tint: MuesliTheme.textPrimary)
            }
            .buttonStyle(KeyboardPressStyle())
            .accessibilityLabel("Dictation panel")
            .accessibilityHint("Model, status and dictation helpers")
            .accessibilityIdentifier("keyboard.dictatePanel")
        }
    }

    /// Quill. While a dictation runs it only reports the mode, as it does on the Dictate page.
    @ViewBuilder
    private var trailingSlot: some View {
        if isActive {
            let editing = controller.activeRewrite != nil
            stripGlyph(quillImage, tint: editing ? .white : MuesliTheme.textTertiary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(editing ? MuesliTheme.accent : Color.clear)
                )
                .opacity(editing ? 1 : 0.55)
                .allowsHitTesting(false)
                .accessibilityLabel(editing ? "Editing by voice" : "Quill unavailable while dictating")
        } else {
            Button {
                controller.startRewrite()
            } label: {
                stripGlyph(quillImage, tint: controller.canRewrite ? MuesliTheme.accent : MuesliTheme.textTertiary)
            }
            .buttonStyle(KeyboardPressStyle())
            .accessibilityLabel("Quill")
            .accessibilityHint("Say what to change in the selected text, or the text before the cursor")
            .accessibilityIdentifier("keyboard.quill")
        }
    }

    private var quillImage: some View {
        Image("QuillIcon").resizable().scaledToFit().frame(width: 22, height: 22)
    }

    private func stripGlyph(_ glyph: some View, tint: Color) -> some View {
        glyph
            .foregroundStyle(tint)
            .frame(width: 40, height: CGFloat(TypingMetrics.stripHeight))
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stripContent: some View {
        switch TypingStripContent.resolve(
            isDictationActive: isActive,
            canUndoRewrite: controller.canUndoRewrite,
            suggestions: typing.state.suggestions
        ) {
        case .dictationStatus:
            KeyboardDictationStatusView(controller: controller)
        case .undoEdit:
            KeyboardUndoEditButton(controller: controller)
        case .suggestions(let suggestions):
            KeyboardSuggestionStrip(suggestions: suggestions) { typing.accept($0) }
        case .empty:
            Color.clear
        }
    }

    // MARK: Keys

    private var keyRows: some View {
        let state = typing.state
        let rows = TypingLayout.rows(
            page: state.page,
            uppercase: state.isUppercase,
            traits: state.traits,
            showsGlobe: typing.showsGlobe
        )
        let rowHeight = CGFloat(TypingMetrics.keyHeight + TypingMetrics.rowSpacing)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                TypingKeyRow(keys: row) { key in
                    KeyboardTypeKey(key: key, controller: controller)
                }
                .frame(height: rowHeight)
            }
        }
        // Each row is a full row plus a gap tall so no tap lands between keys; the first and last overhang the
        // strip gap and bottom inset by half a gap.
        .frame(height: CGFloat(TypingMetrics.rowCount) * CGFloat(TypingMetrics.keyHeight)
               + CGFloat(TypingMetrics.rowCount - 1) * CGFloat(TypingMetrics.rowSpacing))
    }
}

// MARK: Suggestion strip

struct KeyboardSuggestionStrip: View {
    let suggestions: [TypingSuggestion]
    let onTap: (TypingSuggestion) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 {
                    Rectangle()
                        .fill(MuesliTheme.surfaceBorder)
                        .frame(width: 1, height: 22)
                }
                Button {
                    onTap(suggestion)
                } label: {
                    Text(display(suggestion))
                        .font(.system(size: 17, weight: suggestion.kind == .verbatim ? .regular : .medium))
                        .foregroundStyle(suggestion.kind == .verbatim ? MuesliTheme.textSecondary : MuesliTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(suggestion.text)
                .accessibilityIdentifier("keyboard.suggestion.\(index)")
            }
        }
    }

    /// The word as typed is shown in quotes, the way the system strip marks it.
    private func display(_ suggestion: TypingSuggestion) -> String {
        suggestion.kind == .verbatim ? "\u{201C}\(suggestion.text)\u{201D}" : suggestion.text
    }
}

// MARK: Keys

/// Lays a row's keys out in proportion to their weights.
private struct TypingKeyRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let total = subviews.reduce(0) { $0 + $1[TypingKeyWeight.self] }
        guard total > 0 else { return }
        var x = bounds.minX
        for subview in subviews {
            let width = bounds.width * subview[TypingKeyWeight.self] / total
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}

private struct TypingKeyWeight: LayoutValueKey {
    static let defaultValue: Double = 1
}

private struct TypingKeyRow<Content: View>: View {
    let keys: [TypingKey]
    @ViewBuilder let content: (TypingKey) -> Content

    var body: some View {
        TypingKeyRowLayout {
            ForEach(keys) { key in
                content(key).layoutValue(key: TypingKeyWeight.self, value: key.weight)
            }
        }
    }
}

private enum TypingKeyPalette {
    static let letterFill = Color.adaptive(dark: 0x3A3F4A, light: 0xFFFFFF)
    static let specialFill = Color.adaptive(dark: 0x23272F, light: 0xD3DAE6)
    static let faceShadow = Color.adaptiveAlpha(dark: .black, darkAlpha: 0.45, light: .black, lightAlpha: 0.22)
}

private struct TypingKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? -0.08 : 0)
    }
}

private struct KeyboardTypeKey: View {
    static let faceInset: CGFloat = 3

    let key: TypingKey
    let controller: KeyboardController

    private var typing: KeyboardTypingModel { controller.typing }

    var body: some View {
        switch key.action {
        case .spacer:
            Color.clear
        case .record:
            KeyboardPrimaryActionControl(controller: controller) { face(recordFace, fill: MuesliTheme.accent) }
                .accessibilityLabel(recordLabel)
                .accessibilityIdentifier("keyboard.record")
        case .backspace:
            face(Image(systemName: "delete.left").font(.system(size: 19, weight: .medium)), fill: TypingKeyPalette.specialFill)
                .holdToRepeat { typing.perform(.backspace) }
                .accessibilityLabel("Delete")
        case .globe:
            button(fill: TypingKeyPalette.specialFill) { controller.switchInputMode() } label: {
                Image(systemName: "globe").font(.system(size: 19, weight: .medium))
            }
            .accessibilityLabel("Next keyboard")
            .accessibilityIdentifier("keyboard.globe")
        case .shift:
            button(fill: typing.state.shift == .off ? TypingKeyPalette.specialFill : TypingKeyPalette.letterFill) {
                typing.perform(.shift)
            } label: {
                Image(systemName: shiftSymbol).font(.system(size: 19, weight: .medium))
            }
            .accessibilityLabel("Shift")
            .accessibilityValue(shiftValue)
        case .space:
            button(fill: TypingKeyPalette.letterFill) { typing.perform(.space) } label: {
                Text("space").font(.system(size: 16))
            }
            .accessibilityLabel("Space")
        case .returnKey:
            let enabled = typing.state.isReturnEnabled
            button(fill: key.isProminent ? MuesliTheme.accent : TypingKeyPalette.specialFill) {
                typing.perform(.returnKey)
            } label: {
                Text(key.label).font(.system(size: 16, weight: key.isProminent ? .semibold : .regular))
            }
            .foregroundStyle(key.isProminent ? Color.white : MuesliTheme.textPrimary)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(key.label)
        case .switchPage:
            button(fill: TypingKeyPalette.specialFill) { typing.perform(key.action) } label: {
                Text(key.label).font(.system(size: 16))
            }
            .accessibilityLabel(key.label)
        case .character(let text):
            button(fill: isSpecialCharacter ? TypingKeyPalette.specialFill : TypingKeyPalette.letterFill) {
                typing.perform(.character(text))
            } label: {
                Text(key.label).font(.system(size: 22))
            }
            .accessibilityLabel(text)
        }
    }

    private var isSpecialCharacter: Bool { key.id.hasPrefix("extra-") }

    private func button<Label: View>(
        fill: Color,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            face(label(), fill: fill)
        }
        .buttonStyle(TypingKeyPressStyle())
    }

    /// The painted key, inset inside its tap area.
    private func face(_ content: some View, fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(fill))
            .shadow(color: TypingKeyPalette.faceShadow, radius: 0, x: 0, y: 1)
            .padding(.horizontal, Self.faceInset)
            .padding(.vertical, CGFloat(TypingMetrics.rowSpacing) / 2)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var recordFace: some View {
        if controller.dictationPhase == .transcribing {
            ProgressView().tint(.white)
        } else {
            Image(systemName: controller.primaryButtonIcon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var recordLabel: String {
        controller.showsActiveWaveform ? "Stop dictation" : "Record"
    }

    private var shiftSymbol: String {
        switch typing.state.shift {
        case .off: "shift"
        case .once: "shift.fill"
        case .locked: "capslock.fill"
        }
    }

    private var shiftValue: String {
        switch typing.state.shift {
        case .off: "off"
        case .once: "on for the next letter"
        case .locked: "caps lock"
        }
    }
}
