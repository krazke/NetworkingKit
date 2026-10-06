import XCTest
@testable import NetworkingCore
import NetworkingTesting

final class AuthInterceptorTests: XCTestCase {

    private let url = URL(string: "https://example.com/x")!
    private let initialTokens = AuthTokens(accessToken: "access-0", refreshToken: "refresh-0")

    private func request(bearer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func response(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private func isRetry(_ decision: RetryDecision) -> Bool {
        if case .retry = decision { return true }
        return false
    }

    func test_adapt_attachesBearerToken() async throws {
        let store = MockTokenStore(initial: initialTokens)
        let interceptor = AuthInterceptor(tokenStore: store) { _ in
            AuthTokens(accessToken: "new", refreshToken: "r2")
        }
        let adapted = try await interceptor.adapt(request(bearer: nil))
        XCTAssertEqual(adapted.value(forHTTPHeaderField: "Authorization"), "Bearer access-0")
    }

    func test_retry_ignoresNon401() async {
        let server = RotatingAuthServer()
        let interceptor = AuthInterceptor(tokenStore: MockTokenStore(initial: initialTokens)) {
            try await server.refresh($0)
        }

        let decision = await interceptor.retry(request(bearer: "access-0"), response: response(500),
                                               error: URLError(.badServerResponse), attempt: 1)

        XCTAssertFalse(isRetry(decision))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 0)
    }

    func test_401_refreshesSavesTokensAndRetries() async {
        let server = RotatingAuthServer()
        let store = MockTokenStore(initial: initialTokens)
        let interceptor = AuthInterceptor(tokenStore: store) { try await server.refresh($0) }

        let decision = await interceptor.retry(request(bearer: "access-0"), response: response(401),
                                               error: URLError(.userAuthenticationRequired), attempt: 1)

        XCTAssertTrue(isRetry(decision))
        let stored = await store.stored
        XCTAssertEqual(stored?.accessToken, "access-1")
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_concurrent401s_shareOneRefresh_withRotatingRefreshToken() async {
        let server = RotatingAuthServer()
        let store = SlowTokenStore(initial: initialTokens)
        let interceptor = AuthInterceptor(tokenStore: store) { try await server.refresh($0) }
        let failed = request(bearer: "access-0")
        let unauthorized = response(401)

        let decisions = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let decision = await interceptor.retry(failed, response: unauthorized,
                                                           error: URLError(.userAuthenticationRequired),
                                                           attempt: 1)
                    if case .retry = decision { return true }
                    return false
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }

        XCTAssertEqual(decisions, Array(repeating: true, count: 10))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
        let stored = await store.stored
        XCTAssertEqual(stored?.accessToken, "access-1")
    }

    func test_late401WithStaleToken_retriesWithoutRefreshing() async {
        let server = RotatingAuthServer()
        let store = MockTokenStore(initial: initialTokens)
        let interceptor = AuthInterceptor(tokenStore: store) { try await server.refresh($0) }

        _ = await interceptor.retry(request(bearer: "access-0"), response: response(401),
                                    error: URLError(.userAuthenticationRequired), attempt: 1)
        // A request that was sent with the old token fails after the refresh has finished.
        let late = await interceptor.retry(request(bearer: "access-0"), response: response(401),
                                           error: URLError(.userAuthenticationRequired), attempt: 1)

        XCTAssertTrue(isRetry(late))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_401AfterEarlierRetry_stillRefreshes() async {
        let server = RotatingAuthServer()
        let interceptor = AuthInterceptor(tokenStore: MockTokenStore(initial: initialTokens)) {
            try await server.refresh($0)
        }

        // Attempt 1 failed with a 503 and was retried by RetryInterceptor; attempt 2 gets a 401.
        let decision = await interceptor.retry(request(bearer: "access-0"), response: response(401),
                                               error: URLError(.userAuthenticationRequired), attempt: 2)

        XCTAssertTrue(isRetry(decision))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_401sWithFreshTokens_stopAtRefreshWindowLimit() async {
        let server = RotatingAuthServer()
        let store = MockTokenStore(initial: initialTokens)
        let interceptor = AuthInterceptor(tokenStore: store,
                                          refreshWindow: .init(interval: 60, maximumRefreshes: 2)) {
            try await server.refresh($0)
        }

        // The server rejects every token, including freshly refreshed ones.
        var decisions: [Bool] = []
        for _ in 0..<3 {
            let current = await store.stored?.accessToken
            let decision = await interceptor.retry(request(bearer: current), response: response(401),
                                                   error: URLError(.userAuthenticationRequired), attempt: 1)
            decisions.append(isRetry(decision))
        }

        XCTAssertEqual(decisions, [true, true, false])
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 2)
    }

    func test_refreshFailure_doesNotRetry() async {
        let interceptor = AuthInterceptor(tokenStore: MockTokenStore(initial: initialTokens)) { _ in
            throw URLError(.userAuthenticationRequired)
        }

        let decision = await interceptor.retry(request(bearer: "access-0"), response: response(401),
                                               error: URLError(.userAuthenticationRequired), attempt: 1)

        XCTAssertFalse(isRetry(decision))
    }

    func test_noStoredTokens_doesNotRetry() async {
        let server = RotatingAuthServer()
        let interceptor = AuthInterceptor(tokenStore: MockTokenStore()) { try await server.refresh($0) }

        let decision = await interceptor.retry(request(bearer: nil), response: response(401),
                                               error: URLError(.userAuthenticationRequired), attempt: 1)

        XCTAssertFalse(isRetry(decision))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 0)
    }
}

/// Token store whose reads suspend for a while, like a Keychain-backed store.
/// Widens the window in which concurrent 401s interleave inside `AuthInterceptor`.
private actor SlowTokenStore: TokenStore {
    private(set) var stored: AuthTokens?

    init(initial: AuthTokens?) { stored = initial }

    func current() async -> AuthTokens? {
        try? await Task.sleep(for: .milliseconds(5))
        return stored
    }

    func save(_ tokens: AuthTokens) async { stored = tokens }
    func clear() async { stored = nil }
}
