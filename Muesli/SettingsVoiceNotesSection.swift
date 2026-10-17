import SwiftUI

extension SettingsView {
    var voiceNoteSettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsMicrophonePicker(selection: $microphonePreference)
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "waveform.circle",
                    title: "Save Voice Note Audio",
                    detail: "Keep original voice note audio locally on this iPhone for playback and troubleshooting. Audio does not sync.",
                    isOn: $keepDictationAudioRecordings
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                LongVoiceNoteSettingsRow(
                    isEnabled: $longVoiceNoteModeEnabled,
                    thresholdSeconds: $longVoiceNoteThresholdSeconds
                )
                if #available(iOS 18.0, *), ActionButtonHardware.isSupported {
                    Divider().overlay(MuesliTheme.surfaceBorder)
                    SettingsNavigationRow(
                        icon: "button.programmable",
                        title: "Action Button",
                        detail: "Set up or reconfigure dictation and meeting-note shortcuts."
                    ) {
                        isActionButtonOnboardingPresented = true
                        AppTelemetry.signal("action_button_settings_opened")
                    }
                }
            }
            .padding(MuesliTheme.spacing16)
        }
    }
}

struct LongVoiceNoteSettingsRow: View {
    @Binding var isEnabled: Bool
    @Binding var thresholdSeconds: Int
    @State private var customText = ""
    @FocusState private var isCustomFieldFocused: Bool

    private let commonValues = [30, 60, 90, 120]

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            SettingsToggleRow(
                icon: "waveform.path.ecg",
                title: "Long Voice Note Mode",
                detail: "Open Long Voice Note after longer recordings.",
                isOn: $isEnabled
            )

            if isEnabled {
                HStack(spacing: MuesliTheme.spacing12) {
                    Text("Switch after")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)

                    Spacer()

                    Menu {
                        ForEach(commonValues, id: \.self) { value in
                            Button(MuesliPreferences.longVoiceNoteThresholdLabel(value)) {
                                thresholdSeconds = value
                                customText = String(value)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(MuesliPreferences.longVoiceNoteThresholdLabel(thresholdSeconds))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(minHeight: 44)
                    }
                }

                HStack(spacing: MuesliTheme.spacing8) {
                    TextField("Seconds", text: $customText)
                        .keyboardType(.numberPad)
                        .focused($isCustomFieldFocused)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .frame(height: 44)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                        .onSubmit(commitCustomValue)

                    Stepper("Threshold seconds", value: $thresholdSeconds, in: 30...600, step: 5)
                        .labelsHidden()
                }

                Text("30 seconds to 10 minutes")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .onAppear {
            thresholdSeconds = MuesliPreferences.clampedLongVoiceNoteThreshold(thresholdSeconds)
            customText = String(thresholdSeconds)
        }
        .onChange(of: thresholdSeconds) { _, value in
            let clamped = MuesliPreferences.clampedLongVoiceNoteThreshold(value)
            if thresholdSeconds != clamped {
                thresholdSeconds = clamped
                return
            }
            customText = String(clamped)
            signalThresholdChanged(clamped)
        }
        .onChange(of: isEnabled) { _, enabled in
            AppTelemetry.signal(
                "long_voice_note_mode_toggled",
                parameters: ["enabled": enabled ? "true" : "false"]
            )
        }
        .onChange(of: customText) { _, value in
            guard value.count > 4 else { return }
            customText = String(value.prefix(4))
        }
        .onChange(of: isCustomFieldFocused) { _, focused in
            if !focused {
                commitCustomValue()
            }
        }
    }

    func commitCustomValue() {
        let value = Int(customText) ?? thresholdSeconds
        thresholdSeconds = MuesliPreferences.clampedLongVoiceNoteThreshold(value)
        customText = String(thresholdSeconds)
    }

    func signalThresholdChanged(_ seconds: Int) {
        AppTelemetry.signal(
            "long_voice_note_threshold_changed",
            parameters: ["threshold_bucket": MuesliPreferences.longVoiceNoteThresholdLabel(seconds)]
        )
    }
}

struct SettingsMicrophonePicker: View {
    @Binding var selection: String

    var availableOptions: [RecordingMicrophonePreference] {
        let options = AudioInputRouteManager.availablePreferenceOptions()
        guard !options.contains(preference) else { return options }
        return options + [preference]
    }

    var preference: RecordingMicrophonePreference {
        RecordingMicrophonePreference(rawValue: selection) ?? .automatic
    }

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Microphone")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(preference.detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Picker("Microphone", selection: $selection) {
                ForEach(availableOptions) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(MuesliTheme.accent)
        }
    }
}
