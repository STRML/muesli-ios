import SwiftUI

/// An uppercase label above a card, with an optional caption below it. The same style About and Diagnostics use.
struct SettingsGroup<Content: View>: View {
    let title: String
    let footer: String?
    let spacing: CGFloat
    let inset: CGFloat
    let content: Content

    init(
        title: String,
        footer: String? = nil,
        spacing: CGFloat = MuesliTheme.spacing12,
        inset: CGFloat = MuesliTheme.spacing16,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.spacing = spacing
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title.uppercased())
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textTertiary)
                .tracking(0.8)
                .padding(.leading, MuesliTheme.spacing4)

            MuesliSurface {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .padding(inset)
            }

            if let footer {
                Text(footer)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MuesliTheme.spacing4)
            }
        }
    }
}

struct SettingsSectionRow: View {
    let section: SettingsSection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(section.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(section.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, MuesliTheme.spacing4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, MuesliTheme.spacing4)
            .padding(.vertical, MuesliTheme.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    var iconColor = MuesliTheme.accent
    var valueColor = MuesliTheme.textTertiary

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Text(value)
                .font(MuesliTheme.callout())
                .foregroundStyle(valueColor)
        }
    }
}

/// A row with an icon, a title, a detail line and one control (a switch or a menu). VoiceOver reads it as one
/// element: title and detail as its label, the control's own value after. At accessibility Dynamic Type sizes
/// the text takes the full width and the control sits below it.
struct SettingsAccessoryRow<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    let accessory: Accessory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(icon: String, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        layout
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    iconView
                    textColumn
                }
                spokenAccessory
            }
        } else {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                iconView
                textColumn
                Spacer(minLength: MuesliTheme.spacing12)
                spokenAccessory
            }
        }
    }

    private var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(MuesliTheme.accent)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    /// Seen text only: the spoken label sits on the control, so the combined element does not repeat it.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text(title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .accessibilityHidden(true)
            if !detail.isEmpty {
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    private var spokenAccessory: some View {
        accessory.accessibilityLabel(SettingsAccessibility.label(title: title, detail: detail))
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsAccessoryRow(icon: icon, title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(MuesliTheme.accent)
        }
    }
}

struct SettingsTextFieldRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(MuesliTheme.body())
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
    }
}

struct SettingsModelPickerRow: View {
    let icon: String
    let title: String
    @Binding var selection: String
    let presets: [SummaryModelPreset]
    var preserveCustomValue = true
    var fallbackSelection: String?

    var menuPresets: [SummaryModelPreset] {
        SummaryModelPreset.menuPresets(
            presets,
            currentModel: selection,
            preserveCustomValue: preserveCustomValue
        )
    }

    var normalizedSelection: String {
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if presets.contains(where: { $0.id == trimmedSelection }) {
            return trimmedSelection
        }
        if preserveCustomValue, !trimmedSelection.isEmpty {
            return trimmedSelection
        }
        return fallbackSelection ?? presets.first?.id ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Picker(title, selection: $selection) {
                ForEach(menuPresets) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .font(MuesliTheme.body())
            .tint(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 42)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    func normalizeSelectionIfNeeded() {
        let validSelection = normalizedSelection
        guard selection != validSelection else { return }
        selection = validSelection
    }
}
