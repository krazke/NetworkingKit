import Foundation

public struct RetryConfiguration: Sendable {
    public var limit: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: ClosedRange<Double>
    public var retryableMethods: Set<HTTPMethod>
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

    /// Вычисляет задержку для попытки `attempt` (1-based) с jitter.
    public func delay(for attempt: Int) -> TimeInterval {
        let exp = pow(2.0, Double(max(0, attempt - 1)))
        let raw = min(maxDelay, baseDelay * exp)
        let factor = Double.random(in: jitter)
        return raw * factor
    }
}
