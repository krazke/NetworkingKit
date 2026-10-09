import XCTest
@testable import NetworkingURLSession
import NetworkingCore
import NetworkingTesting

private struct GetEndpoint: APIEndpoint {
    var path: String { "/items" }
    var method: HTTPMethod { .get }
}

/// PUT is retryable by default, so a request retried after a pin failure would be sent again.
private struct UploadEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: HTTPMethod { .put }
    var body: RequestBody { .multipart([.data(Data("x".utf8), name: "file")]) }
}

/// What a request to a pinned host whose server trust is rejected throws, and that `retry` is not asked about it.
///
/// `StubProtocol` answers each request's server trust challenge with the client's own `PinningDelegate`, using
/// a trust from `PinningFixtures`, and fails the request with `URLError.cancelled` when the delegate cancels the
/// challenge, as URLSession does for a TLS connection. `URLSessionPinningTLSTests` covers a real connection.
/// `AlamofirePinningFailureTests` checks the same behavior for the Alamofire transport.
final class URLSessionPinningFailureTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() async throws {
        StubProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Rejected trust

    func testCertificatePinMismatchThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.unrelated]),
                                 as: .pinMismatch)
    }

    func testPublicKeyPinMismatchThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 pin: .publicKeys([PinningFixtures.unrelated]),
                                 as: .pinMismatch)
    }

    func testExpiredCertificateThrowsTrustEvaluationFailureWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.expiredLeaf,
                                 pin: .certificates([PinningFixtures.expiredLeaf]),
                                 as: .trustEvaluationFailed)
    }

    func testCertificateForAnotherHostThrowsTrustEvaluationFailureWithoutRetry() async throws {
        try await assertRejected(host: PinningFixtures.wrongHost,
                                 presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.leaf]),
                                 as: .trustEvaluationFailed)
    }

    func testUntrustedRootThrowsTrustEvaluationFailureWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 anchored: false,
                                 pin: .publicKeys([PinningFixtures.leaf]),
                                 as: .trustEvaluationFailed)
    }

    func testUploadPinMismatchThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.unrelated]),
                                 as: .pinMismatch) { client in
            _ = try await client.upload(UploadEndpoint(), as: Data.self, progress: nil)
        }
    }

    func testDownloadPinMismatchThrowsPinningErrorWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.unrelated]),
                                 as: .pinMismatch) { client in
            _ = try await client.download(GetEndpoint(),
                                          to: .temporary(filename: "pinning-\(UUID().uuidString)"),
                                          progress: nil)
        }
    }

    // MARK: - Pin list without a usable pin

    /// No pin can match an empty list, so the host is rejected rather than left unpinned.
    func testEmptyCertificatePinListThrowsPinMismatchWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 pin: .certificates([]),
                                 as: .pinMismatch)
    }

    func testUnparsablePublicKeyPinListThrowsPinMismatchWithoutRetry() async throws {
        try await assertRejected(presenting: PinningFixtures.leaf,
                                 pin: .publicKeys([Data("not a certificate".utf8)]),
                                 as: .pinMismatch)
    }

    // MARK: - Accepted trust

    /// Guards the setup: a challenge the delegate accepts lets the request through.
    func testMatchingPinWithTrustedChainSucceeds() async throws {
        let recorder = RecordingInterceptor()
        let client = try makeClient(host: PinningFixtures.host,
                                    presenting: PinningFixtures.leaf,
                                    anchored: true,
                                    pin: .certificates([PinningFixtures.leaf]),
                                    recorder: recorder)

        try await client.sendVoid(GetEndpoint())

        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
    }

    // MARK: - Helpers

    private func assertRejected(host: String = PinningFixtures.host,
                                presenting certificate: Data,
                                anchored: Bool = true,
                                pin: PinningPolicy,
                                as reason: PinningError.Reason,
                                file: StaticString = #filePath, line: UInt = #line,
                                request: (URLSessionAPIClient) async throws -> Void = {
                                    try await $0.sendVoid(GetEndpoint())
                                }) async throws {
        let recorder = RecordingInterceptor()
        let client = try makeClient(host: host, presenting: certificate, anchored: anchored, pin: pin,
                                    recorder: recorder)

        do {
            try await request(client)
            XCTFail("Expected APIError.transport(PinningError)", file: file, line: line)
        } catch APIError.transport(let error as PinningError) {
            XCTAssertEqual(error, PinningError(host: host, reason: reason), file: file, line: line)
        } catch {
            XCTFail("Expected APIError.transport(PinningError), got \(error)", file: file, line: line)
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0, "retry must not be asked about a rejected server trust", file: file, line: line)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1, file: file, line: line)
    }

    /// A client for `https://<host>/` that pins `host` and allows three attempts, so a retried pin failure
    /// would be sent again. Every request's challenge presents `certificate`.
    private func makeClient(host: String,
                            presenting certificate: Data,
                            anchored: Bool,
                            pin: PinningPolicy,
                            recorder: RecordingInterceptor,
                            file: StaticString = #filePath, line: UInt = #line) throws -> URLSessionAPIClient {
        let configuration = NetworkConfiguration(baseURL: URL(string: "https://\(host)/")!,
                                                 sessionConfiguration: .stubbed,
                                                 pinning: [host: pin],
                                                 retry: RetryConfiguration(limit: 3, baseDelay: 0.01, maxDelay: 0.01),
                                                 additionalInterceptors: [recorder])
        let client = URLSessionAPIClient(configuration: configuration)
        let delegate = try XCTUnwrap(client.pinningDelegate, file: file, line: line)

        StubProtocol.reset(
            responder: { _ in .init(statusCode: 200, data: Data(), headers: [:], delay: 0) },
            serverTrustChallenger: { _, request, answer in
                let host = request.url!.host!
                let trust = PinningFixtures.serverTrust(presenting: certificate, forHost: host, anchored: anchored)
                // The session argument is unused by `PinningDelegate`; the stub has no access to the real one.
                delegate.urlSession(URLSession.shared,
                                    didReceive: ServerTrustChallenge.make(host: host, trust: trust)) { disposition, _ in
                    answer(disposition)
                }
            }
        )
        return client
    }
}
