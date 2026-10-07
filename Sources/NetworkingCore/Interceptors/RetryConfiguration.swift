import Foundation

/// When `RetryInterceptor` sends a failed request again, and how long it waits first.
public struct RetryConfiguration: Sendable {
    /// The maximum number of attempts, the first one included. `0` and `1` disable retries;
    /// the default `3` allows up to two retries.
    public var limit: Int
    /// The backoff delay after the first failed attempt, in seconds. It doubles after every further attempt.
    public var baseDelay: TimeInterval
    /// The longest wait before a retry, in seconds. Caps the backoff delay after jitter is applied.
    /// A `Retry-After` wait longer than this is not retried.
    public var maxDelay: TimeInterval
    /// The range of the random factor the backoff delay is multiplied by. Not applied to `Retry-After`.
    public var jitter: ClosedRange<Double>
    /// The methods whose requests are retried, after both transport errors and retryable statuses.
    public var retryableMethods: Set<HTTPMethod>
    /// The response statuses that are retried.
    public var retryableStatusCodes: Set<Int>

    public init(limit: Int = 3,
                baseDelay: TimeInterval = 0.5,
                maxDelay: TimeInterval = 30,
                jitter: ClosedRange<Double> = 0.8...1.2,
                retryableMethods: Set<HTTPMethod> = [.get, .head, .put, .delete],
                retryableStatusCodes: Set<Int> = [408, 425, 429, 500, 502, 503, 504]) {
        self.limit = limit
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.retryableMethods = retryableMethods
        self.retryableStatusCodes = retryableStatusCodes
    }

    public static let `default` = RetryConfiguration()
    public static let none = RetryConfiguration(limit: 0)

    /// The backoff delay after failed attempt `attempt` (1-based):
    /// `min(maxDelay, baseDelay * 2^(attempt-1) * factor)`, with `factor` drawn at random from `jitter`.
    public func delay(for attempt: Int) -> TimeInterval {
        let exp = pow(2.0, Double(max(0, attempt - 1)))
        let factor = Double.random(in: jitter)
        let raw = baseDelay * exp * factor
        // An overflowed `exp` times a zero factor is NaN, which `min` would turn into `maxDelay`.
        guard !raw.isNaN else { return 0 }
        return min(maxDelay, raw)
    }
}
