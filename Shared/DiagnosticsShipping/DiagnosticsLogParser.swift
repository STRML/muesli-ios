import Foundation

/// One line of the on-device diagnostics log, split into its columns and given a stable identity.
struct DiagnosticsLogLine: Equatable, Sendable {
    /// A hash of the raw line. The log is rewritten on every append, so a byte offset means nothing; the
    /// fractional-second timestamp makes the line itself the identity.
    let id: String
    let time: String
    let process: String
    let name: String
    /// The rendered `key=value key=value` text.
    let detail: String
}

struct DiagnosticsLogParseResult: Equatable, Sendable {
    var lines: [DiagnosticsLogLine] = []
    /// Complete lines that did not have the timestamp, process and event columns.
    var malformedLines = 0
    /// The text did not end in a newline, so its last line may be half written and was left for the next read.
    var skippedPartialTail = false
}

enum DiagnosticsLogParser {
    static func parse(_ text: String) -> DiagnosticsLogParseResult {
        var result = DiagnosticsLogParseResult()
        guard !text.isEmpty else { return result }
        // `components`, not `split(separator: "\n")`: Swift treats "\r\n" as one Character and would not split on it.
        var rows = text.components(separatedBy: "\n")
        // The last element is what follows the final newline. Empty means the file ended cleanly; anything else is a
        // line another process was still writing.
        if let tail = rows.popLast(), !tail.isEmpty { result.skippedPartialTail = true }
        for row in rows where !row.isEmpty {
            let columns = row.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard columns.count >= 3, !columns[0].isEmpty, !columns[1].isEmpty, !columns[2].isEmpty else {
                result.malformedLines += 1
                continue
            }
            result.lines.append(DiagnosticsLogLine(
                id: lineID(row),
                time: String(columns[0]),
                process: String(columns[1]),
                name: String(columns[2]),
                detail: columns.count > 3 ? String(columns[3]) : ""
            ))
        }
        return result
    }

    /// FNV-1a, 64 bit, as 16 hex digits. Swift's `Hasher` is seeded per launch, so it cannot name a line across launches.
    static func lineID(_ raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// The text format shared by the writer (`KeyboardDiagnosticsLog`) and the reader, so one test covers the round trip.
enum DiagnosticsLogFormat {
    static let valueLimit = 64

    /// `key=value` pairs sorted by key and joined by spaces.
    static func renderDetail(_ detail: [String: String]) -> String {
        detail
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(cleanValue($0.value))" }
            .joined(separator: " ")
    }

    /// Control characters and line separators become spaces, so a value cannot add a column or a line; values over
    /// ``valueLimit`` are cut and marked with `...`, which the reader treats as "not the real value".
    static func cleanValue(_ value: String) -> String {
        let flattened = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 ? " " : scalar
        }))
        return flattened.count <= valueLimit ? flattened : String(flattened.prefix(valueLimit)) + "..."
    }

    /// `2026-10-16T09:30:00.123Z`: ISO 8601 with milliseconds, always UTC, so lines sort and compare as text.
    static func timestamp(_ date: Date) -> String {
        let totalMilliseconds = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = Int((Double(totalMilliseconds) / 1000).rounded(.down))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        return String(base.dropLast()) + "." + String(format: "%03d", totalMilliseconds - seconds * 1000) + "Z"
    }

    /// True for `YYYY-MM-DDTHH:MM:SS.mmmZ` with plausible field ranges. Checked by hand: a formatter is slower and
    /// accepts more shapes than the writer ever produces.
    static func isTimestamp(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 24 else { return false }
        let separators: [Int: UInt8] = [4: 0x2D, 7: 0x2D, 10: 0x54, 13: 0x3A, 16: 0x3A, 19: 0x2E, 23: 0x5A]
        for (index, byte) in bytes.enumerated() {
            if let expected = separators[index] {
                if byte != expected { return false }
            } else if byte < 0x30 || byte > 0x39 {
                return false
            }
        }
        func number(_ range: Range<Int>) -> Int { bytes[range].reduce(0) { $0 * 10 + Int($1 - 0x30) } }
        return (1...12).contains(number(5..<7)) && (1...31).contains(number(8..<10))
            && number(11..<13) < 24 && number(14..<16) < 60 && number(17..<19) < 61
    }

    /// The whole line, without its newline: timestamp, process, event and detail, separated by tabs.
    static func line(date: Date, process: String, event: String, detail: [String: String]) -> String {
        let fields = [process, event, renderDetail(detail)].filter { !$0.isEmpty }
        return ([timestamp(date)] + fields).joined(separator: "\t")
    }
}
