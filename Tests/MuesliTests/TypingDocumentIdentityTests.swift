import XCTest
@testable import Muesli

/// A proxy whose document identifier is nil, as the host's is early in a keyboard's startup. The Objective-C
/// getter is `documentIdentifier`, like UITextDocumentProxy's, but nullable here so it can return nil.
private final class NoDocumentYetProxy: NSObject {
    @objc(documentIdentifier) var identifier: NSUUID? { nil }
}

private final class DocumentProxy: NSObject {
    let value = UUID()
    @objc(documentIdentifier) var identifier: NSUUID? { value as NSUUID }
}

private final class ProxyWithoutIdentifier: NSObject {}

final class TypingDocumentIdentityTests: XCTestCase {
    func testANilIdentifierReadsAsNilInsteadOfTrapping() {
        XCTAssertNil(TypingDocumentIdentity.read(from: NoDocumentYetProxy()))
    }

    func testARealIdentifierIsReturned() {
        let proxy = DocumentProxy()
        XCTAssertEqual(TypingDocumentIdentity.read(from: proxy), proxy.value)
    }

    func testAnObjectWithoutTheGetterReadsAsNil() {
        XCTAssertNil(TypingDocumentIdentity.read(from: ProxyWithoutIdentifier()))
    }
}
