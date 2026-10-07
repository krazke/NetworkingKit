import XCTest
@testable import NetworkingCore

/// How `RetryDecision.validated` turns a decision into one both transports can carry out.
final class RetryDecisionValidationTests: XCTestCase {

    private func assertDelay(_ decision: RetryDecision, _ expected: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .retryAfter(let delay) = decision.validated else {
            return XCTFail("Expected .retryAfter(\(expected)), got \(decision.validated)", file: file, line: line)
        }
        XCTAssertEqual(delay, expected, file: file, line: line)
    }

    private func assertDoNotRetry(_ decision: RetryDecision,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .doNotRetry = decision.validated else {
            return XCTFail("Expected .doNotRetry, got \(decision.validated)", file: file, line: line)
        }
    }

    func test_doNotRetryAndRetry_areUnchanged() {
        assertDoNotRetry(.doNotRetry)
        guard case .retry = RetryDecision.retry.validated else {
            return XCTFail("Expected .retry, got \(RetryDecision.retry.validated)")
        }
    }

    func test_delayInRange_isUnchanged() {
        assertDelay(.retryAfter(0), 0)
        assertDelay(.retryAfter(0.5), 0.5)
        assertDelay(.retryAfter(1e9), 1e9)
        assertDelay(.retryAfter(RetryDecision.longestDelay), RetryDecision.longestDelay)
    }

    func test_negativeDelay_becomesZero() {
        assertDelay(.retryAfter(-0.5), 0)
        assertDelay(.retryAfter(-1e19), 0)
        assertDelay(.retryAfter(-.greatestFiniteMagnitude), 0)
    }

    func test_nonFiniteDelay_isNotRetried() {
        assertDoNotRetry(.retryAfter(.nan))
        assertDoNotRetry(.retryAfter(.infinity))
        assertDoNotRetry(.retryAfter(-.infinity))
    }

    func test_delayAboveLongestDelay_isNotRetried() {
        assertDoNotRetry(.retryAfter(RetryDecision.longestDelay.nextUp))
        assertDoNotRetry(.retryAfter(1e19))
        assertDoNotRetry(.retryAfter(.greatestFiniteMagnitude))
    }

    func test_longestDelay_isInt64MaxNanoseconds() {
        // About 292 years; Dispatch measures deadlines in Int64 nanoseconds.
        XCTAssertEqual(RetryDecision.longestDelay, Double(Int64.max) / 1e9)
    }
}
