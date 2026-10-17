import SwiftUI

extension SettingsView {
    var meetingSettings: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                SettingsToggleRow(
                    icon: "sparkles",
                    title: "Meeting Summaries",
                    detail: "Generate structured notes after local transcription and speaker diarization.",
                    isOn: $meetingSummariesEnabled
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "waveform.path.ecg.rectangle",
                    title: "Save Meeting Audio",
                    detail: "Keep the original meeting recording after delayed transcription finishes. Queued recordings are always kept until transcription completes.",
                    isOn: $keepMeetingAudioRecordings
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsToggleRow(
                    icon: "person.2.wave.2",
                    title: "Meeting Live Activities",
                    detail: "Show active meeting recordings while Muesli is recording in the background.",
                    isOn: $liveActivitiesForMeetings
                )
                Divider().overlay(MuesliTheme.surfaceBorder)
                SettingsMeetingTemplatePicker(selection: $meetingTemplate)
            }
            .padding(MuesliTheme.spacing16)
        }
    }
}

struct SettingsMeetingTemplatePicker: View {
    @Binding var selection: String

    var selectedTemplate: MeetingTemplatePreset {
        MeetingTemplatePreset(rawValue: selection) ?? .general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Meeting Template")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(selectedTemplate.detail)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Meeting Template", selection: $selection) {
                ForEach(MeetingTemplatePreset.allCases) { template in
                    Text(template.label).tag(template.rawValue)
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
        guard MeetingTemplatePreset(rawValue: selection) == nil else { return }
        selection = MeetingTemplatePreset.general.rawValue
    }
}
