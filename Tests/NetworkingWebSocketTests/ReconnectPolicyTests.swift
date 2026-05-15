import XCTest
@testable import NetworkingWebSocket

final class ReconnectPolicyTests: XCTestCase {

    func test_none_returnsNil() {
        let p = ReconnectPolicy.none
        XCTAssertNil(p.delay(for: 1))
    }

    func test_linear_returnsConstantDelay() {
        let p = ReconnectPolicy.linear(delay: 2.0, maxAttempts: 3)
        XCTAssertEqual(p.delay(for: 1), 2.0)
        XCTAssertEqual(p.delay(for: 3), 2.0)
        XCTAssertNil(p.delay(for: 4))
    }

    func test_exponential_growsAndCaps() {
        let p = ReconnectPolicy.exponential(baseDelay: 1.0,
                                            maxDelay: 8,
                                            maxAttempts: 10,
                                            jitter: 1.0...1.0)
        XCTAssertEqual(p.delay(for: 1), 1.0)
        XCTAssertEqual(p.delay(for: 2), 2.0)
        XCTAssertEqual(p.delay(for: 3), 4.0)
        XCTAssertEqual(p.delay(for: 4), 8.0)
        XCTAssertEqual(p.delay(for: 5), 8.0)  // capped
    }

    func test_exponential_jitterStaysInBounds() {
        let p = ReconnectPolicy.exponential(baseDelay: 10,
                                            maxDelay: 100,
                                            maxAttempts: .max,
                                            jitter: 0.5...1.5)
        for _ in 0..<50 {
            let d = p.delay(for: 1)!
            XCTAssertGreaterThanOrEqual(d, 5.0)
            XCTAssertLessThanOrEqual(d, 15.0)
        }
    }

    func test_givenUp_afterMaxAttempts() {
        let p = ReconnectPolicy.exponential(baseDelay: 1, maxDelay: 10, maxAttempts: 2)
        XCTAssertNotNil(p.delay(for: 1))
        XCTAssertNotNil(p.delay(for: 2))
        XCTAssertNil(p.delay(for: 3))
    }
}
