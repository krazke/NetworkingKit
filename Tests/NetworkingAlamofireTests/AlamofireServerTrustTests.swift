import XCTest
import Security
import Alamofire
@testable import NetworkingAlamofire
import NetworkingCore

/// How the evaluators `ServerTrustFactory` builds judge a server trust: default system validation and host
/// validation first, then the pins, as `PinningDelegate` does in the URLSession transport.
///
/// The tests evaluate a `SecTrust` from `PinningFixtures` with the evaluator the manager returns for the host.
/// What a failed evaluation turns into for the request is covered by `AlamofirePinningFailureTests` and
/// `AlamofirePinningTLSTests`.
final class AlamofireServerTrustTests: XCTestCase {
    private typealias Pin = @Sendable (Data) -> PinningPolicy

    private static let certificates: Pin = { .certificates([$0]) }
    private static let publicKeys: Pin = { .publicKeys([$0]) }

    // MARK: - .certificates

    func testCertificatePinAcceptsMatchingCertificateWithTrustedChain() throws {
        try assertAccepts(pin: Self.certificates)
    }

    func testCertificatePinRejectsExpiredCertificate() throws {
        try assertRejectsExpiredCertificate(pin: Self.certificates)
    }

    func testCertificatePinRejectsCertificateForAnotherHost() throws {
        try assertRejectsCertificateForAnotherHost(pin: Self.certificates)
    }

    func testCertificatePinRejectsUntrustedRoot() throws {
        try assertRejectsUntrustedRoot(pin: Self.certificates)
    }

    func testCertificatePinRejectsMismatchedCertificate() throws {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.host)
        let evaluator = try evaluator(for: [PinningFixtures.host: .certificates([PinningFixtures.unrelated])],
                                      host: PinningFixtures.host)

        assertFails(try evaluator.evaluate(trust, forHost: PinningFixtures.host)) {
            if case .certificatePinningFailed = $0 { return true } else { return false }
        }
    }

    // MARK: - .publicKeys

    func testPublicKeyPinAcceptsMatchingKeyWithTrustedChain() throws {
        try assertAccepts(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsExpiredCertificate() throws {
        try assertRejectsExpiredCertificate(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsCertificateForAnotherHost() throws {
        try assertRejectsCertificateForAnotherHost(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsUntrustedRoot() throws {
        try assertRejectsUntrustedRoot(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsMismatchedKey() throws {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.host)
        let evaluator = try evaluator(for: [PinningFixtures.host: .publicKeys([PinningFixtures.unrelated])],
                                      host: PinningFixtures.host)

        assertFails(try evaluator.evaluate(trust, forHost: PinningFixtures.host)) {
            if case .publicKeyPinningFailed = $0 { return true } else { return false }
        }
    }

    // MARK: - Assertions

    private func assertAccepts(pin: Pin, file: StaticString = #filePath, line: UInt = #line) throws {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.host)
        let evaluator = try evaluator(for: [PinningFixtures.host: pin(PinningFixtures.leaf)], host: PinningFixtures.host)

        XCTAssertNoThrow(try evaluator.evaluate(trust, forHost: PinningFixtures.host), file: file, line: line)
    }

    private func assertRejectsExpiredCertificate(pin: Pin, file: StaticString = #filePath, line: UInt = #line) throws {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.expiredLeaf, forHost: PinningFixtures.host)
        let evaluator = try evaluator(for: [PinningFixtures.host: pin(PinningFixtures.expiredLeaf)],
                                      host: PinningFixtures.host)

        assertFailsTrustEvaluation(try evaluator.evaluate(trust, forHost: PinningFixtures.host), file: file, line: line)
    }

    private func assertRejectsCertificateForAnotherHost(pin: Pin, file: StaticString = #filePath, line: UInt = #line) throws {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.wrongHost)
        let evaluator = try evaluator(for: [PinningFixtures.wrongHost: pin(PinningFixtures.leaf)],
                                      host: PinningFixtures.wrongHost)

        assertFailsTrustEvaluation(try evaluator.evaluate(trust, forHost: PinningFixtures.wrongHost), file: file, line: line)
    }

    private func assertRejectsUntrustedRoot(pin: Pin, file: StaticString = #filePath, line: UInt = #line) throws {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf,
                                                forHost: PinningFixtures.host,
                                                anchored: false)
        let evaluator = try evaluator(for: [PinningFixtures.host: pin(PinningFixtures.leaf)], host: PinningFixtures.host)

        assertFailsTrustEvaluation(try evaluator.evaluate(trust, forHost: PinningFixtures.host), file: file, line: line)
    }

    /// The system rejects the trust before the pins are compared.
    private func assertFailsTrustEvaluation(_ expression: @autoclosure () throws -> Void,
                                            file: StaticString, line: UInt) {
        assertFails(try expression(), file: file, line: line) {
            if case .trustEvaluationFailed = $0 { return true } else { return false }
        }
    }

    private func assertFails(_ expression: @autoclosure () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line,
                             reason matches: (AFError.ServerTrustFailureReason) -> Bool) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case .serverTrustEvaluationFailed(let reason) = error as? AFError else {
                return XCTFail("Expected AFError.serverTrustEvaluationFailed, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(reason), "Unexpected reason: \(reason)", file: file, line: line)
        }
    }

    private func evaluator(for pinning: [String: PinningPolicy], host: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> any ServerTrustEvaluating {
        let manager = try XCTUnwrap(ServerTrustFactory.makeManager(pinning), file: file, line: line)
        return try XCTUnwrap(try manager.serverTrustEvaluator(forHost: host), file: file, line: line)
    }
}
