import XCTest
@testable import AzureEngine

final class AzureMappingTests: XCTestCase {
    func testCredentialSplit() {
        XCTAssertEqual(AzureTranslateStream.split("northeurope|abc").region, "northeurope")
        XCTAssertEqual(AzureTranslateStream.split("northeurope|abc").key, "abc")
        XCTAssertEqual(AzureTranslateStream.split("abc").region, "westeurope", "bare key defaults to West Europe")
    }

    func testRecognizingIsDraftRecognizedClosesLines() {
        let draft = AzureTranslateStream.tokens(text: "Доброе", translation: "Good", final: false, language: "ru")
        XCTAssertEqual(draft.map(\.isFinal), [false, false])
        let fin = AzureTranslateStream.tokens(text: "Доброе утро.", translation: "Good morning.", final: true, language: "ru")
        XCTAssertEqual(fin.map(\.text), ["Доброе утро.", "<end>", "Good morning.", "<end>"])
        XCTAssertEqual(fin.map(\.translationStatus), ["original", "original", "translation", "translation"])
        XCTAssertTrue(AzureTranslateStream.tokens(text: " ", translation: "", final: true, language: "ru").isEmpty)
    }
}
