import Foundation

/// OAuth bearer authentication with refresh on 401.
///
/// `adapt` attaches `Authorization: Bearer <accessToken>` from the `TokenStore`.
/// On a 401, `retry` refreshes the tokens through `refresh`, saves them and asks
/// the transport to retry, which re-runs `adapt` with the new token. The refresh
/// request itself is supplied by the app, so the package does not dictate the
/// refresh endpoint's format.
///
/// Guarantees:
/// - Concurrent 401s share one in-flight refresh, so a rotating (single-use)
///   refresh token is consumed exactly once.
/// - A 401 for a request that carried a different access token than the stored
///   one is retried without refreshing: another request already refreshed.
/// - Refresh does not depend on the attempt number, so a 401 that follows a
///   retried 503 still refreshes.
/// - Refreshes are rate-limited by `refreshWindow`. When the server keeps
///   rejecting freshly issued tokens, requests fail with 401 instead of
///   refreshing forever.
///
/// `refresh` must not go through a client that uses this interceptor: the
/// refresh request would get the expired bearer token, and a 401 on it would
/// wait for the very refresh that is waiting for it. Use a separate client
/// without `refreshAction`.
public actor AuthInterceptor: RequestInterceptor {
    public typealias RefreshAction = @Sendable (AuthTokens) async throws -> AuthTokens

    /// Upper bound on refreshes within a sliding time interval.
    public struct RefreshWindow: Sendable {
        /// Length of the sliding window, in seconds.
        public var interval: TimeInterval
        /// Refreshes allowed within `interval`; a 401 beyond that is not retried.
        public var maximumRefreshes: Int

        public init(interval: TimeInterval = 30, maximumRefreshes: Int = 5) {
            self.interval = interval
            self.maximumRefreshes = maximumRefreshes
        }

        public static let `default` = RefreshWindow()
    }

    private let tokenStore: any TokenStore
    private let refresh: RefreshAction
    private let refreshWindow: RefreshWindow
    private let clock = ContinuousClock()
    private var inflight: Task<Void, any Error>?
    private var recentRefreshes: [ContinuousClock.Instant] = []

    public init(tokenStore: any TokenStore,
                refreshWindow: RefreshWindow = .default,
                refresh: @escaping RefreshAction) {
        self.tokenStore = tokenStore
        self.refreshWindow = refreshWindow
        self.refresh = refresh
    }

    nonisolated public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var req = request
        if let token = await tokenStore.current() {
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    nonisolated public func retry(_ request: URLRequest,
                                  response: HTTPURLResponse?,
                                  error: any Error & Sendable,
                                  attempt: Int) async -> RetryDecision {
        guard response?.statusCode == 401 else { return .doNotRetry }
        do {
            try await refreshTokens(rejectedAccessToken: Self.bearerToken(in: request))
            return .retry
        } catch {
            return .doNotRetry
        }
    }

    /// Joins the in-flight refresh or starts one. `inflight` is assigned before
    /// the first suspension point, so callers arriving while a refresh runs
    /// always join it instead of starting their own.
    private func refreshTokens(rejectedAccessToken: String?) async throws {
        if let inflight {
            try await inflight.value
            return
        }
        let task = Task { try await self.performRefresh(rejectedAccessToken: rejectedAccessToken) }
        inflight = task
        defer { inflight = nil }
        try await task.value
    }

    private func performRefresh(rejectedAccessToken: String?) async throws {
        guard let current = await tokenStore.current() else {
            throw APIError.unauthorized
        }
        // The request was sent with an older token (or before login):
        // retrying picks up the current token without another refresh.
        guard current.accessToken == rejectedAccessToken else { return }

        try reserveRefresh()
        let new = try await refresh(current)
        await tokenStore.save(new)
    }

    private func reserveRefresh() throws {
        let now = clock.now
        let windowStart = now - .seconds(refreshWindow.interval)
        recentRefreshes.removeAll { $0 < windowStart }
        guard recentRefreshes.count < refreshWindow.maximumRefreshes else {
            throw APIError.unauthorized
        }
        recentRefreshes.append(now)
    }

    private static func bearerToken(in request: URLRequest) -> String? {
        guard let value = request.value(forHTTPHeaderField: "Authorization"),
              value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }
}
