import Foundation

/// One log event that passed the allowlist, in the shape that goes on the wire.
struct DiagnosticsEvent: Codable, Equatable, Sendable {
    /// The log line's hash. The server can drop a repeat of the same event by it.
    var id: String
    var time: String
    var process: String
    var name: String
    var fields: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, time, process, name = "event", fields
    }
}

struct DiagnosticsSanitizeResult: Equatable, Sendable {
    /// Nil when the event itself is not allowed (unknown name, bad process, bad timestamp).
    var event: DiagnosticsEvent?
    /// Fields removed from an event that was otherwise kept. An unallowed event counts as one dropped event
    /// instead, reported by the caller.
    var droppedFields = 0
}

enum DiagnosticsSanitizer {
    private struct Pair {
        var key: String
        var value: String
        var poisoned = false
    }

    static func sanitize(_ line: DiagnosticsLogLine) -> DiagnosticsSanitizeResult {
        guard DiagnosticsVocabulary.events.contains(line.name),
              DiagnosticsValueRule.identifier.accepts(line.process),
              DiagnosticsLogFormat.isTimestamp(line.time)
        else { return DiagnosticsSanitizeResult() }

        let (pairs, strays) = pairs(in: line.detail)
        var result = DiagnosticsSanitizeResult(droppedFields: strays)
        var fields: [String: String] = [:]
        for pair in pairs {
            guard let rule = DiagnosticsVocabulary.keyRules[pair.key],
                  !pair.poisoned,
                  fields[pair.key] == nil,
                  !pair.value.hasSuffix("..."),
                  rule.accepts(pair.value)
            else {
                result.droppedFields += 1
                continue
            }
            // The receiver's value alphabet has no comma, so a list goes out joined with "+".
            fields[pair.key] = rule == .identifierList ? pair.value.replacingOccurrences(of: ",", with: "+") : pair.value
        }
        result.event = DiagnosticsEvent(id: line.id, time: line.time, process: line.process, name: line.name, fields: fields)
        return result
    }

    /// Splits `key=value key=value`. The format cannot tell a value with a space from a new pair, so a token without
    /// `=` poisons the pair before it, and that pair is dropped whole instead of being kept as its first word.
    /// Returns the pairs and the count of stray tokens that had no pair to poison.
    private static func pairs(in detail: String) -> (pairs: [Pair], strays: Int) {
        guard !detail.isEmpty else { return ([], 0) }
        var pairs: [Pair] = []
        var strays = 0
        for token in detail.split(separator: " ", omittingEmptySubsequences: false) {
            if let equals = token.firstIndex(of: "="), isKey(token[..<equals]) {
                pairs.append(Pair(key: String(token[..<equals]), value: String(token[token.index(after: equals)...])))
            } else if pairs.isEmpty {
                strays += 1
            } else {
                pairs[pairs.count - 1].poisoned = true
            }
        }
        return (pairs, strays)
    }

    private static func isKey(_ text: Substring) -> Bool {
        guard let first = text.utf8.first, first == 0x5F || (first | 0x20) >= 0x61 && (first | 0x20) <= 0x7A else { return false }
        return text.utf8.allSatisfy { $0 == 0x5F || ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A || ($0 >= 0x30 && $0 <= 0x39) }
    }
}
