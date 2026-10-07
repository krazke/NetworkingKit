import XCTest
@testable import NetworkingCore

final class InterceptorsTests: XCTestCase {

    // HeadersInterceptor

    func test_headersInterceptor_appliesGlobals() async throws {
        let i = HeadersInterceptor(globalHeaders: ["X-App": "ios"],
                                   dynamicHeaders: { ["X-Locale": "en"] })
        let req = URLRequest(url: URL(string: "https://example.com")!)
        let adapted = try await i.adapt(req)
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "X-App"), "ios")
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "X-Locale"), "en")
    }

    func test_headersInterceptor_doesNotOverwriteExisting() async throws {
        let i = HeadersInterceptor(globalHeaders: ["X-App": "ios"], dynamicHeaders: { [:] })
        var req = URLRequest(url: URL(string: "https://example.com")!)
        req.setValue("custom", forHTTPHeaderField: "X-App")
        let adapted = try await i.adapt(req)
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "X-App"), "custom")
    }

    func test_headersInterceptor_dynamicOverridesGlobal() async throws {
        let i = HeadersInterceptor(globalHeaders: ["X-Locale": "en"],
                                   dynamicHeaders: { ["X-Locale": "ru"] })
        let req = URLRequest(url: URL(string: "https://example.com")!)
        let adapted = try await i.adapt(req)
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "X-Locale"), "ru")
    }

    // RetryInterceptor

    func test_retryInterceptor_doesNotRetryAfterLimit() async {
        let r = RetryInterceptor(configuration: RetryConfiguration(limit: 3))
        let req = URLRequest(url: URL(string: "https://example.com")!)
        let resp = HTTPURLResponse(url: req.url!, statusCode: 503,
                                    httpVersion: nil, headerFields: nil)
        let decision = await r.retry(req, response: resp,
                                     error: URLError(.timedOut), attempt: 3)
        if case .doNotRetry = decision { return }
        XCTFail("Expected .doNotRetry on attempt == limit, got \(decision)")
    }

    func test_retryInterceptor_limitCountsTotalAttempts() async {
        let req = URLRequest(url: URL(string: "https://example.com")!)
        let resp = HTTPURLResponse(url: req.url!, statusCode: 503,
                                   httpVersion: nil, headerFields: nil)
        let cases: [(limit: Int, retriedAttempts: [Int])] = [(0, []), (1, []), (2, [1]), (3, [1, 2])]
        for (limit, expected) in cases {
            let r = RetryInterceptor(configuration: RetryConfiguration(limit: limit, jitter: 1.0...1.0))
            var retried: [Int] = []
            for attempt in 1...4 {
                let decision = await r.retry(req, response: resp,
                                             error: URLError(.timedOut), attempt: attempt)
                if case .doNotRetry = decision { continue }
                retried.append(attempt)
            }
            XCTAssertEqual(retried, expected, "limit \(limit)")
        }
    }

    func test_retryInterceptor_retriesOn503() async {
        let r = RetryInterceptor(configuration: RetryConfiguration(limit: 3,
                                                                   baseDelay: 0.01,
                                                                   maxDelay: 1,
                                                                   jitter: 1.0...1.0))
        var req = URLRequest(url: URL(string: "https://example.com")!)
        req.httpMethod = "GET"
        let resp = HTTPURLResponse(url: req.url!, statusCode: 503,
                                    httpVersion: nil, headerFields: nil)
        let decision = await r.retry(req, response: resp,
                                     error: URLError(.timedOut), attempt: 1)
        if case .retryAfter(let d) = decision {
            XCTAssertEqual(d, 0.01, accuracy: 0.001)
            return
        }
        XCTFail("Expected .retryAfter on 503, got \(decision)")
    }

    func test_retryInterceptor_doesNotRetryNonIdempotentMethods() async {
        let r = RetryInterceptor(configuration: RetryConfiguration())
        var req = URLRequest(url: URL(string: "https://example.com")!)
        req.httpMethod = "POST"
        let resp = HTTPURLResponse(url: req.url!, statusCode: 503,
                                    httpVersion: nil, headerFields: nil)
        let decision = await r.retry(req, response: resp,
                                     error: URLError(.timedOut), attempt: 1)
        if case .doNotRetry = decision { return }
        XCTFail("Expected .doNotRetry for POST")
    }

    // CompositeInterceptor

    func test_compositeInterceptor_chainsAdapt() async throws {
        let h1 = HeadersInterceptor(globalHeaders: ["A": "1"], dynamicHeaders: { [:] })
        let h2 = HeadersInterceptor(globalHeaders: ["B": "2"], dynamicHeaders: { [:] })
        let composite = CompositeInterceptor([h1, h2])
        let req = URLRequest(url: URL(string: "https://example.com")!)
        let adapted = try await composite.adapt(req)
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "A"), "1")
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "B"), "2")
    }
}
