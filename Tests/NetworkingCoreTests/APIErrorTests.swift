import XCTest
@testable import NetworkingCore

/// `statusCode` and `responseBody` let an app decode its error envelope without matching each status case.
final class APIErrorTests: XCTestCase {

    private static let body = Data(#"{"error":"denied"}"#.utf8)

    func test_statusCases_exposeStatusAndBody() {
        let cases: [(APIError, Int)] = [
            (.unauthorized(data: Self.body), 401),
            (.forbidden(data: Self.body), 403),
            (.notFound(data: Self.body), 404),
            (.server(statusCode: 422, data: Self.body, message: "unprocessable"), 422),
        ]
        for (error, status) in cases {
            XCTAssertEqual(error.statusCode, status, "\(error)")
            XCTAssertEqual(error.responseBody, Self.body, "\(error)")
        }
    }

    func test_statusCasesWithoutBody_haveNilBody() {
        let cases: [APIError] = [
            .unauthorized(data: nil),
            .forbidden(data: nil),
            .notFound(data: nil),
            .server(statusCode: 500, data: nil, message: nil),
        ]
        for error in cases {
            XCTAssertNotNil(error.statusCode, "\(error)")
            XCTAssertNil(error.responseBody, "\(error)")
        }
    }

    func test_failuresWithoutStatus_haveNeitherStatusNorBody() {
        let cases: [APIError] = [
            .decoding(URLError(.cannotDecodeContentData)),
            .encoding(URLError(.cannotDecodeRawData)),
            .transport(URLError(.timedOut)),
            .invalidResponse,
            .cancelled,
            .unknown(URLError(.unknown)),
        ]
        for error in cases {
            XCTAssertNil(error.statusCode, "\(error)")
            XCTAssertNil(error.responseBody, "\(error)")
        }
    }

    /// The body stays out of `description`, which ends up in logs: it can be large or carry personal data.
    func test_description_omitsBody() {
        XCTAssertEqual(APIError.unauthorized(data: Self.body).description, "401 Unauthorized")
        XCTAssertEqual(APIError.forbidden(data: Self.body).description, "403 Forbidden")
        XCTAssertEqual(APIError.notFound(data: Self.body).description, "404 Not Found")
    }
}
