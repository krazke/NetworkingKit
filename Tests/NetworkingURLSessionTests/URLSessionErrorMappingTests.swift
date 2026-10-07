import XCTest
@testable import NetworkingURLSession
import NetworkingCore
import NetworkingTesting

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct EchoEndpoint: APIEndpoint {
    var path: String { "/echo" }
    var method: HTTPMethod { .get }
}

/// A JSON body whose encoding always fails.
private struct Unencodable: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "Unencodable"))
    }
}

private struct UnencodableEndpoint: APIEndpoint {
    var path: String { "/items" }
    var method: HTTPMethod { .post }
    var body: RequestBody { .json(Unencodable()) }
}

/// An interceptor whose `adapt` always throws `error`.
private struct ThrowingAdapter: RequestInterceptor {
    let error: any Error & Sendable
    func adapt(_ request: URLRequest) async throws -> URLRequest { throw error }
}

private struct CustomError: Error {}

/// An upload with a raw body. PUT, because Alamofire rejects a GET request with a body.
private struct RawUploadEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: HTTPMethod { .put }
    var body: RequestBody { .raw(Data("bytes".utf8), contentType: "application/octet-stream") }
}

private struct MultipartUploadEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: HTTPMethod { .put }
    var body: RequestBody { .multipart([.data(Data("bytes".utf8), name: "file", filename: "a.bin")]) }
}

