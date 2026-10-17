import XCTest
@testable import DiagnosticsKit

/// The privacy page must say what the allowlist allows. These tests read the docs, the README and the privacy
/// manifest from the source tree, so changing the vocabulary without the words fails the build.
final class DiagnosticsDocsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheDocsListEveryAllowlistedEventAndKey() throws {
        let docs = try read("docs/diagnostics-shipping.md")
        let missingEvents = DiagnosticsVocabulary.events.filter { !docs.contains("`\($0)`") }.sorted()
        let missingKeys = DiagnosticsVocabulary.keyRules.keys.filter { !docs.contains("`\($0)`") }.sorted()
        XCTAssertEqual(missingEvents, [], "events missing from docs/diagnostics-shipping.md")
        XCTAssertEqual(missingKeys, [], "keys missing from docs/diagnostics-shipping.md")
    }

    func testTheDocsListTheClosedValuesOfEveryClosedKey() throws {
        let docs = try read("docs/diagnostics-shipping.md")
        for (key, rule) in DiagnosticsVocabulary.keyRules {
            guard case .oneOf(let values) = rule else { continue }
            for value in values {
                XCTAssertTrue(docs.contains(value), "value \(value) of \(key) is not in the docs")
            }
        }
    }

    func testTheDocsDocumentTheEnvelopeFields() throws {
        let docs = try read("docs/diagnostics-shipping.md")
        let envelope = try JSONSerialization.jsonObject(
            with: DiagnosticsEnvelope(
                batchID: "b", seq: 1, sentAt: "t", deviceID: "d", appVersion: "v", appBuild: "b", os: "i",
                model: "m", thermal: "nominal", trigger: .timer, droppedEvents: 0, droppedFields: 0,
                rejectedEvents: 0, events: []
            ).encoded()
        ) as? [String: Any]
        for key in envelope?.keys ?? [:].keys { XCTAssertTrue(docs.contains("\"\(key)\""), "envelope field \(key) is not in the docs") }
    }

    func testTheSettingsCopyAndTheDocsAgreeOnWhatIsNeverSent() throws {
        let docs = try read("docs/diagnostics-shipping.md").lowercased()
        for term in ["transcript", "rewrite", "selected", "document context", "audio", "contact", "window", "field text", "device name"] {
            XCTAssertTrue(DiagnosticsShippingCopy.whatIsNotSent.lowercased().contains(term), "settings copy omits \(term)")
            XCTAssertTrue(docs.contains(term), "docs omit \(term)")
        }
        XCTAssertTrue(DiagnosticsShippingCopy.toggleDetail.contains("Off by default"))
    }

    /// The remote-transcription warning says "Dictation recordings would leave your network", which is true for that
    /// feature and false here: a diagnostics log never holds audio.
    func testThePublicServerWarningTalksAboutTheLogNotRecordings() {
        let warning = DiagnosticsShippingCopy.publicServerWarning.lowercased()
        XCTAssertTrue(warning.contains("log"))
        XCTAssertTrue(warning.contains("private server"))
        XCTAssertFalse(warning.contains("recording"))
        XCTAssertFalse(warning.contains("dictation"))
    }

    func testTheDocsLinkTheReceiverGuideTheSettingsRowOpens() throws {
        XCTAssertTrue(DiagnosticsShippingCopy.receiverGuideURL.hasSuffix("/docs/diagnostics-receiver.md"))
        XCTAssertTrue(try read("docs/diagnostics-shipping.md").contains("(diagnostics-receiver.md)"))
        XCTAssertTrue(DiagnosticsShippingCopy.noEndpoint.contains(DiagnosticsShippingCopy.receiverGuideTitle))
    }

    func testTheREADMEAndThePrivacyManifestMentionDiagnosticsShipping() throws {
        XCTAssertTrue(try read("README.md").contains("docs/diagnostics-shipping.md"))
        let manifest = try read("Muesli/PrivacyInfo.xcprivacy")
        XCTAssertTrue(manifest.contains("Diagnostics shipping"))
        XCTAssertTrue(manifest.contains("never sent to the developer"))
        // The keyboard extension never uploads, so its manifest needs no such note.
        XCTAssertFalse(try read("MuesliKeyboard/PrivacyInfo.xcprivacy").contains("Diagnostics shipping"))
    }
}
