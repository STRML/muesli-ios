import SwiftUI

struct AppearanceSettingsContent: View {
    @AppStorage(MuesliPreferences.appearanceModeKey) private var appearanceMode = MuesliAppearanceMode.system.rawValue
    @AppStorage(MuesliPreferences.accentThemeKey) private var accentTheme = MuesliAccentTheme.blue.rawValue

    var selectedAppearanceMode: MuesliAppearanceMode {
        MuesliAppearanceMode(rawValue: appearanceMode) ?? .system
    }

    var selectedAccentTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(rawValue: accentTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    SettingsAppearanceModePicker(selection: $appearanceMode)
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsAccentThemePicker(selection: $accentTheme)
                }
                .padding(MuesliTheme.spacing16)
            }

            MuesliSurface {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    Text("Preview")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    appearancePreviewSurface
                }
                .padding(MuesliTheme.spacing16)
            }
        }
    }

    var appearancePreviewSurface: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                MuesliTheme.accent
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))

                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(selectedAccentTheme.label)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("\(selectedAppearanceMode.label) appearance")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: MuesliTheme.spacing8) {
                previewMetric("3", "streak", tint: Color(hex: 0xFF9F2D))
                previewMetric("152", "WPM", tint: MuesliTheme.success)
                previewRecorderButton
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    func previewMetric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MuesliTheme.headline())
                .monospacedDigit()
                .foregroundStyle(MuesliTheme.textPrimary)
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
    }

    var previewRecorderButton: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityHidden(true)
            Text("Record")
                .font(MuesliTheme.captionMedium())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(MuesliTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
    }
}

struct SettingsAppearanceModePicker: View {
    @Binding var selection: String

    var selectedMode: MuesliAppearanceMode {
        MuesliAppearanceMode(rawValue: selection) ?? .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Color Scheme")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Currently \(selectedMode.label.lowercased()).")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            Picker("Color Scheme", selection: $selection) {
                ForEach(MuesliAppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    func normalizeSelectionIfNeeded() {
        guard MuesliAppearanceMode(rawValue: selection) == nil else { return }
        selection = MuesliAppearanceMode.system.rawValue
    }
}

struct SettingsAccentThemePicker: View {
    @Binding var selection: String

    var selectedTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(rawValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Accent")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(selectedTheme.label)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                ForEach(MuesliAccentTheme.allCases) { theme in
                    Button {
                        selection = theme.rawValue
                    } label: {
                        MuesliTheme.color(for: theme)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        selectedTheme == theme ? MuesliTheme.textPrimary : MuesliTheme.surfaceBorder,
                                        lineWidth: selectedTheme == theme ? 2 : 1
                                    )
                            }
                            .overlay {
                                if selectedTheme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.label) accent")
                }
            }
        }
        .onAppear(perform: normalizeSelectionIfNeeded)
        .onChange(of: selection) { _, _ in
            normalizeSelectionIfNeeded()
        }
    }

    func normalizeSelectionIfNeeded() {
        let resolved = MuesliAccentTheme.resolved(rawValue: selection)
        guard selection != resolved.rawValue else { return }
        selection = resolved.rawValue
    }
}
