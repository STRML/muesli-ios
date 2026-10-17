import Foundation

/// What a logged value has to look like to leave the phone. Each rule is strict ASCII: anything with a space, a
/// newline, a non-ASCII scalar or an over-long run fails, which is what keeps dictated text out.
enum DiagnosticsValueRule: Sendable, Equatable {
    /// A full UUID.
    case uuid
    /// A full UUID, or the keyboard's 8 lowercase hex prefix of one.
    case requestID
    /// `requestID`, or `none`.
    case optionalID
    case int
    /// A code identifier or an integer.
    case codeOrInt
    case decimal
    /// `true`, `false`, `yes`, `no`.
    case flag
    /// Seconds: `0.45`, `1.2s`, or `none`, `never`, `unlimited`.
    case duration
    case oneOf(Set<String>)
    /// A short code identifier such as `foregroundCopyRequired` or `AVAudioSessionCategoryPlayAndRecord`.
    case identifier
    /// Comma-separated identifiers, for audio route ports.
    case identifierList
    /// An error domain such as `NSURLErrorDomain` or `com.apple.coreaudio.avfaudio`.
    case errorDomain
    /// An app version or build: `0.1.7`, `42`.
    case version
    /// A hardware identifier such as `iPhone17,1`. Never the user-assigned device name.
    case hardwareModel

    func accepts(_ value: String) -> Bool {
        switch self {
        case .uuid: Self.isUUID(value)
        case .requestID: Self.isUUID(value) || Self.isShortID(value)
        case .optionalID: value == "none" || Self.isUUID(value) || Self.isShortID(value)
        case .int: Self.isInt(value)
        case .codeOrInt: Self.isInt(value) || Self.isIdentifier(value)
        case .decimal: Self.isDecimal(value)
        case .flag: ["true", "false", "yes", "no"].contains(value)
        case .duration: ["none", "never", "unlimited"].contains(value) || Self.isDuration(value)
        case .oneOf(let allowed): allowed.contains(value)
        case .identifier: Self.isIdentifier(value)
        case .identifierList: Self.isIdentifierList(value)
        case .errorDomain: Self.isErrorDomain(value)
        case .version: Self.isVersion(value)
        case .hardwareModel: Self.isHardwareModel(value)
        }
    }

    // MARK: Shapes
    //
    // All checks walk `utf8`, so a non-ASCII scalar can never satisfy a class by accident (`Character.isNumber` is
    // true for Arabic-Indic and full-width digits, and `isLetter` for accented ones).

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
    private static func isLowerHex(_ byte: UInt8) -> Bool { isDigit(byte) || (byte >= 0x61 && byte <= 0x66) }
    private static func isHex(_ byte: UInt8) -> Bool { isLowerHex(byte) || (byte >= 0x41 && byte <= 0x46) }

    private static func isUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if byte != 0x2D { return false }
            } else if !isHex(byte) {
                return false
            }
        }
        return true
    }

    private static func isShortID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 8 && bytes.allSatisfy(isLowerHex)
    }

    private static func isInt(_ value: String) -> Bool {
        var bytes = Array(value.utf8)
        if bytes.first == 0x2D { bytes.removeFirst() }
        return (1...12).contains(bytes.count) && bytes.allSatisfy(isDigit)
    }

    private static func isDecimal(_ value: String) -> Bool {
        var bytes = Array(value.utf8)
        if bytes.first == 0x2D { bytes.removeFirst() }
        let parts = bytes.split(separator: 0x2E, maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, (1...10).contains(whole.count), whole.allSatisfy(isDigit) else { return false }
        guard parts.count == 2 else { return true }
        return (1...6).contains(parts[1].count) && parts[1].allSatisfy(isDigit)
    }

    /// `0.45`, `-0.3s`, `1.2s`, `12`.
    private static func isDuration(_ value: String) -> Bool {
        guard value.utf8.count <= 14 else { return false }
        return isDecimal(value.hasSuffix("s") ? String(value.dropLast()) : value)
    }

    /// A letter, then letters, digits and `_ . : -`; short; not ending in a dot (which would be a cut-off value).
    private static func isIdentifier(_ value: String, maxLength: Int = 48) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maxLength).contains(bytes.count), isLetter(bytes[0]), bytes.last != 0x2E else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || [0x5F, 0x2E, 0x3A, 0x2D].contains($0) }
    }

    private static func isIdentifierList(_ value: String) -> Bool {
        guard value.utf8.count <= 160 else { return false }
        if value.isEmpty { return true }
        let items = value.split(separator: ",", omittingEmptySubsequences: false)
        return items.count <= 8 && items.allSatisfy { isIdentifier(String($0)) }
    }

    /// `NSURLErrorDomain`, `com.apple.coreaudio.avfaudio`. A bare word is not a domain, so a dictated word cannot pass.
    private static func isErrorDomain(_ value: String) -> Bool {
        guard isIdentifier(value, maxLength: 64) else { return false }
        return value.contains(".") || value.hasSuffix("Domain")
    }

    private static func isVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...24).contains(bytes.count), isLetter(bytes[0]) || isDigit(bytes[0]) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || [0x5F, 0x2E, 0x2D].contains($0) }
    }

    /// `iPhone18,1`: letters, digits and a comma, with at least one digit. A name like "Sam's iPhone" has a space.
    private static func isHardwareModel(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...24).contains(bytes.count), isLetter(bytes[0]), bytes.contains(where: isDigit) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == 0x2C }
    }
}
