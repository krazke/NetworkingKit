import Foundation

public enum ReconnectPolicy: Sendable {
    /// Без авто-переподключения.
    case none
    /// Линейная задержка между попытками.
    case linear(delay: TimeInterval, maxAttempts: Int = .max)
    /// Экспоненциальный backoff с jitter (избегаем thundering herd).
    case exponential(baseDelay: TimeInterval = 1.0,
                     maxDelay: TimeInterval = 30.0,
                     maxAttempts: Int = .max,
                     jitter: ClosedRange<Double> = 0.8...1.2)

    /// Возвращает задержку для попытки `attempt` (1-based) или nil, если переподключаться не нужно.
    public func delay(for attempt: Int) -> TimeInterval? {
        switch self {
        case .none:
            return nil
        case .linear(let delay, let max):
            return attempt <= max ? delay : nil
        case .exponential(let base, let cap, let max, let jitter):
            guard attempt <= max else { return nil }
            let exp = pow(2.0, Double(attempt - 1))
            let raw = min(cap, base * exp)
            return raw * Double.random(in: jitter)
        }
    }
}
