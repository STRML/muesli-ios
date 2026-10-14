import Foundation

/// When the keyboard mic's Live Activity must go away. The Island promises "the mic is on", so a session
/// that is over for any reason has to take it down; a session that is only paused for another capture
/// (`requestFinished` after the mic was handed over) keeps it.
enum KeyboardMicActivityPolicy {
    static func endsActivity(after event: KeyboardSessionEvent) -> Bool {
        switch event {
        case .micStopped, .stop, .standbyStopped:
            true
        case .startFailed(_, let recoverable):
            !recoverable
        case .micRequested, .startRequested, .startSucceeded, .retryScheduled, .resumeRequested,
             .handoffStarted, .recordingStarted, .transcribing, .requestFinished:
            false
        }
    }
}
