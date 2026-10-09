import XCTest
import NetworkingURLSession
import NetworkingCore
import NetworkingTesting

private struct GetEndpoint: APIEndpoint {
    var path: String { "/items" }
    var method: HTTPMethod { .get }
}

/// PUT is retryable by default, so a request retried after a trust failure would be sent again.
private struct UploadEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: HTTPMethod { .put }
    var body: RequestBody { .multipart([.data(Data("x".utf8), name: "file")]) }
}

/// What a request to a host without pinning throws when the system rejects its server trust, and that `retry`
/// is not asked about it.
///
/// The TLS tests connect to `LoopbackTLSServer`. Its certificate is self-signed, so the system reports every case,
/// the expired certificate and the wrong host included, as `.serverCertificateUntrusted`; the other trust failure
/// codes need a chain the system trusts, and `StubProtocol` fails the request with them instead.
/// `AlamofireUnpinnedTrustTests` checks the same behavior for the Alamofire transport.
final class URLSessionUnpinnedTrustTests: XCTestCase {
    /// The codes URLSession fails a task with when the system rejects the server's certificate.
    private static let serverTrustCodes: Set<URLError.Code> = [
        .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
    ]

    /// Three attempts, so a retried trust failure would be sent again.
    private static let retry = RetryConfiguration(limit: 3, baseDelay: 0.01, maxDelay: 0.01)

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    override func tearDown() async throws {
        StubProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Real TLS connection

    func testUntrustedRootOverTLSThrowsURLErrorWithoutRetry() async throws {
        try await assertRejectedOverTLS(presenting: LoopbackTLSServer.certificate)
    }

    func testExpiredCertificateOverTLSThrowsURLErrorWithoutRetry() async throws {
        try await assertRejectedOverTLS(presenting: LoopbackTLSServer.expiredCertificate)
    }

    /// The certificate is issued for the IP address 127.0.0.1, not for `localhost`.
    func testCertificateForAnotherHostOverTLSThrowsURLErrorWithoutRetry() async throws {
        try await assertRejectedOverTLS(presenting: LoopbackTLSServer.certificate, host: "localhost")
    }

    /// With another host pinned, `PinningDelegate` answers this host's challenge with default handling.
    func testUntrustedRootWhileAnotherHostIsPinnedThrowsURLErrorWithoutRetry() async throws {
        try await assertRejectedOverTLS(presenting: LoopbackTLSServer.certificate,
                                        pinning: [PinningFixtures.host: .certificates([PinningFixtures.leaf])])
    }

    // MARK: - Trust failure codes

    func testBadDateIsNotRetried() async throws {
        try await assertNotRetried(.serverCertificateHasBadDate)
    }

    func testUntrustedCertificateIsNotRetried() async throws {
        try await assertNotRetried(.serverCertificateUntrusted)
    }

    func testUnknownRootIsNotRetried() async throws {
        try await assertNotRetried(.serverCertificateHasUnknownRoot)
    }

    func testNotYetValidCertificateIsNotRetried() async throws {
        try await assertNotRetried(.serverCertificateNotYetValid)
    }

    func testUploadTrustFailureIsNotRetried() async throws {
        try await assertNotRetried(.serverCertificateUntrusted) { client in
            _ = try await client.upload(UploadEndpoint(), as: Data.self, progress: nil)
        }
    }

    func testDownloadTrustFailureIsNotRetried() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpinned-trust-\(UUID().uuidString)")
        try await assertNotRetried(.serverCertificateUntrusted) { client in
            _ = try await client.download(GetEndpoint(), to: .fileURL(target), progress: nil)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Other TLS failures

    /// A failed TLS handshake can be transient, such as a connection reset by a middlebox, so it is still retried.
    func testSecureConnectionFailureIsStillRetried() async throws {
        StubProtocol.reset { _ in .failing(.secureConnectionFailed) }
        let recorder = RecordingInterceptor()
        let client = makeClient(baseURL: URL(string: "https://api.test/")!, sessionConfiguration: .stubbed,
                                recorder: recorder)

        do {
            try await client.sendVoid(GetEndpoint())
            XCTFail("Expected APIError.transport(URLError)")
        } catch APIError.transport(let error as URLError) {
            XCTAssertEqual(error.code, .secureConnectionFailed)
        } catch {
            XCTFail("Expected APIError.transport(URLError), got \(error)")
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 3)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 3)
    }

    // MARK: - Helpers

    private func assertRejectedOverTLS(presenting certificate: Data,
                                       host: String = LoopbackTLSServer.host,
                                       pinning: [String: PinningPolicy] = [:],
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let server = try await LoopbackTLSServer(presenting: certificate)
        defer { server.stop() }
        var components = try XCTUnwrap(URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false))
        components.host = host
        let recorder = RecordingInterceptor()
        let client = makeClient(baseURL: try XCTUnwrap(components.url), sessionConfiguration: .ephemeral,
                                pinning: pinning, recorder: recorder)

        try await assertTrustFailure(client, in: Self.serverTrustCodes, recorder: recorder, file: file, line: line) {
            try await $0.sendVoid(GetEndpoint())
        }
        XCTAssertEqual(server.connectionCount, 1, file: file, line: line)
    }

    private func assertNotRetried(_ code: URLError.Code,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  request: (URLSessionAPIClient) async throws -> Void = {
                                      try await $0.sendVoid(GetEndpoint())
                                  }) async throws {
        StubProtocol.reset { _ in .failing(code) }
        let recorder = RecordingInterceptor()
        let client = makeClient(baseURL: URL(string: "https://api.test/")!, sessionConfiguration: .stubbed,
                                recorder: recorder)

        try await assertTrustFailure(client, in: [code], recorder: recorder, file: file, line: line, request: request)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1, file: file, line: line)
    }

    private func assertTrustFailure(_ client: URLSessionAPIClient,
                                    in codes: Set<URLError.Code>,
                                    recorder: RecordingInterceptor,
                                    file: StaticString, line: UInt,
                                    request: (URLSessionAPIClient) async throws -> Void) async throws {
        do {
            try await request(client)
            XCTFail("Expected APIError.transport(URLError)", file: file, line: line)
        } catch APIError.transport(let error as URLError) {
            XCTAssertTrue(codes.contains(error.code), "Unexpected code: \(error.code.rawValue)", file: file, line: line)
        } catch {
            XCTFail("Expected APIError.transport(URLError), got \(error)", file: file, line: line)
        }

        let retries = await recorder.retryAttempts.count
        XCTAssertEqual(retries, 0, "retry must not be asked about a rejected server trust", file: file, line: line)
    }

    private func makeClient(baseURL: URL,
                            sessionConfiguration: URLSessionConfiguration,
                            pinning: [String: PinningPolicy] = [:],
                            recorder: RecordingInterceptor) -> URLSessionAPIClient {
        URLSessionAPIClient(configuration: NetworkConfiguration(baseURL: baseURL,
                                                                sessionConfiguration: sessionConfiguration,
                                                                pinning: pinning,
                                                                retry: Self.retry,
                                                                additionalInterceptors: [recorder]))
    }
}
