import ActivityKit
import SwiftUI
import WidgetKit

struct KeyboardMicLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KeyboardMicActivityAttributes.self) { context in
            controls(context)
                .padding()
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { controls(context) }
            } compactLeading: {
                if context.isStale {
                    Image(systemName: "mic.slash.fill")
                        .accessibilityLabel("Muesli microphone off")
                } else {
                    LiveActivityMicrophoneMark()
                        .accessibilityLabel("Muesli microphone on")
                }
            } compactTrailing: {
                if context.isStale {
                    EmptyView()
                } else if context.state.isRecording {
                    LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 24, height: 20)
                } else if context.state.showsCompletion() {
                    Image(systemName: "checkmark")
                        .accessibilityLabel("Dictation complete")
                } else if !context.state.isReady {
                    Image(systemName: "pause.fill")
                        .accessibilityLabel(context.state.title)
                }
            } minimal: {
                if context.isStale {
                    Image(systemName: "mic.slash.fill")
                        .accessibilityLabel("Muesli microphone off")
                } else if context.state.isRecording {
                    LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 24, height: 20)
                } else {
                    LiveActivityMicrophoneMark()
                        .accessibilityLabel(context.state.title)
                }
            }
        }
    }

    private func controls(_ context: ActivityViewContext<KeyboardMicActivityAttributes>) -> some View {
        LiveActivityStatusRow(
            title: context.isStale ? "Mic off" : context.state.title,
            subtitle: "muesli",
            isRecording: !context.isStale && context.state.isRecording,
            samples: context.isStale ? nil : context.state.waveform
        ) {
            // A stale activity is a leftover: the session it described is gone, so there is nothing to turn off.
            if !context.isStale {
                Button(intent: TurnOffKeyboardMicIntent(sessionID: context.attributes.sessionID)) {
                    Label("Turn mic off", systemImage: "mic.slash.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(.red.opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
    }
}
