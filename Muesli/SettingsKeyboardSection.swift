import SwiftUI

extension SettingsView {
    var keyboardSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            SettingsGroup(title: "Status") {
                SettingsRow(icon: "keyboard", title: "Keyboard Extension", value: keyboardSetupStatus.label)
                Divider().overlay(MuesliTheme.surfaceBorder)
                Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                    HStack {
                        Text("Open Muesli Settings")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(minHeight: SettingsAccessibility.minimumTapTarget)
                    .contentShape(Rectangle())
                }
            }

            SettingsGroup(title: "iOS dictation mic") {
                Text("iOS draws its own mic under the keyboard. Tapping it while Muesli dictates runs two dictations at once and leaves both stuck until the keyboard closes. To remove it, open the iOS Settings app, go to General > Keyboard and turn off Enable Dictation. That also removes the mic from every other keyboard.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.systemDictationNote")
            }

            SettingsGroup(
                title: "Layout and typing",
                footer: "Autocorrect and live typing apply at once with Allow Full Access. The layout applies the next time the keyboard opens."
            ) {
                SettingsKeyboardLayoutRow(selection: keyboardLayoutBinding)
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "textformat.abc",
                    title: "Autocorrect",
                    detail: "Fix typos when you type a space or punctuation on the full Muesli keyboard. Backspace right after a fix puts your word back. Needs Allow Full Access to follow this switch; without it, autocorrect stays on.",
                    isOn: keyboardAutocorrectBinding
                )
                typingSwitchNote(.autocorrect)
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "text.cursor",
                    title: "Live typing",
                    detail: "Your words appear in the text field as you speak and are replaced by the final text when you stop. Off: they show only in the keyboard's strip and the text is inserted once. Needs a live model (see Models). Needs Allow Full Access to follow this switch; without it, live typing stays on.",
                    isOn: keyboardLiveTypingBinding
                )
                typingSwitchNote(.liveTyping)
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "rectangle.on.rectangle",
                    title: "Dictation panel while recording",
                    detail: "On: the full keyboard switches to the dictation panel when you start dictating. Off: the keyboard stays on the page you were using, and on the typing keys the strip shows the live status. Needs Allow Full Access to follow this switch; without it, the keyboard stays on the page you were using.",
                    isOn: keyboardDictatePanelWhileRecordingBinding
                )
            }

            SettingsGroup(title: "Dictation", footer: "Mic changes apply to the next dictation.") {
                SettingsToggleRow(
                    icon: "keyboard.badge.ellipsis",
                    title: "Turn mic off after each dictation",
                    detail: keyboardSessionModeDetail,
                    isOn: keyboardSessionBinding
                )
                if coordinator.isKeyboardMicOn {
                    Button("Turn mic off", systemImage: "mic.slash.fill") {
                        Task { await coordinator.turnOffKeyboardMic() }
                    }
                    .frame(minHeight: 44)
                }
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsKeyboardMicAutoOffRow(
                    minutes: keyboardMicAutoOffBinding,
                    isAvailable: keyboardSessionMode
                )
            }

            SettingsGroup(title: "Lock Screen and Dynamic Island") {
                SettingsToggleRow(
                    icon: "waveform.badge.mic",
                    title: "Dictation Live Activities",
                    detail: "Show progress while you dictate with the keyboard, the Action Button or a voice note.",
                    isOn: $liveActivitiesForDictations
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "mic.circle",
                    title: "Keyboard mic card on the Lock Screen",
                    detail: "Shows a card with a Turn mic off button while the keyboard mic is on. It is off by default, and needs Dictation Live Activities on too.",
                    isOn: $liveActivitiesForKeyboardMic
                )
            }

            SettingsGroup(title: "Rewrite") {
                SettingsNavigationRow(
                    icon: "pencil.and.outline",
                    title: "Quill",
                    detail: "Tap Quill on the keyboard and say what to change. Uses your Custom LLM server."
                ) { openSettingsSection(.aiServices) }
            }
        }
    }

    var keyboardSessionBinding: Binding<Bool> {
        Binding(get: { !keyboardSessionMode }, set: { stopAfterEach in
            coordinator.setKeyboardSessionModeEnabled(!stopAfterEach)
        })
    }

    var keyboardLayoutBinding: Binding<KeyboardLayout> {
        Binding(
            get: { KeyboardLayout(storedValue: keyboardLayout) ?? .fallback },
            set: { layout in
                keyboardLayout = layout.storedValue
                coordinator.setKeyboardLayout(layout)
            }
        )
    }

    var keyboardAutocorrectBinding: Binding<Bool> {
        Binding(get: { keyboardAutocorrect }, set: { enabled in
            keyboardAutocorrect = enabled
            coordinator.setKeyboardAutocorrectEnabled(enabled)
        })
    }

    var keyboardLiveTypingBinding: Binding<Bool> {
        Binding(get: { keyboardLiveTyping }, set: { enabled in
            keyboardLiveTyping = enabled
            coordinator.setKeyboardLiveTypingEnabled(enabled)
        })
    }

    var keyboardDictatePanelWhileRecordingBinding: Binding<Bool> {
        Binding(get: { keyboardDictatePanelWhileRecording }, set: { enabled in
            keyboardDictatePanelWhileRecording = enabled
            coordinator.setKeyboardDictatePanelWhileRecording(enabled)
        })
    }

    var keyboardMicAutoOffBinding: Binding<Int> {
        Binding(
            get: { keyboardMicAutoOffMinutes },
            set: { minutes in
                keyboardMicAutoOffMinutes = minutes
                coordinator.setKeyboardMicAutoOffMinutes(minutes)
            }
        )
    }

    var keyboardSessionModeDetail: String {
        "On: the mic turns off as soon as a dictation ends, and the next keyboard dictation has to open Muesli to start it. Off: the mic stays ready between dictations, so the keyboard starts instantly, until you turn it off in Muesli, on the Lock Screen or in the Dynamic Island, or it turns off by itself (see below)."
    }

    /// A note under a typing switch when the keyboard cannot see the switch for lack of Allow Full Access.
    @ViewBuilder
    func typingSwitchNote(_ feature: SettingsPresentation.TypingFeature) -> some View {
        if let note = SettingsPresentation.typingSwitchNote(feature, access: keyboardSetupStatus.fullAccess) {
            Label(note, systemImage: "exclamationmark.triangle")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func refreshKeyboardStatus() {
        let store = SharedStore()
        let extensionStatus = try? store.keyboardExtensionStatus()
        let confirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.keyboardEnabledConfirmed)
        let fullAccessConfirmed = UserDefaults.standard.bool(forKey: OnboardingPreferenceKeys.fullAccessConfirmed)

        keyboardSetupStatus = KeyboardSetupStatus.resolve(
            hasOpenAccess: extensionStatus?.hasOpenAccess == true,
            enabledConfirmed: confirmed,
            fullAccessConfirmed: fullAccessConfirmed
        )
    }
}

