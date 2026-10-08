import XCTest
import Alamofire
@testable import NetworkingAlamofire
import NetworkingCore
import NetworkingTesting

private struct GetEndpoint: APIEndpoint {
    var path: String { "/items" }
    var method: NetworkingCore.HTTPMethod { .get }
}

/// PUT is retryable by default, so a request retried after a pin failure would be sent again.
private struct UploadEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: NetworkingCore.HTTPMethod { .put }
    var body: RequestBody { .multipart([.data(Data("x".utf8), name: "file")]) }
}

/// What a request to a pinned host whose server trust is rejected throws, and that `retry` is not asked about it.
///
/// The client runs on the session `AlamofireAPIClient(configuration:)` builds, with the `ServerTrustManager` from
/// `ServerTrustFactory`. `StubProtocol` answers each request's server trust challenge through that session's
/// `SessionDelegate`, using a trust from `PinningFixtures`, and fails the request with `URLError.cancelled` when
/// the delegate cancels the challenge, as URLSession does for a TLS connection. `AlamofirePinningTLSTests` covers
/// a real connection. `URLSessionPinningFailureTests` checks the same behavior for the URLSession transport.
final class AlamofirePinningFailureTests: XCTestCase {

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

    /// An unpinned host while another host is pinned fails with Alamofire's `noRequiredEvaluator`
    /// (see the known issues). That is not a pin failure, but it is not retried either.
    func testUnpinnedHostWithoutEvaluatorIsNotRetried() async throws {
        let recorder = RecordingInterceptor()
        let client = makeClient(host: PinningFixtures.wrongHost,
                                pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf])],
                                presenting: PinningFixtures.leaf,
                                anchored: true,
                                recorder: recorder)

        do {
            try await client.sendVoid(GetEndpoint())
            XCTFail("Expected APIError.transport")
        } catch APIError.transport(let error) {
            let reason = ((error as? NonSendableErrorBox)?.underlying as? AFError).flatMap { af -> AFError.ServerTrustFailureReason? in
                if case .serverTrustEvaluationFailed(let reason) = af { return reason } else { return nil }
            }
            guard case .noRequiredEvaluator(let host) = reason else {
                return XCTFail("Expected AFError.serverTrustEvaluationFailed(.noRequiredEvaluator), got \(error)")
            }
            XCTAssertEqual(host, PinningFixtures.wrongHost)
        } catch {
            XCTFail("Expected APIError.transport, got \(error)")
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
    }

    // MARK: - Accepted trust

    /// Guards the setup: a challenge the delegate accepts lets the request through.
    func testMatchingPinWithTrustedChainSucceeds() async throws {
        let client = makeClient(host: PinningFixtures.host,
                                pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf])],
                                presenting: PinningFixtures.leaf,
                                anchored: true,
                                recorder: RecordingInterceptor())

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
                                request: (AlamofireAPIClient) async throws -> Void = {
                                    try await $0.sendVoid(GetEndpoint())
                                }) async throws {
        let recorder = RecordingInterceptor()
        let client = makeClient(host: host, pinning: [host: pin], presenting: certificate, anchored: anchored,
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

    /// A client for `https://<host>/` that allows three attempts, so a retried trust failure would be sent again.
    /// Every request's challenge presents `certificate`.
    private func makeClient(host: String,
                            pinning: [String: PinningPolicy],
                            presenting certificate: Data,
                            anchored: Bool,
                            recorder: RecordingInterceptor) -> AlamofireAPIClient {
        let configuration = NetworkConfiguration(baseURL: URL(string: "https://\(host)/")!,
                                                 sessionConfiguration: .stubbed,
                                                 pinning: pinning,
                                                 retry: RetryConfiguration(limit: 3, baseDelay: 0.01, maxDelay: 0.01),
                                                 additionalInterceptors: [recorder])
        let session = AlamofireAPIClient.buildSession(configuration: configuration, additionalMonitors: [])

        StubProtocol.reset(
            responder: { _ in .init(statusCode: 200, data: Data(), headers: [:], delay: 0) },
            serverTrustChallenger: { task, request, answer in
                // URLSession calls the delegate on `rootQueue`, which `Session` requires.
                session.rootQueue.async {
                    let host = request.url!.host!
                    let trust = PinningFixtures.serverTrust(presenting: certificate, forHost: host, anchored: anchored)
                    session.delegate.urlSession(session.session, task: task,
                                                didReceive: ServerTrustChallenge.make(host: host, trust: trust)) { disposition, _ in
                        answer(disposition)
                    }
                }
            }
        )
        return AlamofireAPIClient(session: session, configuration: configuration)
    }
}
