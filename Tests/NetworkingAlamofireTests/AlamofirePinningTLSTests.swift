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

    private func assertRejected(presenting certificate: Data, pin: PinningPolicy,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let server = try await LoopbackTLSServer(presenting: certificate)
        defer { server.stop() }
        let recorder = RecordingInterceptor()
        let client = AlamofireAPIClient(configuration: NetworkConfiguration(
            baseURL: server.baseURL,
            sessionConfiguration: .ephemeral,
            pinning: [LoopbackTLSServer.host: pin],
            retry: RetryConfiguration(limit: 3, baseDelay: 0.01, maxDelay: 0.01),
            additionalInterceptors: [recorder]
        ))

        do {
            try await client.sendVoid(GetEndpoint())
            XCTFail("Expected APIError.transport(PinningError)", file: file, line: line)
        } catch APIError.transport(let error as PinningError) {
            XCTAssertEqual(error, PinningError(host: LoopbackTLSServer.host, reason: .trustEvaluationFailed),
                           file: file, line: line)
        } catch {
            XCTFail("Expected APIError.transport(PinningError), got \(error)", file: file, line: line)
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0, "retry must not be asked about a rejected server trust", file: file, line: line)
        XCTAssertEqual(server.connectionCount, 1, file: file, line: line)
    }
}
