import Foundation

/// The words the Settings section, the privacy manifest note and `docs/diagnostics-shipping.md` use to say what is
/// sent. One copy, so a test can hold the docs to it.
enum DiagnosticsShippingCopy {
    static let sectionTitle = "Diagnostics"
    static let toggleTitle = "Send diagnostics to my server"
    static let toggleDetail = "Off by default. When on, Muesli sends its event log to your own server (the address below, or the AI Summaries server), so a dictation that did not save can be traced. The log records what happened and when, never what you said."
    static let whatIsSent = "Sent: event names, request and note IDs, timings, counts, error codes, the app and iOS version, the hardware model, the thermal state, and a random ID for this install."
    static let whatIsNotSent = "Never sent: transcripts, rewrites, selected or surrounding text, document context, audio, contacts, window or field text, your device name, or anything not on the allowlist. It goes only to your server's address, over HTTPS, and to no other service."
    static let sendNowDetail = "Send now uploads the events already in this phone's log (the newest \(KeyboardDiagnosticsLogLimit.entries)), including ones from before you turned this on."
    static let receiverGuideTitle = "How to set up a receiver"
    static let receiverGuideURL = "https://github.com/STRML/muesli-ios/blob/main/docs/diagnostics-receiver.md"
    static let noEndpoint = "No server set. Enter a Diagnostics server above, or add a Server URL under AI Summaries. \(receiverGuideTitle) explains what the server needs."
    static let serverFieldTitle = "Diagnostics server"
    static let serverFieldPlaceholder = "Same as AI Summaries"
    static let sendsToTitle = "Sends to"
    static let keyNote = "The API key is the one under AI Summaries."
    static let fromOwnField = "From the Diagnostics server field. " + keyNote
    static let fromAISummaries = "From the Server URL under AI Summaries. Type an address in Diagnostics server to send diagnostics somewhere else. " + keyNote
    static let invalidOverride = "The Diagnostics server must be an address that starts with https://. Nothing is sent until it is."
    static let publicEndpointAcknowledgement = "I trust this server with my diagnostics"
    static let keyRejected = "The server rejected the API key. Fix it under AI Summaries, then tap Send now."
    static let routeMissing = "The server has no /diagnostics route yet. Tap Send now once it does."
    static let resetDetail = "Starts a new random ID for this install and discards events that have not been sent."
}

/// The log keeps this many lines. Mirrors `KeyboardDiagnosticsLog.entryLimit`, which this target cannot see.
enum KeyboardDiagnosticsLogLimit {
    static let entries = 600
}