/// Full or minimal keyboard. A row of its own: two choices with a line each, and when it takes effect.
struct SettingsKeyboardLayoutRow: View {
    @Binding var selection: KeyboardLayout

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "keyboard")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Keyboard layout")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Picker("Keyboard layout", selection: $selection) {
                    Text("Full").tag(KeyboardLayout.full)
                    Text("Minimal").tag(KeyboardLayout.minimal)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.keyboardLayout")
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Full: a typing keyboard with suggestions and autocorrect, and the dictation panel one 3 second hold on the Record key away.")
                    Text("Minimal: the dictation panel only, with no typing keys.")
                    Text("Takes effect the next time the keyboard opens. Needs Allow Full Access to follow this choice; without it, the keyboard stays Full.")
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// When the ready keyboard mic turns itself off. Its own row, because it is a separate choice from the toggle
/// above: that one decides whether the mic stays ready at all.
struct SettingsKeyboardMicAutoOffRow: View {
    @Binding var minutes: Int
    let isAvailable: Bool

    var body: some View {
        SettingsAccessoryRow(icon: "timer", title: "Turn mic off when idle", detail: detail) {
            Picker("Turn mic off when idle", selection: $minutes) {
                ForEach(KeyboardMicAutoOff.choices, id: \.self) { choice in
                    Text(KeyboardMicAutoOff.label(forMinutes: choice)).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(MuesliTheme.accent)
            .disabled(!isAvailable)
        }
        .opacity(isAvailable ? 1 : 0.5)
    }

    var detail: String {
        guard isAvailable else {
            return "Not needed while the mic turns off after each dictation."
        }
        return "Turns off a ready mic after this long unused, to save battery. Always off when the screen locks."
    }
}
