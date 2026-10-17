import XCTest
@testable import DiagnosticsKit

/// Reads the source tree so a new `KeyboardDiagnosticsLog.record("...")` cannot silently never be uploaded.
final class DiagnosticsVocabularyScanTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under directory: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func recordedEventNames() throws -> Set<String> {
        let pattern = try NSRegularExpression(
            pattern: #"(?:KeyboardDiagnosticsLog\.record|recordCaptureLifecycle)\(\s*"([A-Za-z0-9_.]+)""#
        )
        var names = Set<String>()
        for directory in ["Muesli", "MuesliKeyboard", "Shared"] {
            for file in swiftFiles(under: directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                for match in pattern.matches(in: text, range: range) {
                    if let nameRange = Range(match.range(at: 1), in: text) { names.insert(String(text[nameRange])) }
                }
            }
        }
        return names
    }

    func testTheScanFindsTheEventsTheAppRecords() throws {
        let names = try recordedEventNames()
        XCTAssertGreaterThan(names.count, 40, "the scan found too few record() calls; the source layout may have moved")
        XCTAssertTrue(names.contains("intent.stop"))
        XCTAssertTrue(names.contains("recording.started"))
    }

    func testEveryRecordedEventNameIsInTheVocabulary() throws {
        let missing = try recordedEventNames().subtracting(DiagnosticsVocabulary.events).sorted()
        XCTAssertEqual(
            missing, [],
            "These events are recorded but not in DiagnosticsVocabulary.events, so they would never be uploaded. Add them to Shared/DiagnosticsShipping/DiagnosticsVocabulary.swift."
        )
    }

    func testEveryVocabularyEventIsRecordedSomewhere() throws {
        // Events built through DiagnosticsEvents carry their name in the Shared/DiagnosticsShipping sources, and the scene
        // events come from `recordCaptureLifecycle("scene.\(phase)")`.
        var text = ""
        for directory in ["Muesli", "MuesliKeyboard", "Shared"] {
            for file in swiftFiles(under: directory) where file.lastPathComponent != "DiagnosticsVocabulary.swift" {
                text += try String(contentsOf: file, encoding: .utf8)
            }
        }
        let scene: Set = ["scene.active", "scene.inactive", "scene.background"]
        let unused = DiagnosticsVocabulary.events.subtracting(scene).filter { !text.contains("\"\($0)\"") }
        XCTAssertEqual(unused.sorted(), [], "Events allowlisted but never recorded; remove them from the vocabulary.")
    }
}
