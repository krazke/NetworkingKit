import XCTest
@testable import NetworkingURLSession
import NetworkingCore

private struct VoidEndpoint: APIEndpoint {
    var path: String { "/void" }
    var method: HTTPMethod { .get }
}

/// Asks to retry the first failed attempt after `delay`, and no later one.
private struct FixedDelayInterceptor: RequestInterceptor {
    let delay: TimeInterval

    func retry(_ request: URLRequest,
               response: HTTPURLResponse?,
               error: any Error & Sendable,
               attempt: Int) async -> RetryDecision {
        attempt == 1 ? .retryAfter(delay) : .doNotRetry
    }
}

/// How the real URLSession transport carries out a `.retryAfter(_:)` delay it cannot wait for as is.
/// `AlamofireRetryDelayTests` checks the same behavior for the Alamofire transport.
final class URLSessionRetryDelayTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // The first request gets 500, every later one 204.
        StubProtocol.reset { _ in
            StubProtocol.recordedRequests.count == 1
                ? .init(statusCode: 500, data: Data(), headers: [:], delay: 0)
                : .init(statusCode: 204, data: Data(), headers: [:], delay: 0)
        }
    }

    /// Sends one request and returns its outcome, or `nil` when it has not finished within 5 s.
    private func send(retry: RetryConfiguration = .none,
                      interceptors: [any RequestInterceptor]) async -> Result<Void, any Error>? {
        let config = NetworkConfiguration(baseURL: URL(string: "https://api.test")!,
                                          sessionConfiguration: .stubbed,
                                          retry: retry,
                                          additionalInterceptors: interceptors)
        let client = URLSessionAPIClient(configuration: config)
        let task = Task { try await client.sendVoid(VoidEndpoint()) }
        let outcome = await task.result(timeout: .seconds(5))
        task.cancel()
        return outcome
    }

    private func assertFailsWithoutRetry(_ outcome: Result<Void, any Error>?,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        switch outcome {
        case .failure(APIError.server(let statusCode, _, _))?:
            XCTAssertEqual(statusCode, 500, file: file, line: line)
        case nil:
            XCTFail("Expected APIError.server(500); the request is still waiting to retry", file: file, line: line)
        default:
            XCTFail("Expected APIError.server(500), got \(String(describing: outcome))", file: file, line: line)
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1, file: file, line: line)
    }

    private func assertRetriedAtOnce(_ outcome: Result<Void, any Error>?,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        switch outcome {
        case .success?:
            break
        case nil:
            XCTFail("Expected success; the request is still waiting to retry", file: file, line: line)
        case .failure(let error)?:
            XCTFail("Unexpected: \(error)", file: file, line: line)
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 2, file: file, line: line)
    }

    func test_nanDelay_failsWithoutRetrying() async {
        assertFailsWithoutRetry(await send(interceptors: [FixedDelayInterceptor(delay: .nan)]))
    }

    func test_infiniteDelay_failsWithoutRetrying() async {
        assertFailsWithoutRetry(await send(interceptors: [FixedDelayInterceptor(delay: .infinity)]))
    }

    func test_negativeInfiniteDelay_failsWithoutRetrying() async {
        assertFailsWithoutRetry(await send(interceptors: [FixedDelayInterceptor(delay: -.infinity)]))
    }

    func test_delayAboveLongestRetryDelay_failsWithoutRetrying() async {
        // About 317 years, just above `RetryDecision.longestDelay`.
        assertFailsWithoutRetry(await send(interceptors: [FixedDelayInterceptor(delay: 1e10)]))
    }

    func test_delayTooLargeForDuration_failsWithoutRetrying() async {
        assertFailsWithoutRetry(await send(interceptors: [FixedDelayInterceptor(delay: 1e19)]))
    }

    func test_negativeDelay_retriesAtOnce() async {
        assertRetriedAtOnce(await send(interceptors: [FixedDelayInterceptor(delay: -1)]))
    }

    func test_negativeDelayTooLargeForDuration_retriesAtOnce() async {
        assertRetriedAtOnce(await send(interceptors: [FixedDelayInterceptor(delay: -1e19)]))
    }

    func test_zeroDelay_retriesAtOnce() async {
        assertRetriedAtOnce(await send(interceptors: [FixedDelayInterceptor(delay: 0)]))
    }

    func test_retryAfterAboveLongestRetryDelay_withUnlimitedMaxDelay_failsWithoutRetrying() async {
        // `RetryInterceptor` passes on any finite `Retry-After` up to `maxDelay`.
        StubProtocol.reset { _ in
            StubProtocol.recordedRequests.count == 1
                ? .init(statusCode: 503, data: Data(), headers: ["Retry-After": "99999999999999999999"], delay: 0)
                : .init(statusCode: 204, data: Data(), headers: [:], delay: 0)
        }
        let retry = RetryConfiguration(limit: 2, baseDelay: 0.001, maxDelay: .infinity, jitter: 1.0...1.0)
        let outcome = await send(retry: retry, interceptors: [])

        switch outcome {
        case .failure(APIError.server(let statusCode, _, _))?:
            XCTAssertEqual(statusCode, 503)
        default:
            XCTFail("Expected APIError.server(503), got \(String(describing: outcome))")
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
    }
}
