import Foundation

public enum RetryDecision: Sendable {
    case doNotRetry
    case retry
    case retryAfter(TimeInterval)
}
