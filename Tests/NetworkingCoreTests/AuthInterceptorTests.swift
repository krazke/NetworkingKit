import XCTest
@testable import NetworkingCore
import NetworkingTesting

final class AuthInterceptorTests: XCTestCase {

    func test_adapt_attachesBearerToken() async throws {
        let store = MockTokenStore(initial: AuthTokens(accessToken: "abc", refreshToken: "r"))
        let interceptor = AuthInterceptor(tokenStore: store) { _ in
            AuthTokens(accessToken: "new", refreshToken: "r2")
        }
        let req = URLRequest(url: URL(string: "https://example.com/x")!)
        let adapted = try await interceptor.adapt(req)
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    func test_retry_only401_only_firstAttempt() async {
        let store = MockTokenStore(initial: AuthTokens(accessToken: "abc", refreshToken: "r"))
        let interceptor = AuthInterceptor(tokenStore: store) { _ in
            AuthTokens(accessToken: "new", refreshToken: "r2")
        }
        let req = URLRequest(url: URL(string: "https://example.com/x")!)

        let resp401 = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)
        let resp500 = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)

        let d1 = await interceptor.retry(req, response: resp401,
                                         error: URLError(.userAuthenticationRequired), attempt: 1)
        if case .retry = d1 {
            // ok
        } else {
            XCTFail("Expected .retry on first 401")
        }

        let d2 = await interceptor.retry(req, response: resp500,
                                         error: URLError(.badServerResponse), attempt: 1)
        if case .doNotRetry = d2 {
            // ok
        } else {
            XCTFail("Expected .doNotRetry on 500")
        }

        // После refresh — token обновлён.
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1)
        let stored = await store.stored
        XCTAssertEqual(stored?.accessToken, "new")
    }
}
