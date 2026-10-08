import XCTest
import Security
@testable import NetworkingURLSession
import NetworkingCore

/// `PinningDelegate`'s answer to a server trust challenge.
///
/// `StubProtocol` never raises a server trust challenge, so the tests call the delegate with a challenge
/// built around a `SecTrust` from `PinningFixtures`. A completed request is not covered: the delegate's
/// answer is what decides whether the connection is used.
final class PinningDelegateTests: XCTestCase {
    private typealias Pin = @Sendable (Data) -> PinningPolicy

    private static let certificates: Pin = { .certificates([$0]) }
    private static let publicKeys: Pin = { .publicKeys([$0]) }

    // MARK: - .certificates

    func testCertificatePinAcceptsMatchingCertificateWithTrustedChain() {
        assertAccepts(pin: Self.certificates)
    }

    func testCertificatePinRejectsExpiredCertificate() {
        assertRejectsExpiredCertificate(pin: Self.certificates)
    }

    func testCertificatePinRejectsCertificateForAnotherHost() {
        assertRejectsCertificateForAnotherHost(pin: Self.certificates)
    }

    func testCertificatePinRejectsUntrustedRoot() {
        assertRejectsUntrustedRoot(pin: Self.certificates)
    }

    func testCertificatePinRejectsMismatchedCertificate() {
        assertRejectsMismatch(pin: Self.certificates)
    }

    // MARK: - .publicKeys

    func testPublicKeyPinAcceptsMatchingKeyWithTrustedChain() {
        assertAccepts(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsExpiredCertificate() {
        assertRejectsExpiredCertificate(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsCertificateForAnotherHost() {
        assertRejectsCertificateForAnotherHost(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsUntrustedRoot() {
        assertRejectsUntrustedRoot(pin: Self.publicKeys)
    }

    func testPublicKeyPinRejectsMismatchedKey() {
        assertRejectsMismatch(pin: Self.publicKeys)
    }

    // MARK: - Unpinned hosts

    func testUnpinnedHostGetsDefaultHandling() {
        let delegate = PinningDelegate(pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf])])
        // An untrusted chain: default handling must leave the decision to the system, not accept it.
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.unrelated,
                                                forHost: PinningFixtures.wrongHost,
                                                anchored: false)

        let answer = answer(of: delegate, host: PinningFixtures.wrongHost, trust: trust)

        XCTAssertEqual(answer.disposition, .performDefaultHandling)
        XCTAssertNil(answer.credential)
    }

    // MARK: - Assertions

    private func assertAccepts(pin: Pin, file: StaticString = #filePath, line: UInt = #line) {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.host)
        let delegate = PinningDelegate(pinning: [PinningFixtures.host: pin(PinningFixtures.leaf)])

        let answer = answer(of: delegate, host: PinningFixtures.host, trust: trust)

        XCTAssertEqual(answer.disposition, .useCredential, file: file, line: line)
        XCTAssertNotNil(answer.credential, file: file, line: line)
    }

    private func assertRejectsExpiredCertificate(pin: Pin, file: StaticString = #filePath, line: UInt = #line) {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.expiredLeaf, forHost: PinningFixtures.host)
        let delegate = PinningDelegate(pinning: [PinningFixtures.host: pin(PinningFixtures.expiredLeaf)])

        assertCancelled(answer(of: delegate, host: PinningFixtures.host, trust: trust), file: file, line: line)
    }

    private func assertRejectsCertificateForAnotherHost(pin: Pin, file: StaticString = #filePath, line: UInt = #line) {
        // URLSession puts the host it connected to into the trust's SSL policy.
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.wrongHost)
        let delegate = PinningDelegate(pinning: [PinningFixtures.wrongHost: pin(PinningFixtures.leaf)])

        assertCancelled(answer(of: delegate, host: PinningFixtures.wrongHost, trust: trust), file: file, line: line)
    }

    private func assertRejectsUntrustedRoot(pin: Pin, file: StaticString = #filePath, line: UInt = #line) {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf,
                                                forHost: PinningFixtures.host,
                                                anchored: false)
        let delegate = PinningDelegate(pinning: [PinningFixtures.host: pin(PinningFixtures.leaf)])

        assertCancelled(answer(of: delegate, host: PinningFixtures.host, trust: trust), file: file, line: line)
    }

    private func assertRejectsMismatch(pin: Pin, file: StaticString = #filePath, line: UInt = #line) {
        let trust = PinningFixtures.serverTrust(presenting: PinningFixtures.leaf, forHost: PinningFixtures.host)
        let delegate = PinningDelegate(pinning: [PinningFixtures.host: pin(PinningFixtures.unrelated)])

        assertCancelled(answer(of: delegate, host: PinningFixtures.host, trust: trust), file: file, line: line)
    }

    private func assertCancelled(_ answer: Answer, file: StaticString, line: UInt) {
        XCTAssertEqual(answer.disposition, .cancelAuthenticationChallenge, file: file, line: line)
        XCTAssertNil(answer.credential, file: file, line: line)
    }

    // MARK: - Challenge

    private struct Answer {
        let disposition: URLSession.AuthChallengeDisposition
        let credential: URLCredential?
    }

    private func answer(of delegate: PinningDelegate, host: String, trust: SecTrust,
                        file: StaticString = #filePath, line: UInt = #line) -> Answer {
        let challenge = URLAuthenticationChallenge(protectionSpace: ServerTrustProtectionSpace(host: host, trust: trust),
                                                   proposedCredential: nil,
                                                   previousFailureCount: 0,
                                                   failureResponse: nil,
                                                   error: nil,
                                                   sender: IgnoringChallengeSender())
        var answer: Answer?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            answer = Answer(disposition: disposition, credential: credential)
        }
        // The delegate answers synchronously; a missing answer would leave the connection waiting.
        guard let answer else {
            XCTFail("PinningDelegate did not call the completion handler", file: file, line: line)
            return Answer(disposition: .rejectProtectionSpace, credential: nil)
        }
        return answer
    }
}

/// A server trust protection space with a given trust. `URLProtectionSpace` has no initializer that takes one.
private final class ServerTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust) {
        self.trust = trust
        super.init(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                   authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

/// The delegate answers through its completion handler, so the sender is never used.
private final class IgnoringChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
