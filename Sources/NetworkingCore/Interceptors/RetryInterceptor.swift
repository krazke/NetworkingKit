import Foundation

/// Принимает решение о повторе по `RetryConfiguration`.
/// Совмещается с другими интерсепторами через композицию (см. CompositeInterceptor).
public struct RetryInterceptor: RequestInterceptor {
    public let configuration: RetryConfiguration
    public init(configuration: RetryConfiguration) { self.configuration = configuration }

    public func retry(_ request: URLRequest,
                      response: HTTPURLResponse?,
                      error: any Error & Sendable,
                      attempt: Int) async -> RetryDecision {
        guard attempt < configuration.limit else { return .doNotRetry }

        // Метод не идемпотентный — не ретраим.
        let method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        guard configuration.retryableMethods.contains(method) else { return .doNotRetry }

        // Сетевая ошибка (нет ответа) — ретраим.
        if response == nil {
            return .retryAfter(configuration.delay(for: attempt))
        }

        // По коду ответа.
        if let code = response?.statusCode,
           configuration.retryableStatusCodes.contains(code) {
            return .retryAfter(configuration.delay(for: attempt))
        }

        return .doNotRetry
    }
}
