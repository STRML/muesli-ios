import XCTest
@testable import Muesli

/// The Custom LLM model picker asks the server which models it serves, so Settings can offer a dropdown
/// instead of a free-text field. Same behaviour as the Mac app.
final class CustomLLMModelCatalogTests: XCTestCase {
    private static func response(_ status: Int, _ body: String, url: String = "https://x/v1/models") -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: models URL

    func testTheModelsURLSitsNextToTheChatEndpointForEveryFormOfTheAddress() {
        let expected = URL(string: "https://host.ts.net/v1/models")
        XCTAssertEqual(CustomLLMModelCatalog.modelsURL(from: "https://host.ts.net/v1"), expected)
        XCTAssertEqual(CustomLLMModelCatalog.modelsURL(from: "https://host.ts.net/v1/"), expected)
        XCTAssertEqual(CustomLLMModelCatalog.modelsURL(from: "  https://host.ts.net/v1/chat/completions  "), expected)
    }

    func testAnAddressWithoutAV1PathListsFromItsRoot() {
        XCTAssertEqual(
            CustomLLMModelCatalog.modelsURL(from: "https://host.ts.net"),
            URL(string: "https://host.ts.net/models")
        )
    }

    func testAnUnusableAddressHasNoModelsURL() {
        XCTAssertNil(CustomLLMModelCatalog.modelsURL(from: ""))
        XCTAssertNil(CustomLLMModelCatalog.modelsURL(from: "http://host.ts.net/v1"), "plain http is refused")
    }

    // MARK: parsing

    func testOpenAIShapeListsTheIDs() throws {
        let ids = try CustomLLMModelCatalog.parseModelIDs(
            from: Data(#"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#.utf8))
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testOllamaShapeListsTheNames() throws {
        let ids = try CustomLLMModelCatalog.parseModelIDs(
            from: Data(#"{"models":[{"name":"llama3:8b"},{"model":"qwen"}]}"#.utf8))
        XCTAssertEqual(ids, ["llama3:8b", "qwen"])
    }

    func testABareArrayAndDuplicatesAndBlanksAreHandled() throws {
        XCTAssertEqual(
            try CustomLLMModelCatalog.parseModelIDs(from: Data(#"["a","a"," ","b"]"#.utf8)),
            ["a", "b"]
        )
    }

    func testAnEmptyListIsAnErrorNotAnEmptyPicker() {
        XCTAssertThrowsError(try CustomLLMModelCatalog.parseModelIDs(from: Data(#"{"data":[]}"#.utf8))) {
            XCTAssertEqual($0 as? CustomLLMModelCatalogError, .noModels)
        }
    }

    func testSomethingThatIsNotAModelListIsUnreadable() {
        XCTAssertThrowsError(try CustomLLMModelCatalog.parseModelIDs(from: Data("<html>".utf8))) {
            XCTAssertEqual($0 as? CustomLLMModelCatalogError, .unreadable)
        }
        XCTAssertThrowsError(try CustomLLMModelCatalog.parseModelIDs(from: Data(#"{"error":"x"}"#.utf8))) {
            XCTAssertEqual($0 as? CustomLLMModelCatalogError, .unreadable)
        }
    }

    // MARK: fetching

    func testFetchSendsTheKeyAsABearerTokenToTheModelsURL() async throws {
        let seen = Box<URLRequest?>(nil)
        let ids = try await CustomLLMModelCatalog.fetch(baseURL: "https://x/v1", apiKey: " sk-1 ") { request in
            seen.value = request
            return Self.response(200, #"{"data":[{"id":"m"}]}"#)
        }
        XCTAssertEqual(ids, ["m"])
        XCTAssertEqual(seen.value?.url, URL(string: "https://x/v1/models"))
        XCTAssertEqual(seen.value?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        XCTAssertEqual(seen.value?.httpMethod, "GET")
    }

    func testFetchSendsNoAuthorizationWhenThereIsNoKey() async throws {
        let seen = Box<URLRequest?>(nil)
        _ = try await CustomLLMModelCatalog.fetch(baseURL: "https://x/v1", apiKey: "") { request in
            seen.value = request
            return Self.response(200, #"{"data":[{"id":"m"}]}"#)
        }
        XCTAssertNil(seen.value?.value(forHTTPHeaderField: "Authorization"))
    }

    func testARefusedKeyIsReportedAsSuch() async {
        for status in [401, 403] {
            do {
                _ = try await CustomLLMModelCatalog.fetch(baseURL: "https://x/v1", apiKey: "k") { _ in
                    Self.response(status, "")
                }
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? CustomLLMModelCatalogError, .unauthorized)
            }
        }
    }

    func testOtherStatusesAndTransportFailuresAreReported() async {
        do {
            _ = try await CustomLLMModelCatalog.fetch(baseURL: "https://x/v1", apiKey: "") { _ in Self.response(500, "") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CustomLLMModelCatalogError, .http(500))
        }
        do {
            _ = try await CustomLLMModelCatalog.fetch(baseURL: "https://x/v1", apiKey: "") { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("expected an error")
        } catch {
            guard case .unreachable = error as? CustomLLMModelCatalogError else { return XCTFail("\(error)") }
        }
    }

    func testAnInvalidAddressFailsBeforeAnyRequest() async {
        let called = Box(false)
        do {
            _ = try await CustomLLMModelCatalog.fetch(baseURL: "not a url", apiKey: "") { _ in
                called.value = true
                return Self.response(200, "{}")
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CustomLLMModelCatalogError, .invalidEndpoint)
        }
        XCTAssertFalse(called.value)
    }

    // MARK: picker content

    func testThePickerKeepsAModelTheServerNoLongerListsSoItIsNeverSilentlyReplaced() {
        XCTAssertEqual(
            CustomLLMModelCatalog.pickerChoices(listed: ["a", "b"], current: "old"),
            ["old", "a", "b"]
        )
        XCTAssertEqual(CustomLLMModelCatalog.pickerChoices(listed: ["a", "b"], current: "b"), ["a", "b"])
        XCTAssertEqual(CustomLLMModelCatalog.pickerChoices(listed: ["a"], current: " "), ["a"])
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
