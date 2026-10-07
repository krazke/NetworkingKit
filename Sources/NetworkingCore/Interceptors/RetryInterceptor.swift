import Foundation

/// Decides whether to retry a failed attempt according to a `RetryConfiguration`.
///
/// A failed attempt is retried while fewer than `limit` attempts have been sent, only for a method in
/// `retryableMethods`, and only after a transport error or a status in `retryableStatusCodes`. The wait
/// is the backoff from `RetryConfiguration.delay(for:)`, except for a 429 or 503 response with a valid
/// `Retry-After` header:
/// - The value is delta-seconds (`120`) or an HTTP-date in any of the three formats of RFC 9110. A date
///   is measured from the response's `Date` header, or from the local clock when that is missing.
/// - The wait is used as is, without jitter. A date in the past retries at once.
/// - A wait longer than `maxDelay` is not retried: the request fails with the response's error.
/// - An invalid value, such as `-5` or `1.5`, is ignored and the backoff applies.
///
/// Both transports put it last in the chain (see `CompositeInterceptor`), so an interceptor in
/// `NetworkConfiguration.additionalInterceptors` that decides to retry takes precedence over it.
public struct RetryInterceptor: RequestInterceptor {
    /// Statuses whose `Retry-After` sets the wait: RFC 6585 defines it for 429, RFC 9110 for 503.
    private static let retryAfterStatusCodes: Set<Int> = [429, 503]

    public let configuration: RetryConfiguration
    private let now: @Sendable () -> Date

    public init(configuration: RetryConfiguration) {
        self.init(configuration: configuration, now: { Date() })
    }

    init(configuration: RetryConfiguration, now: @escaping @Sendable () -> Date) {
        self.configuration = configuration
        self.now = now
    }

    public func retry(_ request: URLRequest,
                      response: HTTPURLResponse?,
                      error: any Error & Sendable,
                      attempt: Int) async -> RetryDecision {
        // `limit` counts the first attempt too, so attempt `limit` is the last one.
        guard attempt < configuration.limit else { return .doNotRetry }

        let method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        guard configuration.retryableMethods.contains(method) else { return .doNotRetry }

        // A transport error has no response.
        guard let response else {
            return .retryAfter(configuration.delay(for: attempt))
        }
        guard configuration.retryableStatusCodes.contains(response.statusCode) else { return .doNotRetry }

        if Self.retryAfterStatusCodes.contains(response.statusCode),
           let wait = retryAfter(in: response) {
            // Retrying before the server's time would most likely fail the same way and waste an attempt.
            guard wait.isFinite, wait <= configuration.maxDelay else { return .doNotRetry }
            return .retryAfter(wait)
        }
        return .retryAfter(configuration.delay(for: attempt))
    }

    /// The wait `response`'s `Retry-After` header asks for, or `nil` when the header is missing or invalid.
    /// Infinite for a delta-seconds value too large for `TimeInterval`.
    private func retryAfter(in response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)

        // delta-seconds is `1*DIGIT`: no sign, fraction or exponent.
        if !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) }) {
            return TimeInterval(value)
        }

        let now = now()
        guard let date = HTTPDate.parse(value, relativeTo: now) else { return nil }
        // Measuring from the server's own clock keeps a skewed device clock out of the wait.
        let reference = response.value(forHTTPHeaderField: "Date")
            .flatMap { HTTPDate.parse($0, relativeTo: now) } ?? now
        return max(0, date.timeIntervalSince(reference))
    }
}
