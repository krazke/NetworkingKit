import Foundation

/// OAuth Bearer + refresh-on-401 с дедупликацией параллельных refresh'ей.
/// Сам refresh-запрос делегируется наружу (closure), чтобы пакет не диктовал
/// формат refresh-эндпоинта.
public actor AuthInterceptor: RequestInterceptor {
    public typealias RefreshAction = @Sendable (AuthTokens) async throws -> AuthTokens

    private let tokenStore: any TokenStore
    private let refresh: RefreshAction
    private var inflight: Task<AuthTokens, any Error & Sendable>?

    public init(tokenStore: any TokenStore, refresh: @escaping RefreshAction) {
        self.tokenStore = tokenStore
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
        guard response?.statusCode == 401, attempt == 1 else { return .doNotRetry }
        do {
            try await refreshIfNeeded()
            return .retry
        } catch {
            return .doNotRetry
        }
    }

    private func refreshIfNeeded() async throws {
        if let task = inflight {
            _ = try await task.value
            return
        }
        guard let current = await tokenStore.current() else {
            throw APIError.unauthorized
        }
        let refresh = self.refresh
        let store = self.tokenStore
        let typed = Task<AuthTokens, any Error & Sendable> {
            let new = try await refresh(current)
            await store.save(new)
            return new
        }
        inflight = typed
        defer { inflight = nil }
        _ = try await typed.value
    }
}

