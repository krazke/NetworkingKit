import XCTest
@testable import NetworkingCore

/// How `RetryInterceptor` honors `Retry-After` on 429 and 503.
/// The clock is fixed and jitter is 1.0...1.0, so every expected delay is exact.
final class RetryAfterTests: XCTestCase {

    /// Wed, 07 Oct 2026 12:00:00 GMT.
    private static let now = Date(timeIntervalSince1970: 1_791_374_400)

    /// Backoff is 1 s for attempt 1 and 2 s for attempt 2, so it never equals a `Retry-After` value below.
    private static let config = RetryConfiguration(limit: 3, baseDelay: 1, maxDelay: 30, jitter: 1.0...1.0)

    private func decide(status: Int = 503,
                        headers: [String: String] = [:],
                        method: String = "GET",
                        attempt: Int = 1,
                        configuration: RetryConfiguration = config) async -> RetryDecision {
        let interceptor = RetryInterceptor(configuration: configuration, now: { Self.now })
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpMethod = method
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        return await interceptor.retry(request,
                                       response: response,
                                       error: APIError.server(statusCode: status, data: nil, message: nil),
                                       attempt: attempt)
    }

    private func assertDelay(_ decision: RetryDecision, _ expected: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .retryAfter(let delay) = decision else {
            return XCTFail("Expected .retryAfter(\(expected)), got \(decision)", file: file, line: line)
        }
        XCTAssertEqual(delay, expected, accuracy: 0.000_1, file: file, line: line)
    }

    private func assertDoNotRetry(_ decision: RetryDecision,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .doNotRetry = decision else {
            return XCTFail("Expected .doNotRetry, got \(decision)", file: file, line: line)
        }
    }

    // MARK: - delta-seconds

    func test_deltaSeconds_on503_isTheDelay() async {
        assertDelay(await decide(status: 503, headers: ["Retry-After": "7"]), 7)
    }

    func test_deltaSeconds_on429_isTheDelay() async {
        assertDelay(await decide(status: 429, headers: ["Retry-After": "7"]), 7)
    }

    func test_deltaSeconds_surroundingWhitespaceIsIgnored() async {
        assertDelay(await decide(headers: ["Retry-After": " 7 "]), 7)
    }

    func test_deltaSeconds_zero_retriesImmediately() async {
        assertDelay(await decide(headers: ["Retry-After": "0"]), 0)
    }

    func test_deltaSeconds_replacesBackoffOnLaterAttempts() async {
        assertDelay(await decide(headers: ["Retry-After": "7"], attempt: 2), 7)
    }

    func test_deltaSeconds_jitterIsNotApplied() async {
        let config = RetryConfiguration(limit: 3, baseDelay: 1, maxDelay: 30, jitter: 0.5...0.5)
        assertDelay(await decide(headers: ["Retry-After": "7"], configuration: config), 7)
    }

    // MARK: - HTTP-date

    func test_imfFixdate_isMeasuredFromDateHeader() async {
        // The local clock is far from the server's; the server's own `Date` is the reference.
        let decision = await decide(headers: ["Date": "Sun, 06 Nov 1994 08:49:37 GMT",
                                              "Retry-After": "Sun, 06 Nov 1994 08:49:49 GMT"])
        assertDelay(decision, 12)
    }

    func test_rfc850Date_isAccepted() async {
        let decision = await decide(headers: ["Date": "Sunday, 06-Nov-94 08:49:37 GMT",
                                              "Retry-After": "Sunday, 06-Nov-94 08:49:49 GMT"])
        assertDelay(decision, 12)
    }

    func test_asctimeDate_isAccepted() async {
        let decision = await decide(headers: ["Date": "Sun Nov  6 08:49:37 1994",
                                              "Retry-After": "Sun Nov  6 08:49:49 1994"])
        assertDelay(decision, 12)
    }

    func test_date_withoutDateHeader_isMeasuredFromLocalClock() async {
        assertDelay(await decide(headers: ["Retry-After": "Wed, 07 Oct 2026 12:00:05 GMT"]), 5)
    }

    func test_date_withUnparseableDateHeader_isMeasuredFromLocalClock() async {
        let decision = await decide(headers: ["Date": "yesterday",
                                              "Retry-After": "Wed, 07 Oct 2026 12:00:05 GMT"])
        assertDelay(decision, 5)
    }

