import XCTest
@testable import NetworkingCore

final class HTTPHeadersTests: XCTestCase {
    func test_set_overrides() {
        var h: HTTPHeaders = ["A": "1"]
        h.set("A", "2")
        XCTAssertEqual(h["A"], "2")
    }

    func test_append_combines() {
        var h: HTTPHeaders = ["Cookie": "a=1"]
        h.append("Cookie", "b=2")
        XCTAssertEqual(h["Cookie"], "a=1, b=2")
    }

    func test_remove() {
        var h: HTTPHeaders = ["A": "1", "B": "2"]
        h.remove("A")
        XCTAssertNil(h["A"])
        XCTAssertEqual(h["B"], "2")
    }

    func test_merging_other_wins() {
        let a: HTTPHeaders = ["A": "1", "B": "2"]
        let b: HTTPHeaders = ["B": "X", "C": "3"]
        let merged = a.merging(b)
        XCTAssertEqual(merged["A"], "1")
        XCTAssertEqual(merged["B"], "X")
        XCTAssertEqual(merged["C"], "3")
    }
}
