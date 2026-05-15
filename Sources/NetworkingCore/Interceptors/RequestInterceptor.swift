import Foundation

/// Async-first request interceptor. Транспорты бриджуют это в свою цепочку.
public protocol RequestInterceptor: Sendable {
    /// Модификация исходящего запроса (заголовки, авторизация, телеметрия).
    func adapt(_ request: URLRequest) async throws -> URLRequest

    /// Решение о повторе после ошибки/неуспешного статуса.
    /// `attempt` — номер попытки (1-based).
    func retry(_ request: URLRequest,
               response: HTTPURLResponse?,
               error: any Error & Sendable,
               attempt: Int) async -> RetryDecision
}

public extension RequestInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest { request }
    func retry(_ request: URLRequest,
               response: HTTPURLResponse?,
               error: any Error & Sendable,
               attempt: Int) async -> RetryDecision { .doNotRetry }
}
