import XCTest
@testable import NetworkingCore

final class RetryConfigurationTests: XCTestCase {
    func test_delay_growsExponentially() {
        let config = RetryConfiguration(limit: 5,
                                        baseDelay: 1.0,
                                        maxDelay: 100,
                                        jitter: 1.0...1.0)
        XCTAssertEqual(config.delay(for: 1), 1.0, accuracy: 0.001)
        XCTAssertEqual(config.delay(for: 2), 2.0, accuracy: 0.001)
        XCTAssertEqual(config.delay(for: 3), 4.0, accuracy: 0.001)
        XCTAssertEqual(config.delay(for: 4), 8.0, accuracy: 0.001)
    }

    func test_delay_cappedByMaxDelay() {
        let config = RetryConfiguration(limit: 10,
                                        baseDelay: 1.0,
                                        maxDelay: 5,
                                        jitter: 1.0...1.0)
        XCTAssertEqual(config.delay(for: 10), 5.0, accuracy: 0.001)
    }

    func test_delay_jitterBounds() {
        let config = RetryConfiguration(limit: 3,
                                        baseDelay: 10,
                                        maxDelay: 100,
                                        jitter: 0.5...1.5)
        for _ in 0..<50 {
            let d = config.delay(for: 1)
            XCTAssertGreaterThanOrEqual(d, 5.0)
            XCTAssertLessThanOrEqual(d, 15.0)
        }
    }
}
