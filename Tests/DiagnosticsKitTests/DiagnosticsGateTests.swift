import XCTest
@testable import DiagnosticsKit

/// Diagnostics leave the phone only when the toggle is on, an endpoint is set, and a public-looking endpoint has been
/// acknowledged for that exact host.
final class DiagnosticsGateTests: XCTestCase {
    private let studio = "studio.tail13013.ts.net"

    func testToggleOffBlocksEvenWithAPrivateEndpoint() {
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: false, endpointHost: studio, endpointLooksPrivate: true, acknowledgedHost: nil),
            .blocked(.toggleOff)
        )
    }

    func testNoEndpointBlocks() {
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: true, endpointHost: nil, endpointLooksPrivate: true, acknowledgedHost: nil),
            .blocked(.noEndpoint)
        )
    }

    func testAPrivateEndpointNeedsNoAcknowledgement() {
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: true, endpointHost: studio, endpointLooksPrivate: true, acknowledgedHost: nil),
            .allowed
        )
    }

    func testAPublicLookingEndpointIsBlockedUntilAcknowledged() {
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: true, endpointHost: "logs.example.com", endpointLooksPrivate: false, acknowledgedHost: nil),
            .blocked(.publicEndpointNotAcknowledged)
        )
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: true, endpointHost: "logs.example.com", endpointLooksPrivate: false, acknowledgedHost: "logs.example.com"),
            .allowed
        )
    }

    func testAcknowledgingOneHostDoesNotCoverAnother() {
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: true, endpointHost: "other.example.com", endpointLooksPrivate: false, acknowledgedHost: "logs.example.com"),
            .blocked(.publicEndpointNotAcknowledged)
        )
    }

    func testHostComparisonIgnoresCase() {
        XCTAssertEqual(
            DiagnosticsGate.decide(enabled: true, endpointHost: "Logs.Example.com", endpointLooksPrivate: false, acknowledgedHost: "logs.example.COM"),
            .allowed
        )
    }
}