    func test_date_inThePast_retriesImmediately() async {
        assertDelay(await decide(headers: ["Retry-After": "Wed, 07 Oct 2026 11:59:00 GMT"]), 0)
    }

    func test_date_equalToNow_retriesImmediately() async {
        assertDelay(await decide(headers: ["Retry-After": "Wed, 07 Oct 2026 12:00:00 GMT"]), 0)
    }

    func test_rfc850TwoDigitYear_within50YearsIsInTheFuture() async {
        // RFC 9110 §5.6.7: "50" is 2050, not 1950, so this is 24 years away and exceeds `maxDelay`.
        assertDoNotRetry(await decide(headers: ["Retry-After": "Friday, 07-Oct-50 12:00:00 GMT"]))
    }

    // MARK: - Invalid values fall back to backoff

    func test_invalidValues_fallBackToBackoff() async {
        let invalid = ["-5", "+7", "1.5", "7s", "inf", "nan", "1e3", "", "  ", "soon",
                       "7, 9", "Wed, 07 Oct 2026 12:00:05 UTC", "07 Oct 2026 12:00:05 GMT"]
        for value in invalid {
            let decision = await decide(headers: ["Retry-After": value], attempt: 2)
            guard case .retryAfter(let delay) = decision, delay == 2 else {
                XCTFail("Retry-After \"\(value)\": expected backoff .retryAfter(2), got \(decision)")
                continue
            }
        }
    }

    // MARK: - maxDelay

    func test_valueAboveMaxDelay_doesNotRetry() async {
        assertDoNotRetry(await decide(headers: ["Retry-After": "31"]))
    }

    func test_dateAboveMaxDelay_doesNotRetry() async {
        assertDoNotRetry(await decide(headers: ["Retry-After": "Wed, 07 Oct 2026 12:00:31 GMT"]))
    }

    func test_valueEqualToMaxDelay_isTheDelay() async {
        assertDelay(await decide(headers: ["Retry-After": "30"]), 30)
    }

    func test_valueTooLargeForDouble_doesNotRetry() async {
        let digits = String(repeating: "9", count: 400)
        let unbounded = RetryConfiguration(limit: 3, baseDelay: 1, maxDelay: .infinity, jitter: 1.0...1.0)
        assertDoNotRetry(await decide(headers: ["Retry-After": digits], configuration: unbounded))
    }

    // MARK: - Statuses, limit and methods

    func test_otherRetryableStatus_ignoresHeader() async {
        assertDelay(await decide(status: 500, headers: ["Retry-After": "7"]), 1)
    }

    func test_statusNotInRetryableStatusCodes_doesNotRetry() async {
        let config = RetryConfiguration(limit: 3, baseDelay: 1, maxDelay: 30, jitter: 1.0...1.0,
                                        retryableStatusCodes: [500])
        assertDoNotRetry(await decide(status: 429, headers: ["Retry-After": "7"], configuration: config))
    }

    func test_limitStillApplies() async {
        assertDoNotRetry(await decide(headers: ["Retry-After": "7"], attempt: 3))
    }

    func test_retryableMethodsStillApply() async {
        assertDoNotRetry(await decide(headers: ["Retry-After": "7"], method: "POST"))
    }

    func test_headerNameIsCaseInsensitive() async {
        assertDelay(await decide(headers: ["retry-after": "7"]), 7)
    }

    func test_publicInit_usesTheSystemClock() async {
        let interceptor = RetryInterceptor(configuration: Self.config)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1",
                                       headerFields: ["Retry-After": HTTPDateTestFormat.imf(Date() + 20)])!
        let decision = await interceptor.retry(request, response: response,
                                               error: APIError.server(statusCode: 503, data: nil, message: nil),
                                               attempt: 1)
        guard case .retryAfter(let delay) = decision else {
            return XCTFail("Expected .retryAfter, got \(decision)")
        }
        // The header has whole seconds, and some time passes before the interceptor reads the clock.
        XCTAssertGreaterThan(delay, 18)
        XCTAssertLessThanOrEqual(delay, 20)
    }
}

private enum HTTPDateTestFormat {
    static func imf(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
