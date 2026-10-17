import Foundation

/// The words the Settings section, the privacy manifest note and `docs/diagnostics-shipping.md` use to say what is
/// sent. One copy, so a test can hold the docs to it.
enum DiagnosticsShippingCopy {
    static let sectionTitle = "Diagnostics"
    static let toggleTitle = "Send diagnostics to my server"
    static let toggleDetail = "Off by default. When on, Muesli sends its event log to the server you set under AI Summaries, so a dictation that did not save can be traced. The log records what happened and when, never what you said."
    static let whatIsSent = "Sent: event names, request and note IDs, timings, counts, error codes, the app and iOS version, the hardware model, the thermal state, and a random ID for this install."
    static let whatIsNotSent = "Never sent: transcripts, rewrites, selected or surrounding text, document context, audio, contacts, window or field text, your device name, or anything not on the allowlist. It goes only to your server's address, over HTTPS, and to no other service."
    static let sendNowDetail = "Send now uploads the events already in this phone's log (the newest \(KeyboardDiagnosticsLogLimit.entries)), including ones from before you turned this on."
    static let noEndpoint = "No server set. Add a Server URL under AI Summaries."
    static let publicEndpointAcknowledgement = "I trust this server with my diagnostics"
    static let keyRejected = "The server rejected the API key. Fix it under AI Summaries, then tap Send now."
    static let routeMissing = "The server has no /diagnostics route yet. Tap Send now once it does."
    static let resetDetail = "Starts a new random ID for this install and discards events that have not been sent."
}

/// The log keeps this many lines. Mirrors `KeyboardDiagnosticsLog.entryLimit`, which this target cannot see.
enum KeyboardDiagnosticsLogLimit {
    static let entries = 600
}
