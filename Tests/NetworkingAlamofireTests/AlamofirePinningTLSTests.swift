import XCTest
import NetworkingAlamofire
import NetworkingCore
import NetworkingTesting

private struct GetEndpoint: APIEndpoint {
    var path: String { "/items" }
    var method: HTTPMethod { .get }
}

/// A pinned host over a real TLS connection to `LoopbackTLSServer`.
///
/// The server's certificate is self-signed, so the evaluators `ServerTrustFactory` builds reject the trust
/// whatever the pin, and only a `.trustEvaluationFailed` rejection is reachable; `AlamofirePinningFailureTests`
/// covers a pin mismatch with a trusted chain. The test checks the error Alamofire reports for a challenge its
/// `SessionDelegate` rejected over a real connection, and that the request opens one connection.
/// `URLSessionPinningTLSTests` checks the URLSession transport.
final class AlamofirePinningTLSTests: XCTestCase {

    func testMatchingPinOnUntrustedCertificateThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: LoopbackTLSServer.certificate,
                                 pin: .certificates([LoopbackTLSServer.certificate]))
    }

    func testMatchingPinOnExpiredCertificateThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: LoopbackTLSServer.expiredCertificate,
                                 pin: .publicKeys([LoopbackTLSServer.expiredCertificate]))
    }

    /// No pin can match an empty list; the system rejects the certificate before the pins are compared.
    func testEmptyPinListOnUntrustedCertificateThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: LoopbackTLSServer.certificate, pin: .certificates([]))
    }

    /// URLSession lowercases the host in the challenge, in the task's current request and in the error's failing
    /// URL, so a host written with uppercase letters in the base URL is pinned and reported in lowercase.
    func testUppercaseBaseURLHostIsPinned() async throws {
        try await assertRejected(presenting: LoopbackTLSServer.certificate,
                                 pin: .certificates([LoopbackTLSServer.certificate]),
                                 baseURLHost: "LOCALHOST",
                                 key: "localhost",
                                 reportedHost: "localhost")
    }

    /// Before 1.3.0 a key with an uppercase letter matched no challenge, and the host was not pinned.
    func testUppercaseKeyPinsHost() async throws {
        try await assertRejected(presenting: LoopbackTLSServer.certificate,
                                 pin: .certificates([LoopbackTLSServer.certificate]),
                                 baseURLHost: "localhost",
                                 key: "LocalHost",
                                 reportedHost: "localhost")
    }

    /// Requests `baseURLHost`, which resolves to the server's address, with `pin` for `key`, and expects a
    /// `.trustEvaluationFailed` rejection of `reportedHost`. `localhost` reaches the server, whose certificate is
    /// issued for its IP address only, so the system rejects the trust for that name too.
    private func assertRejected(presenting certificate: Data, pin: PinningPolicy,
                                baseURLHost: String = LoopbackTLSServer.host,
                                key: String = LoopbackTLSServer.host,
                                reportedHost: String = LoopbackTLSServer.host,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let server = try await LoopbackTLSServer(presenting: certificate)
        defer { server.stop() }
        let baseURL = try XCTUnwrap(URL(string: "https://\(baseURLHost):\(try XCTUnwrap(server.baseURL.port))/"))
        let recorder = RecordingInterceptor()
        let client = AlamofireAPIClient(configuration: NetworkConfiguration(
            baseURL: baseURL,
            sessionConfiguration: .ephemeral,
            pinning: [key: pin],
            retry: RetryConfiguration(limit: 3, baseDelay: 0.01, maxDelay: 0.01),
            additionalInterceptors: [recorder]
        ))

        do {
            try await client.sendVoid(GetEndpoint())
            XCTFail("Expected APIError.transport(PinningError)", file: file, line: line)
        } catch APIError.transport(let error as PinningError) {
            XCTAssertEqual(error, PinningError(host: reportedHost, reason: .trustEvaluationFailed),
                           file: file, line: line)
        } catch {
            XCTFail("Expected APIError.transport(PinningError), got \(error)", file: file, line: line)
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0, "retry must not be asked about a rejected server trust", file: file, line: line)
        XCTAssertEqual(server.connectionCount, 1, file: file, line: line)
    }
}
