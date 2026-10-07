import Foundation

/// What `RequestInterceptor.retry(_:response:error:attempt:)` decides about a failed attempt.
public enum RetryDecision: Sendable {
    /// Fail the request with the attempt's error.
    case doNotRetry
    /// Send another attempt at once.
    case retry
    /// Send another attempt after waiting the given number of seconds.
    ///
    /// Both transports retry at once for a negative delay. For a delay that is not finite or is longer
    /// than about 292 years, they do not retry and fail the request with the attempt's error.
    case retryAfter(TimeInterval)
}

extension RetryDecision {
    /// The longest delay a transport waits for: `Int64.max` nanoseconds, about 292 years.
    ///
    /// Dispatch, which the Alamofire transport waits with, measures deadlines in `Int64` nanoseconds;
    /// `Task.sleep(for: .seconds(_:))`, which the URLSession transport waits with, traps for a delay of
    /// about `Int64.max` seconds and more.
    package static let longestDelay: TimeInterval = Double(Int64.max) / 1_000_000_000

    /// This decision as both transports carry it out.
    ///
    /// - Returns: `.doNotRetry` for a `.retryAfter(_:)` delay that is not finite or exceeds
    ///   `longestDelay`, since waiting that long never retries; `.retryAfter(0)` for a negative delay,
    ///   like a `Retry-After` date in the past; otherwise the decision unchanged.
    package var validated: RetryDecision {
        guard case .retryAfter(let delay) = self else { return self }
        guard delay.isFinite, delay <= Self.longestDelay else { return .doNotRetry }
        return .retryAfter(max(0, delay))
    }
}
