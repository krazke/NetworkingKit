import XCTest
@testable import NetworkingCore

final class RequestBodyEncodingTests: XCTestCase {

    private func encoded(_ fields: [String: String]) -> String {
        String(decoding: FormURLEncoding.encode(fields), as: UTF8.self)
    }

    func test_formURLEncoding_escapesReservedCharacters() {
        XCTAssertEqual(encoded(["a b": "1+2&3=4%"]), "a+b=1%2B2%263%3D4%25")
        XCTAssertEqual(encoded(["k": "*-._~!'()/?"]), "k=*-._%7E%21%27%28%29%2F%3F")
        XCTAssertEqual(encoded(["é": "✓"]), "%C3%A9=%E2%9C%93")
        XCTAssertEqual(encoded(["empty": ""]), "empty=")
    }

    func test_formURLEncoding_sortsFieldsByName() {
        XCTAssertEqual(encoded(["b": "2", "a": "1", "c": "3"]), "a=1&b=2&c=3")
        XCTAssertEqual(encoded([:]), "")
    }

    func test_multipartDisposition_normalizesLineBreaksInNamesThenEscapes() {
        XCTAssertEqual(MultipartDisposition.escapeName("a\"b\nc\rd\r\ne"), "a%22b%0D%0Ac%0D%0Ad%0D%0Ae")
        XCTAssertEqual(MultipartDisposition.escapeName("\r\r\n\n"), "%0D%0A%0D%0A%0D%0A")
        XCTAssertEqual(MultipartDisposition.escapeName("100% ok"), "100% ok")
    }

    func test_multipartDisposition_escapesFilenamesWithoutNormalizing() {
        XCTAssertEqual(MultipartDisposition.escapeFilename("a\"b\nc\rd\r\ne.txt"), "a%22b%0Ac%0Dd%0D%0Ae.txt")
        XCTAssertEqual(MultipartDisposition.escapeFilename("фото 1%.jpg"), "фото 1%.jpg")
    }
}
