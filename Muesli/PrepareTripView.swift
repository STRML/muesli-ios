import SwiftUI

/// The screen the keyboard sends the user to when dictation is not ready. It shows the same states the keyboard
/// shows, loads the speech model as the user's request, and says when to go back.
struct PrepareTripView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let presentation = coordinator.prepareTripPresentation {
                content(presentation)
            }
        }
        .transition(.opacity)
    }

    private func content(_ presentation: PrepareTripPresentation) -> some View {
        ZStack {
            MuesliTheme.backgroundBase.ignoresSafeArea()

            VStack(spacing: MuesliTheme.spacing24) {
                Spacer(minLength: MuesliTheme.spacing32)

                symbol(presentation)

                VStack(spacing: MuesliTheme.spacing12) {
                    Text(presentation.title)
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("prepare.title")
                    Text(presentation.detail)
                        .font(MuesliTheme.title3())
                        .foregroundStyle(presentation.isReady ? MuesliTheme.success : MuesliTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("prepare.detail")
                    if let note = presentation.note {
                        Text(note)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if presentation.showsProgress {
                    progress(presentation)
                }

                Spacer()

                actions(presentation)
            }
            .padding(MuesliTheme.spacing24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prepare.screen")
    }

    @ViewBuilder
    private func symbol(_ presentation: PrepareTripPresentation) -> some View {
        Image(systemName: presentation.symbol)
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(presentation.isReady ? MuesliTheme.success : MuesliTheme.brandBlue)
            .symbolEffect(.pulse, isActive: presentation.showsProgress)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func progress(_ presentation: PrepareTripPresentation) -> some View {
        if let value = presentation.progress {
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ViewBuilder
    private func actions(_ presentation: PrepareTripPresentation) -> some View {
        VStack(spacing: MuesliTheme.spacing12) {
            if let button = presentation.primaryButton {
                Button(button == .retry ? "Try again" : "Download the model") {
                    coordinator.retryPrepareTrip()
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("prepare.primary")
            }
            if presentation.isReady {
                Label("Swipe right across the bottom edge", systemImage: "arrow.left.arrow.right")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.success)
            }
            Button(presentation.isReady ? "Done" : "Not now") {
                coordinator.dismissPrepareTrip()
            }
            .frame(minHeight: 44)
            .foregroundStyle(MuesliTheme.textSecondary)
            .accessibilityIdentifier("prepare.dismiss")
        }
    }
}
