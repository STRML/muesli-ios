import Darwin
import UIKit
import XCTest
@testable import Muesli

/// The keyboard extension has a small memory ceiling that Apple does not publish, so what autocorrect adds is
/// measured. This is the test process, not the extension: a proxy, taken as the change in `phys_footprint`.
@MainActor
final class AutocorrectFootprintTests: XCTestCase {
    private func footprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) / 1024 : 0
    }

    // What the previous rule asked of the checker, then what this one asks, over different typos of the same size.
    func testFootprintOfTheGuessOnlyPathAndOfTheCandidatePool() throws {
        let typos = TypoGenerator.generate(from: CommonWords.all).filter { $0.kind != .apostrophe }
        let first = Array(typos.prefix(2500)), second = Array(typos.dropFirst(2500).prefix(2500))
        let start = footprintKB()
        let checker = UITextCheckerAdapter()
        _ = checker.isMisspelled("warm", language: "en_US")
        let afterChecker = footprintKB()
        for typo in first {
            if checker.isMisspelled(typo.typed, language: "en_US") { _ = checker.guesses(forWord: typo.typed, language: "en_US") }
        }
        let afterGuesses = footprintKB()
        let pool = TypingCandidatePool(checker: checker, language: "en_US")
        for typo in second where checker.isMisspelled(typo.typed, language: "en_US") { _ = pool.candidates(for: typo.typed) }
        let afterPool = footprintKB()
        let text = "footprint KB: start \(start), checker created \(afterChecker), after 2500 guess-only words \(afterGuesses), " +
            "after 2500 candidate-pool words \(afterPool); checker +\(afterChecker - start), guess path +\(afterGuesses - afterChecker), " +
            "pool path +\(afterPool - afterGuesses)"
        print("FOOTPRINT \(text)")
        try? text.write(toFile: NSTemporaryDirectory() + "autocorrect-footprint.txt", atomically: true, encoding: .utf8)
        XCTAssertLessThan(afterPool - afterGuesses, 20_000, text)
    }

    // What the appear-time warm-up costs: wall time on its queue, and the footprint it adds beyond a bare checker.
    func testCostOfTheAppearTimeWarmUp() async throws {
        let warmup = TypingCheckerWarmup(makeWarmer: { UITextCheckerWarmer() }, scheduler: DispatchWarmupScheduler())
        let start = footprintKB()
        let began = ProcessInfo.processInfo.systemUptime
        var appeared = began
        warmup.start(languages: ["en-US"], available: UITextChecker.availableLanguages)
        appeared = ProcessInfo.processInfo.systemUptime
        while warmup.state == .warming, ProcessInfo.processInfo.systemUptime - began < 30 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let done = ProcessInfo.processInfo.systemUptime
        let after = footprintKB()
        let lookups = TypingCheckerWarmup.probeLetters.count + TypingCheckerWarmup.probeTypos.count
        let text = String(
            format: "warm-up state %@, start() returned in %.3f ms, finished after %.1f ms (%d lookups), footprint KB %d -> %d (+%d)",
            "\(warmup.state)", (appeared - began) * 1000, (done - began) * 1000, lookups, start, after, after - start
        )
        print("WARMUP COST \(text)")
        try? text.write(toFile: NSTemporaryDirectory() + "warmup-cost.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(warmup.state, .warm, text)
        XCTAssertLessThan((appeared - began) * 1000, 5, "start() must not do the lookups on the caller")
    }
}
