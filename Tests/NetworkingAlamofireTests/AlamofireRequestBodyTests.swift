import XCTest
@testable import NetworkingAlamofire
import NetworkingCore
import NetworkingTesting

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct FormEndpoint: APIEndpoint {
    let fields: [String: String]
    var path: String { "/form" }
    var method: HTTPMethod { .post }
    var body: RequestBody { .urlEncoded(fields) }
}

private struct MultipartEndpoint: APIEndpoint {
    let parts: [MultipartPart]
    var path: String { "/files" }
    var method: HTTPMethod { .post }
    var body: RequestBody { .multipart(parts) }
}

/// Values that `URLComponents.percentEncodedQuery` used to garble or that need escaping.
private let reservedFields: [String: String] = [
    "plus": "a+b",
    "amp&name": "x&y",
    "equals": "k=v",
    "percent": "100%",
    "space": "a b",
    "unicode": "привет ✓ 🐎",
    "mixed +&=%": "+&=% ~*-._",
    "empty": "",
]

/// Request bodies as they reach the server, checked through the real Alamofire transport.
final class AlamofireRequestBodyTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset { _ in
            .init(statusCode: 200, data: Data(#"{"value":"ok"}"#.utf8),
                  headers: ["Content-Type": "application/json"], delay: 0)
        }
    }

    /// Retries idempotent methods with a negligible delay.
    private static let fastRetry = RetryConfiguration(limit: 3, baseDelay: 0.001, maxDelay: 0.01, jitter: 1.0...1.0)

    private func makeClient(retry: RetryConfiguration = .none) -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: retry
        )
        return AlamofireAPIClient(configuration: config)
    }

    private var sentBody: String? {
        StubProtocol.recordedBodies.last.flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    func test_urlEncodedBody_roundTripsReservedCharacters() async throws {
        try await makeClient().sendVoid(FormEndpoint(fields: reservedFields))

        let body = try XCTUnwrap(sentBody)
        XCTAssertEqual(try FormBody.parse(body), reservedFields, body)
        XCTAssertEqual(StubProtocol.recordedRequests.last?.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded; charset=utf-8")
    }

    func test_multipartUpload_escapesQuotesAndLineBreaksInContentDisposition() async throws {
        let parts: [MultipartPart] = [
            .data(Data("payload".utf8), name: "fi\"le\r\nX-Injected: 1",
                  filename: "a\"b\nc\rd.txt", mimeType: "text/plain"),
            .data(Data("value".utf8), name: "fie\"ld\nX-Injected: 2"),
        ]
        _ = try await makeClient().upload(MultipartEndpoint(parts: parts), as: Echo.self)

        let lines = try XCTUnwrap(sentBody).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("Content-Disposition:") }, [
            #"Content-Disposition: form-data; name="fi%22le%0D%0AX-Injected: 1"; filename="a%22b%0Ac%0Dd.txt""#,
            #"Content-Disposition: form-data; name="fie%22ld%0D%0AX-Injected: 2""#,
        ])
        XCTAssertFalse(lines.contains { $0.hasPrefix("X-Injected") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("payload"))
        XCTAssertTrue(lines.contains("value"))
    }

    // MARK: - Retry

    private static let payload: [MultipartPart] = [.data(Data("payload".utf8), name: "file",
                                                           filename: "file.txt", mimeType: "text/plain")]

    func test_multipartUpload_retryable503_isNotRetriedForPost() async throws {
        StubProtocol.reset { _ in .init(statusCode: 503, data: Data(), headers: [:], delay: 0) }
        let bodiesBefore = try TemporaryFiles.multipartBodies()

        do {
            _ = try await makeClient(retry: Self.fastRetry).upload(MultipartEndpoint(parts: Self.payload),
                                                                  as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.server(let statusCode, _, _) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
        XCTAssertEqual(try TemporaryFiles.multipartBodies(), bodiesBefore)
    }

    func test_multipartUpload_retryablePost_resendsTheSameBody() async throws {
        let attempts = LockedCounter()
        StubProtocol.reset { _ in
            attempts.increment() == 1
                ? .init(statusCode: 503, data: Data(), headers: [:], delay: 0)
                : .init(statusCode: 200, data: Data(#"{"value":"ok"}"#.utf8),
                        headers: ["Content-Type": "application/json"], delay: 0)
        }
        var retry = Self.fastRetry
        retry.retryableMethods = [.post]
        let bodiesBefore = try TemporaryFiles.multipartBodies()

        let result = try await makeClient(retry: retry).upload(MultipartEndpoint(parts: Self.payload),
                                                               as: Echo.self)

        XCTAssertEqual(result, Echo(value: "ok"))
        let bodies = StubProtocol.recordedBodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        XCTAssertTrue(String(decoding: try XCTUnwrap(bodies.last ?? nil), as: UTF8.self).contains("payload"))
        XCTAssertEqual(try TemporaryFiles.multipartBodies(), bodiesBefore)
    }

    func test_multipartUpload_cancellationDuringRetryDelay_throwsCancelled() async throws {
        StubProtocol.reset { _ in .init(statusCode: 503, data: Data(), headers: [:], delay: 0) }
        var retry = RetryConfiguration(limit: 3, baseDelay: 30, maxDelay: 30, jitter: 1.0...1.0)
        retry.retryableMethods = [.post]
        let client = makeClient(retry: retry)
        let bodiesBefore = try TemporaryFiles.multipartBodies()

        let task = Task { try await client.upload(MultipartEndpoint(parts: Self.payload), as: Echo.self) }
        try await StubProtocol.waitForRequests(1)
        // Lets the transport receive the 503 and start waiting out the 30-second delay.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let outcome = await task.result(timeout: .seconds(5))

        XCTExpectFailure(KnownIssue.cancellationDuringRetryDelayThrowsLastError) {
            XCTAssertCancelled(outcome)
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
        XCTAssertEqual(try TemporaryFiles.multipartBodies(), bodiesBefore)
    }
}

/// Parses an `application/x-www-form-urlencoded` body the way a server does.
enum FormBody {
    struct DuplicateName: Error { let name: String }

    static func parse(_ body: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let nameAndValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decode(nameAndValue[0])
            guard result[name] == nil else { throw DuplicateName(name: name) }
            result[name] = nameAndValue.count > 1 ? decode(nameAndValue[1]) : ""
        }
        return result
    }

    private static func decode(_ component: Substring) -> String {
        component.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "<invalid>"
    }
}
