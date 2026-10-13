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

/// What a request to a pinned host whose server trust is rejected throws, and that `retry` is not asked about it;
/// also that a host without pins beside a pinned one is left to URLSession's default handling.
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

    // MARK: - Key and host forms

    /// URLSession lowercases the host it names in the challenge, so a key is compared in canonical form.
    func testUppercaseKeyPinsHost() async throws {
        try await assertRejected(key: "PINNED.Test",
                                 presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.unrelated]),
                                 as: .pinMismatch)
    }

    /// The challenge names a host with a trailing dot with the dot, and the system trusts a certificate for the
    /// host without it; before 1.3.0 such a request was not pinned.
    func testKeyPinsHostWithTrailingDot() async throws {
        try await assertRejected(host: "\(PinningFixtures.host).",
                                 key: PinningFixtures.host,
                                 presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.unrelated]),
                                 as: .pinMismatch)
    }

    func testKeyWithTrailingDotPinsHost() async throws {
        try await assertRejected(key: "\(PinningFixtures.host).",
                                 presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.unrelated]),
                                 as: .pinMismatch)
    }

    /// The challenge names an IPv6 address without brackets. `leaf` is not issued for it, so the system rejects
    /// the trust; a host left unpinned would get default handling, which the stub answers with 200.
    func testBracketedIPv6KeyPinsAddress() async throws {
        try await assertRejected(host: "[::1]",
                                 key: "[0:0:0:0:0:0:0:1]",
                                 reportedHost: "::1",
                                 presenting: PinningFixtures.leaf,
                                 pin: .certificates([PinningFixtures.leaf]),
                                 as: .trustEvaluationFailed)
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

    // MARK: - Hosts without pins

    /// A host outside `pinning` gets default handling while another host is pinned, so the system evaluates its
    /// trust without pins.
    func testUnlistedHostBesidePinnedHostGetsDefaultHandling() async throws {
        try await assertDefaultHandling(pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf])])
    }

    func testExplicitlyUnpinnedHostBesidePinnedHostGetsDefaultHandling() async throws {
        try await assertDefaultHandling(pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf]),
                                                  Self.unpinnedHost: .none])
    }

    // MARK: - Accepted trust

    /// Guards the setup: a challenge the delegate accepts lets the request through.
    func testMatchingPinWithTrustedChainSucceeds() async throws {
        let recorder = RecordingInterceptor()
        let client = try makeClient(host: PinningFixtures.host,
                                    presenting: PinningFixtures.leaf,
                                    anchored: true,
                                    pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf])],
                                    recorder: recorder)

        try await client.sendVoid(GetEndpoint())

        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
    }

    // MARK: - Helpers

    /// A host without pins that `PinningFixtures.leaf` is issued for, so the system would trust its chain.
    private static let unpinnedHost = "localhost"

    /// Requests `unpinnedHost` and expects the delegate to leave its challenge to URLSession's default handling,
    /// neither accepting nor rejecting the trust itself.
    private func assertDefaultHandling(pinning: [String: PinningPolicy],
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let recorder = RecordingInterceptor()
        let dispositions = RecordedDispositions()
        let client = try makeClient(host: Self.unpinnedHost,
                                    presenting: PinningFixtures.leaf,
                                    anchored: true,
                                    pinning: pinning,
                                    recorder: recorder,
                                    dispositions: dispositions,
                                    file: file, line: line)

        try await client.sendVoid(GetEndpoint())

        XCTAssertEqual(dispositions.all, [.performDefaultHandling], file: file, line: line)
        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0, file: file, line: line)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1, file: file, line: line)
    }

    /// Requests `https://<host>/` with `pin` for `key`, or for `host` when `key` is `nil`, and expects a
    /// `PinningError` for `reportedHost`, or for `host` when it is `nil`.
    private func assertRejected(host: String = PinningFixtures.host,
                                key: String? = nil,
                                reportedHost: String? = nil,
                                presenting certificate: Data,
                                anchored: Bool = true,
                                pin: PinningPolicy,
                                as reason: PinningError.Reason,
                                file: StaticString = #filePath, line: UInt = #line,
                                request: (URLSessionAPIClient) async throws -> Void = {
                                    try await $0.sendVoid(GetEndpoint())
                                }) async throws {
        let recorder = RecordingInterceptor()
        let client = try makeClient(host: host, presenting: certificate, anchored: anchored,
                                    pinning: [key ?? host: pin], recorder: recorder)

        do {
            try await request(client)
            XCTFail("Expected APIError.transport(PinningError)", file: file, line: line)
        } catch APIError.transport(let error as PinningError) {
            XCTAssertEqual(error, PinningError(host: reportedHost ?? host, reason: reason),
                           file: file, line: line)
        } catch {
            XCTFail("Expected APIError.transport(PinningError), got \(error)", file: file, line: line)
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0, "retry must not be asked about a rejected server trust", file: file, line: line)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1, file: file, line: line)
    }

    /// A client for `https://<host>/` that allows three attempts, so a retried pin failure would be sent again.
    /// Every request's challenge presents `certificate`; `dispositions` records the delegate's answers.
    private func makeClient(host: String,
                            presenting certificate: Data,
                            anchored: Bool,
                            pinning: [String: PinningPolicy],
                            recorder: RecordingInterceptor,
                            dispositions: RecordedDispositions? = nil,
                            file: StaticString = #filePath, line: UInt = #line) throws -> URLSessionAPIClient {
        let configuration = NetworkConfiguration(baseURL: URL(string: "https://\(host)/")!,
                                                 sessionConfiguration: .stubbed,
                                                 pinning: pinning,
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
                    dispositions?.append(disposition)
                    answer(disposition)
                }
            }
        )
        return client
    }
}

/// The answers a client's delegate gave to the server trust challenges that `StubProtocol` passed to it.
private final class RecordedDispositions: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLSession.AuthChallengeDisposition] = []

    var all: [URLSession.AuthChallengeDisposition] { lock.withLock { recorded } }

    func append(_ disposition: URLSession.AuthChallengeDisposition) {
        lock.withLock { recorded.append(disposition) }
    }
}
