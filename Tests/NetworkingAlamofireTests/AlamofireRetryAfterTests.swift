import XCTest
@testable import NetworkingAlamofire
import NetworkingCore

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct EchoEndpoint: APIEndpoint {
    var path: String { "/echo" }
    var method: HTTPMethod { .get }
}

/// `Retry-After` handling through the real Alamofire transport.
/// `URLSessionRetryAfterTests` checks the same behavior for the URLSession transport.
final class AlamofireRetryAfterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    private func makeClient(baseDelay: TimeInterval) -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: RetryConfiguration(limit: 3, baseDelay: baseDelay, maxDelay: 30, jitter: 1.0...1.0)
        )
        return AlamofireAPIClient(configuration: config)
    }

    /// The first request gets `status` with `headers`; every later one gets 200.
    private static func stubFailureThenSuccess(status: Int, headers: [String: String]) {
        StubProtocol.reset { _ in
            if StubProtocol.recordedRequests.count == 1 {
                return .init(statusCode: status, data: Data(), headers: headers, delay: 0)
            }
            return .init(statusCode: 200, data: Data(#"{"value":"ok"}"#.utf8),
                         headers: ["Content-Type": "application/json"], delay: 0)
        }
    }

    private func assertFailsWithoutRetry(status: Int,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) async {
        let client = makeClient(baseDelay: 0.001)
        do {
            let echo = try await client.send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected APIError.server(\(status)), got \(echo)", file: file, line: line)
        } catch APIError.server(let statusCode, _, _) {
            XCTAssertEqual(statusCode, status, file: file, line: line)
        } catch {
            XCTFail("Unexpected: \(error)", file: file, line: line)
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1, file: file, line: line)
    }

    func test_retryAfterAboveMaxDelay_failsWithoutRetrying() async {
        Self.stubFailureThenSuccess(status: 429, headers: ["Retry-After": "60"])
        await assertFailsWithoutRetry(status: 429)
    }

    func test_retryAfterDate_isMeasuredFromServerDateHeader() async {
        // 60 s after the server's `Date`, although long past by the local clock.
        Self.stubFailureThenSuccess(status: 503, headers: ["Date": "Sun, 06 Nov 1994 08:49:37 GMT",
                                                           "Retry-After": "Sun, 06 Nov 1994 08:50:37 GMT"])
        await assertFailsWithoutRetry(status: 503)
    }

    func test_retryAfterZero_retriesWithoutBackoff() async {
        Self.stubFailureThenSuccess(status: 503, headers: ["Retry-After": "0"])
        // Backoff alone would wait 30 s before the second attempt.
        let client = makeClient(baseDelay: 30)
        let task = Task { try await client.send(EchoEndpoint(), as: Echo.self) }
        let outcome = await task.result(timeout: .seconds(5))
        task.cancel()

        switch outcome {
        case .success(let echo)?:
            XCTAssertEqual(echo, Echo(value: "ok"))
        case nil:
            XCTFail("The retry waited for backoff instead of Retry-After: 0")
        case .failure(let error)?:
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 2)
    }
}
