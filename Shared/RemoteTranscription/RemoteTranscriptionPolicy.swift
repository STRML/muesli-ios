import Foundation

/// Where a dictation was started. The keyboard path matters because remote processing needs Full Access there.
enum RemoteDictationOrigin: Sendable, Equatable {
    case app
    case keyboard(hasFullAccess: Bool)
}

extension RemoteDictationOrigin {
    /// The Action Button hands its result to the keyboard when one is visible, but it is the app's own dictation:
    /// the Full Access rule is about the keyboard extension only. Unknown Full Access counts as none.
    static func resolve(startedFromKeyboard: Bool, isActionButton: Bool, keyboardHasFullAccess: Bool?) -> Self {
        guard startedFromKeyboard, !isActionButton else { return .app }
        return .keyboard(hasFullAccess: keyboardHasFullAccess == true)
    }
}

enum RemoteSkipReason: Sendable, Equatable {
    case settingOff
    case noEndpoint
    case privateContent
    case keyboardNeedsFullAccess
}

enum RemoteEligibility: Sendable, Equatable {
    case eligible
    case skip(RemoteSkipReason)
}

struct RemoteRequestContext: Sendable, Equatable {
    var settingEnabled: Bool
    var endpointConfigured: Bool
    var origin: RemoteDictationOrigin
    var isPrivateContent: Bool

    init(
        settingEnabled: Bool,
        endpointConfigured: Bool,
        origin: RemoteDictationOrigin = .app,
        isPrivateContent: Bool = false
    ) {
        self.settingEnabled = settingEnabled
        self.endpointConfigured = endpointConfigured
        self.origin = origin
        self.isPrivateContent = isPrivateContent
    }
}

struct RemoteTranscriptionTiming: Sendable, Equatable {
    /// A probe round trip slower than this means the server is too far away to help dictation.
    var probeThreshold: TimeInterval
    /// How long after the recording ends the remote text may still arrive and be used.
    var resultBudget: TimeInterval
    /// When on-device text is ready and the probe has not answered yet, wait this long for it, no more.
    var unresolvedProbeGrace: TimeInterval

    static let standard = RemoteTranscriptionTiming(
        probeThreshold: 0.4,
        resultBudget: 3,
        unresolvedProbeGrace: 0.05
    )
}

enum RemoteTranscriptionPolicy {
    static let checkboxTitle = "Use remote processing for higher accuracy"
    static let footnote = "Used when it can be done quickly. This endpoint gets full access to your recordings. Turn it on only if you trust the remote machine or control it completely."
    static let fullAccessBanner = "Full Access needed for remote processing"

    /// The `model` form field. The chat model is the wrong value here: the server routes speech by ASR model.
    static let asrModel = "qwen3-asr-1.7b"
    static let maxUploadBytes = 25 * 1024 * 1024

    /// Why a request stays on the phone, in the order the user would expect the reasons to apply.
    static func eligibility(for context: RemoteRequestContext) -> RemoteEligibility {
        guard context.settingEnabled else { return .skip(.settingOff) }
        guard context.endpointConfigured else { return .skip(.noEndpoint) }
        guard !context.isPrivateContent else { return .skip(.privateContent) }
        if case .keyboard(let hasFullAccess) = context.origin, !hasFullAccess {
            return .skip(.keyboardNeedsFullAccess)
        }
        return .eligible
    }

    static func showsCheckbox(endpointConfigured: Bool) -> Bool {
        endpointConfigured
    }

    /// The stored choice counts only while its checkbox can be seen: Settings shows it under the Custom LLM summary
    /// backend, so switching to another backend must stop uploads rather than hide a setting that keeps sending audio.
    static func isSettingActive(stored: Bool, endpointConfigured: Bool, summaryBackendIsCustomLLM: Bool) -> Bool {
        stored && endpointConfigured && summaryBackendIsCustomLLM
    }

    static let publicEndpointWarningText = "This address doesn't look like a private server. Dictation recordings would leave your network."

    /// A warning, never a block: the user decides whom to trust. Private means loopback, LAN, link-local,
    /// Tailscale (100.64.0.0/10 or *.ts.net) or a .local name. Nil for those and for an unparseable address.
    static func publicEndpointWarning(baseURL: String) -> String? {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return isPrivateHost(host) ? nil : publicEndpointWarningText
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".local") || bare.hasSuffix(".ts.net") { return true }
        if bare.contains(":") {
            return bare == "::1" || bare.hasPrefix("fc") || bare.hasPrefix("fd") || bare.hasPrefix("fe80")
        }
        let octets = bare.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    static func keyboardBanner(remoteProcessingEnabled: Bool, hasFullAccess: Bool) -> String? {
        remoteProcessingEnabled && !hasFullAccess ? fullAccessBanner : nil
    }
}
