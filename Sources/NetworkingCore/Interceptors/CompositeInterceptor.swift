import Foundation

/// Композирует список интерсепторов в один. `adapt` пропускает запрос
/// последовательно через каждый. `retry` опрашивает по очереди — первый
/// не-`.doNotRetry` побеждает.
public struct CompositeInterceptor: RequestInterceptor {
    public let interceptors: [any RequestInterceptor]
    public init(_ interceptors: [any RequestInterceptor]) { self.interceptors = interceptors }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var req = request
        for interceptor in interceptors {
            req = try await interceptor.adapt(req)
        }
        return req
    }

    public func retry(_ request: URLRequest,
                      response: HTTPURLResponse?,
                      error: any Error & Sendable,
                      attempt: Int) async -> RetryDecision {
        for interceptor in interceptors {
            let decision = await interceptor.retry(request,
                                                   response: response,
                                                   error: error,
                                                   attempt: attempt)
            if case .doNotRetry = decision { continue }
            return decision
        }
        return .doNotRetry
    }
}
