import Darwin
import UIKit
import XCTest
@testable import Muesli

/// Records the real checker's candidate pool for every corpus item, so the cost weights, the usage prior and the
/// margin can be tuned on a Mac in seconds (`TuningHarnessTests` in KeyboardTypingKitTests reads the file)
/// instead of re-typing 20,000 typos through the simulator for every guess. Skipped unless
/// `MUESLI_POOL_RECORDING_OUT` (as `TEST_RUNNER_MUESLI_POOL_RECORDING_OUT`) names the file to write.
@MainActor
final class AutocorrectPoolRecorderTests: XCTestCase {
    private struct Row: Encodable {
        let typed: String
        let intended: String?
        let kind: String
        let length: Int
        let tuning: Bool
        let capitalized: Bool
        let tail: Bool
        let candidates: [[Item]]
    }

    private enum Item: Encodable {
        case word(String)
        case number(Int)
        case numbers([Int])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .word(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .numbers(let value): try container.encode(value)
            }
        }
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : 0
    }

    func testRecordPools() throws {
        guard let out = ProcessInfo.processInfo.environment["MUESLI_POOL_RECORDING_OUT"] else {
            throw XCTSkip("Set MUESLI_POOL_RECORDING_OUT to record the candidate pools.")
        }
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        defer { try? handle.close() }
        var checker = UITextCheckerAdapter()
        var seconds: [Double] = []
        var written = 0
        let encoder = JSONEncoder()
        // Optional slice "i/n": only rows whose index modulo n is i, so a long recording can run in several
        // short runs (one run was killed by the system after a few minutes).
        let slice = (ProcessInfo.processInfo.environment["MUESLI_POOL_SLICE"] ?? "0/1").split(separator: "/").compactMap { Int($0) }
        let sliceIndex = slice.first ?? 0, sliceCount = max(1, slice.last ?? 1)
        var seen = 0

        func record(typed: String, intended: String?, kind: String, length: Int, tuning: Bool, tail: Bool = false) {
            seen += 1
            guard (seen - 1) % sliceCount == sliceIndex else { return }
            autoreleasepool {
                // A fresh checker now and then: one instance grows with every word it is asked about.
                if written % 1500 == 0 { checker = UITextCheckerAdapter() }
                // The system's completion service has gone quiet on this simulator now and then; a recording made
                // while it was would say no word is used at all, so stop instead of writing it.
                if written % 100 == 0, checker.completions(forPartial: "a", language: "en_US").isEmpty {
                    XCTFail("UITextChecker.completions returned nothing for \"a\" after \(written) rows")
                    return
                }
                var pool = TypingCandidatePool(checker: checker, language: "en_US")
                pool.options.usageDepth = 5
                pool.options.usageLimit = 8
                let start = ProcessInfo.processInfo.systemUptime
                let candidates = pool.candidates(for: typed)
                seconds.append(ProcessInfo.processInfo.systemUptime - start)
                let row = Row(
                    typed: typed, intended: intended, kind: kind, length: length, tuning: tuning,
                    capitalized: typed.first?.isUppercase == true, tail: tail,
                    candidates: candidates.map { [.word($0.word), .number($0.guessPosition ?? -1), .numbers($0.usage)] }
                )
                if let data = try? encoder.encode(row) {
                    handle.write(data)
                    handle.write(Data("\n".utf8))
                }
                written += 1
                if written % 250 == 0 { NSLog("POOLPROGRESS %d rows, footprint %d MB", written, Self.footprintMB()) }
            }
        }

        for typo in TypoGenerator.generate(from: CommonWords.all) + TypoGenerator.generateTail() where typo.kind != .apostrophe {
            guard checker.isMisspelled(typo.typed, language: "en_US") else { continue }
            record(typed: typo.typed, intended: typo.intended, kind: typo.kind.rawValue, length: typo.length,
                   tuning: TypoGenerator.isTuningWord(typo.intended), tail: typo.isTail)
        }
        for pair in AutocorrectCorpus.typos + AutocorrectCorpus.sentenceStartTypos {
            record(typed: pair.typed, intended: pair.expected, kind: "hand-made", length: pair.expected.filter(\.isLetter).count, tuning: false)
        }
        for group in AutocorrectCorpus.neverChangeGroups {
            for token in group.tokens where token.allSatisfy(\.isLetter) && (3...24).contains(token.count) {
                guard checker.isMisspelled(token, language: "en_US") else { continue }
                record(typed: token, intended: nil, kind: "never:" + group.category, length: token.count,
                       tuning: TypoGenerator.isTuningWord(token.lowercased()))
            }
        }
        print("POOLS \(written) rows -> \(out); " + CorpusReport.latencyLine(seconds))
    }
}