/// The error each failure source maps to, checked through the real URLSession transport.
/// `AlamofireErrorMappingTests` checks the same mapping for the Alamofire transport.
final class URLSessionErrorMappingTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkingKitTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// Retries idempotent methods with a negligible delay.
    private static let fastRetry = RetryConfiguration(limit: 3, baseDelay: 0.001, maxDelay: 0.01, jitter: 1.0...1.0)

    private func makeClient(retry: RetryConfiguration = .none,
                            additional: [any RequestInterceptor] = []) -> URLSessionAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: retry,
            additionalInterceptors: additional
        )
        return URLSessionAPIClient(configuration: config)
    }

    private static func stub(_ stub: StubProtocol.Stub) {
        StubProtocol.reset { _ in stub }
    }

    private static func json(_ body: String) -> StubProtocol.Stub {
        .init(statusCode: 200, data: Data(body.utf8), headers: ["Content-Type": "application/json"], delay: 0)
    }

    /// A plain `URLResponse` with `body`, as a non-HTTP URL scheme would return.
    private static func nonHTTP(_ body: String) -> StubProtocol.Stub {
        var stub = json(body)
        stub.isHTTP = false
        return stub
    }

    /// Bodies of a non-HTTP response: empty, not decodable as `Echo`, and decodable.
    private static let nonHTTPBodies = ["", "not json", #"{"value":"ok"}"#]

    private static func assertInvalidResponse(_ operation: () async throws -> Void, _ message: String,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("\(message): expected error", file: file, line: line)
        } catch APIError.invalidResponse {
        } catch {
            XCTFail("\(message): unexpected \(error)", file: file, line: line)
        }
    }

    /// The error inside the transport's box for non-`Sendable` errors.
    private static func unboxed(_ error: any Error) -> any Error {
        (error as? SendableErrorBox)?.underlying ?? error
    }

    // MARK: - Before the request is sent

    func test_encodingFailure_throwsEncoding() async {
        do {
            _ = try await makeClient().send(UnencodableEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.encoding(let error) {
            XCTAssertTrue(Self.unboxed(error) is EncodingError, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertTrue(StubProtocol.recordedRequests.isEmpty)
    }

    func test_adaptThrowingAPIError_passesItThrough() async {
        Self.stub(Self.json(#"{"value":"ok"}"#))
        do {
            _ = try await makeClient(additional: [ThrowingAdapter(error: APIError.forbidden)])
                .send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.forbidden {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertTrue(StubProtocol.recordedRequests.isEmpty)
    }

    func test_adaptThrowingURLError_throwsTransport() async {
        Self.stub(Self.json(#"{"value":"ok"}"#))
        do {
            _ = try await makeClient(additional: [ThrowingAdapter(error: URLError(.notConnectedToInternet))])
                .send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.transport(let error) {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_adaptThrowingOtherError_throwsUnknown() async {
        Self.stub(Self.json(#"{"value":"ok"}"#))
        do {
            _ = try await makeClient(additional: [ThrowingAdapter(error: CustomError())])
                .send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.unknown(let error) {
            XCTAssertTrue(Self.unboxed(error) is CustomError, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_adaptThrowingCancellationError_throwsCancelled() async {
        Self.stub(Self.json(#"{"value":"ok"}"#))
        do {
            _ = try await makeClient(additional: [ThrowingAdapter(error: CancellationError())])
                .send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.cancelled {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    // MARK: - Transport

    func test_transportError_throwsTransportWithURLError() async {
        Self.stub(.failing(.notConnectedToInternet))
        do {
            _ = try await makeClient().send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.transport(let error) {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_transportError_whenRetriesRunOut_throwsTransportWithURLError() async {
        Self.stub(.failing(.timedOut))
        do {
            _ = try await makeClient(retry: Self.fastRetry).send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.transport(let error) {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 3)
    }

    func test_download_transportError_throwsTransportWithURLError() async {
        Self.stub(.failing(.networkConnectionLost))
        let target = directory.appendingPathComponent("file.bin")
        do {
            _ = try await makeClient().download(EchoEndpoint(), to: .fileURL(target))
            XCTFail("Expected error")
        } catch APIError.transport(let error) {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func test_cancellationWhileRequestIsInFlight_throwsCancelled() async throws {
        Self.stub(.init(statusCode: 200, data: Data(#"{"value":"ok"}"#.utf8),
                        headers: ["Content-Type": "application/json"], delay: 5))
        let client = makeClient()

        let task = Task { try await client.send(EchoEndpoint(), as: Echo.self) }
        try await StubProtocol.waitForRequests(1)
        task.cancel()
        let outcome = await task.result(timeout: .seconds(3))

        XCTAssertCancelled(outcome)
    }

    // MARK: - Response

    func test_nonHTTPResponse_throwsInvalidResponse() async {
        var stub = Self.json(#"{"value":"ok"}"#)
        stub.isHTTP = false
        Self.stub(stub)
        do {
            _ = try await makeClient().send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.invalidResponse {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    /// The response type is checked before the body, so neither an empty nor an undecodable body
    /// turns a non-HTTP response into `.decoding`.
    func test_nonHTTPResponse_send_throwsInvalidResponseForAnyBody() async {
        let client = makeClient()
        for body in Self.nonHTTPBodies {
            Self.stub(Self.nonHTTP(body))
            await Self.assertInvalidResponse({ _ = try await client.send(EchoEndpoint(), as: Echo.self) },
                                             "body \"\(body)\"")
        }
    }

    func test_nonHTTPResponse_sendVoid_throwsInvalidResponseForAnyBody() async {
        let client = makeClient()
        for body in Self.nonHTTPBodies {
            Self.stub(Self.nonHTTP(body))
            await Self.assertInvalidResponse({ try await client.sendVoid(EchoEndpoint()) }, "body \"\(body)\"")
        }
    }

    func test_nonHTTPResponse_upload_throwsInvalidResponseForAnyBody() async {
        let client = makeClient()
        let endpoints: [(String, any APIEndpoint)] = [("raw", RawUploadEndpoint()),
                                                      ("multipart", MultipartUploadEndpoint())]
        for (name, endpoint) in endpoints {
            for body in Self.nonHTTPBodies {
                Self.stub(Self.nonHTTP(body))
                await Self.assertInvalidResponse({ _ = try await client.upload(endpoint, as: Echo.self) },
                                                 "\(name), body \"\(body)\"")
            }
        }
    }

    func test_download_nonHTTPEmptyResponse_throwsInvalidResponseAndDiscardsTheFile() async throws {
        Self.stub(Self.nonHTTP(""))
        let target = directory.appendingPathComponent("file.bin")
        let downloadsBefore = try TemporaryFiles.downloads()

        await Self.assertInvalidResponse({ _ = try await makeClient().download(EchoEndpoint(), to: .fileURL(target)) },
                                         "download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try TemporaryFiles.downloads(), downloadsBefore)
    }

    func test_download_nonHTTPResponse_throwsInvalidResponseAndDiscardsTheFile() async throws {
        var stub = Self.json(#"{"value":"ok"}"#)
        stub.isHTTP = false
        Self.stub(stub)
        let target = directory.appendingPathComponent("file.bin")
        let downloadsBefore = try TemporaryFiles.downloads()

        do {
            _ = try await makeClient().download(EchoEndpoint(), to: .fileURL(target))
            XCTFail("Expected error")
        } catch APIError.invalidResponse {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try TemporaryFiles.downloads(), downloadsBefore)
    }

    func test_decodingFailure_throwsDecoding() async {
        Self.stub(Self.json(#"{"other":1}"#))
        do {
            _ = try await makeClient().send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.decoding(let error) {
            XCTAssertTrue(Self.unboxed(error) is DecodingError, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_emptyBody_throwsDecoding() async {
        Self.stub(.init(statusCode: 200, data: Data(), headers: [:], delay: 0))
        do {
            _ = try await makeClient().send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.decoding {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_noContent_throwsDecoding() async {
        Self.stub(.init(statusCode: 204, data: Data(), headers: [:], delay: 0))
        do {
            _ = try await makeClient().send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.decoding {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }
}
