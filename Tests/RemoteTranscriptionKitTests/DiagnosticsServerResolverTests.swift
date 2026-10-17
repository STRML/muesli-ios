import XCTest
@testable import RemoteTranscriptionKit

/// Where diagnostics are posted: the Diagnostics server field when it is filled in, otherwise the AI Summaries
/// server. The settings screen and the uploader both call this one function, so they cannot disagree.
final class DiagnosticsServerResolverTests: XCTestCase {
    private let summaries = "https://studio.tail13013.ts.net/v1"

    func testAnEmptyOverrideFallsBackToTheAISummariesServer() throws {
        for blank in ["", "   ", "\n"] {
            let resolved = try XCTUnwrap(DiagnosticsServerResolver.resolve(override: blank, aiSummariesBaseURL: summaries).server)
            XCTAssertEqual(resolved.url.absoluteString, "https://studio.tail13013.ts.net/v1/diagnostics")
            XCTAssertEqual(resolved.source, .aiSummaries)
        }
    }

    func testTheOverrideWinsOverTheAISummariesServer() throws {
        let resolved = try XCTUnwrap(
            DiagnosticsServerResolver.resolve(override: "https://logs.home.ts.net/v1", aiSummariesBaseURL: summaries).server
        )
        XCTAssertEqual(resolved.url.absoluteString, "https://logs.home.ts.net/v1/diagnostics")
        XCTAssertEqual(resolved.host, "logs.home.ts.net")
        XCTAssertEqual(resolved.source, .ownField)
    }

    func testTheOverrideWorksWithNoAISummariesServerAtAll() throws {
        let resolved = try XCTUnwrap(DiagnosticsServerResolver.resolve(override: "https://logs.home.ts.net/v1", aiSummariesBaseURL: "").server)
        XCTAssertEqual(resolved.source, .ownField)
    }

    func testEveryFormOfTheOverrideNormalisesToOneURL() {
        for address in [
            "https://logs.home.ts.net/v1",
            "  https://logs.home.ts.net/v1/  ",
            "https://logs.home.ts.net/v1/diagnostics",
            "https://logs.home.ts.net/v1/chat/completions",
        ] {
            XCTAssertEqual(
                DiagnosticsServerResolver.resolve(override: address, aiSummariesBaseURL: "").server?.url.absoluteString,
                "https://logs.home.ts.net/v1/diagnostics",
                address
            )
        }
    }

    func testABadOverrideIsNeverReplacedByTheAISummariesServer() {
        for bad in ["http://logs.home.ts.net/v1", "logs.home.ts.net/v1", "https://", "ftp://logs.home.ts.net"] {
            let resolution = DiagnosticsServerResolver.resolve(override: bad, aiSummariesBaseURL: summaries)
            XCTAssertNil(resolution.server, bad)
            XCTAssertEqual(resolution, .invalidOverride, bad)
        }
    }

    func testNothingSetResolvesToNothing() {
        XCTAssertEqual(DiagnosticsServerResolver.resolve(override: "", aiSummariesBaseURL: ""), .none)
        XCTAssertEqual(DiagnosticsServerResolver.resolve(override: "", aiSummariesBaseURL: "http://studio.tail13013.ts.net/v1"), .none)
    }

    func testAPublicHostIsNotPrivateAndAPrivateOneIs() throws {
        let publicHost = try XCTUnwrap(DiagnosticsServerResolver.resolve(override: "https://logs.example.com/v1", aiSummariesBaseURL: summaries).server)
        XCTAssertFalse(publicHost.looksPrivate)
        let tailnet = try XCTUnwrap(DiagnosticsServerResolver.resolve(override: "https://100.101.102.103/v1", aiSummariesBaseURL: "").server)
        XCTAssertTrue(tailnet.looksPrivate)
        // The warning follows the address that is used, not the AI Summaries one.
        let fallback = try XCTUnwrap(DiagnosticsServerResolver.resolve(override: "", aiSummariesBaseURL: "https://logs.example.com/v1").server)
        XCTAssertFalse(fallback.looksPrivate)
    }
}
