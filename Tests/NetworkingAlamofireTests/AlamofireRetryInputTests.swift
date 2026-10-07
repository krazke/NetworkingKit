import XCTest
@testable import NetworkingAlamofire
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

/// PUT is retryable by default, so a missed check would retry these requests.
private struct UnencodableEndpoint: APIEndpoint {
    var path: String { "/items/1" }
    var method: HTTPMethod { .put }
    var body: RequestBody { .json(Unencodable()) }
}

private struct GetWithBodyEndpoint: APIEndpoint {
    var path: String { "/echo" }
    var method: HTTPMethod { .get }
    var body: RequestBody { .raw(Data("body".utf8), contentType: "text/plain") }
}

private struct MultipartEndpoint: APIEndpoint {
    let parts: [MultipartPart]
    var method: HTTPMethod = .put
    var path: String { "/files" }
    var body: RequestBody { .multipart(parts) }
}

/// PUT is retryable by default, so a missed check would retry these requests.
private struct PutEndpoint: APIEndpoint {
    var body: RequestBody = .empty
    var path: String { "/items/1" }
    var method: HTTPMethod { .put }
}

/// Records what the transport passes to `retry` and always declines, so the chain's
/// `RetryInterceptor` still makes the decision. Optionally makes `adapt` throw.
private actor RetryInputRecorder: RequestInterceptor {
    struct Call: Sendable {
        let statusCode: Int?
        let error: any Error & Sendable
        let attempt: Int
    }

    private(set) var calls: [Call] = []
    private(set) var adaptCount = 0
    private let adaptError: (any Error & Sendable)?

    init(adaptError: (any Error & Sendable)? = nil) { self.adaptError = adaptError }

    func adapt(_ request: URLRequest) async throws -> URLRequest {
        adaptCount += 1
        if let adaptError { throw adaptError }
        return request
    }

    func retry(_ request: URLRequest,
               response: HTTPURLResponse?,
               error: any Error & Sendable,
               attempt: Int) async -> RetryDecision {
        calls.append(Call(statusCode: response?.statusCode, error: error, attempt: attempt))
        return .doNotRetry
    }
}

/// What `RequestInterceptor.retry` receives from the real Alamofire transport.
/// `URLSessionRetryInputTests` checks the same contract for the URLSession transport.
final class AlamofireRetryInputTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    /// Three attempts with a negligible delay.
    private static let fastRetry = RetryConfiguration(limit: 3, baseDelay: 0.001, maxDelay: 0.01, jitter: 1.0...1.0)

    private func makeClient(_ recorder: RetryInputRecorder,
                            retry: RetryConfiguration = fastRetry) -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: retry,
            additionalInterceptors: [recorder]
        )
        return AlamofireAPIClient(configuration: config)
    }

    private static func stub(_ stub: StubProtocol.Stub) {
        StubProtocol.reset { _ in stub }
    }

    private static func status(_ code: Int, body: String = "") -> StubProtocol.Stub {
        .init(statusCode: code, data: Data(body.utf8), headers: [:], delay: 0)
    }

    private static func assertServerError(_ error: any Error, statusCode: Int, data: Data?,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard case .server(let code, let body, _)? = error as? APIError else {
            return XCTFail("Expected APIError.server, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(code, statusCode, file: file, line: line)
        XCTAssertEqual(body, data, file: file, line: line)
    }

    private static func assertURLError(_ error: any Error, _ code: URLError.Code,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? URLError)?.code, code, "\(error)", file: file, line: line)
    }

    // MARK: - Before the request is sent

    func test_requestBuildFailure_isNotRetriedAndDoesNotReachRetry() async {
        let recorder = RetryInputRecorder()
        do {
            try await makeClient(recorder).sendVoid(UnencodableEndpoint())
            XCTFail("Expected error")
        } catch APIError.encoding {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(StubProtocol.recordedRequests.isEmpty)
    }

    func test_adaptFailure_isNotRetriedAndDoesNotReachRetry() async {
        Self.stub(Self.status(200))
        let recorder = RetryInputRecorder(adaptError: URLError(.notConnectedToInternet))
        do {
            try await makeClient(recorder).sendVoid(EchoEndpoint())
            XCTFail("Expected error")
        } catch APIError.transport(let error) {
            Self.assertURLError(error, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        let adaptCount = await recorder.adaptCount
        let calls = await recorder.calls
        XCTAssertEqual(adaptCount, 1)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(StubProtocol.recordedRequests.isEmpty)
    }

    func test_multipartBodyFailure_isNotRetriedAndDoesNotReachRetry() async {
        Self.stub(Self.status(200))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).bin")
        let recorder = RetryInputRecorder()
        do {
            _ = try await makeClient(recorder).upload(MultipartEndpoint(parts: [.file(missing, name: "file")]),
                                                      as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.encoding(let error) {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile, "\(error)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(StubProtocol.recordedRequests.isEmpty)
    }

    /// Alamofire rejects a GET request with a body before sending it (`urlRequestValidationFailed`).
    func test_getWithBody_isNotRetriedAndDoesNotReachRetry() async {
        Self.stub(Self.status(200))
        let recorder = RetryInputRecorder()
        do {
            try await makeClient(recorder).sendVoid(GetWithBodyEndpoint())
            XCTFail("Expected error")
        } catch APIError.transport {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(StubProtocol.recordedRequests.isEmpty)
    }

    // MARK: - Status

    func test_statusFailure_passesResponseAndServerErrorWithBody_oncePerAttempt() async {
        Self.stub(Self.status(503, body: "busy"))
        let recorder = RetryInputRecorder()
        do {
            try await makeClient(recorder).sendVoid(EchoEndpoint())
            XCTFail("Expected error")
        } catch {
            Self.assertServerError(error, statusCode: 503, data: Data("busy".utf8))
        }
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(calls.map(\.statusCode), [503, 503, 503])
        for call in calls {
            Self.assertServerError(call.error, statusCode: 503, data: Data("busy".utf8))
        }
    }

    func test_statusFailureWithEmptyBody_passesServerErrorWithNilData() async throws {
        Self.stub(Self.status(503))
        let parts: [MultipartPart] = [.data(Data("bytes".utf8), name: "file", filename: "a.bin", mimeType: nil)]
        let operations: [(String, (APIClientProtocol) async throws -> Void)] = [
            ("sendVoid", { try await $0.sendVoid(EchoEndpoint()) }),
            ("multipart upload", { _ = try await $0.upload(MultipartEndpoint(parts: parts), as: Echo.self) }),
        ]
        for (name, operation) in operations {
            let recorder = RetryInputRecorder()
            do {
                try await operation(makeClient(recorder, retry: .none))
                XCTFail("\(name): expected error")
            } catch {
                Self.assertServerError(error, statusCode: 503, data: nil)
            }
            let calls = await recorder.calls
            XCTAssertEqual(calls.map(\.statusCode), [503], name)
            Self.assertServerError(try XCTUnwrap(calls.first, name).error, statusCode: 503, data: nil)
        }
    }

    func test_401_403_404_passTheirAPIError() async {
        for code in [401, 403, 404] {
            Self.stub(Self.status(code, body: "denied"))
            let recorder = RetryInputRecorder()
            _ = try? await makeClient(recorder, retry: .none).sendVoid(EchoEndpoint())

            let calls = await recorder.calls
            XCTAssertEqual(calls.map(\.statusCode), [code])
            switch (code, calls.first?.error as? APIError) {
            case (401, .unauthorized?), (403, .forbidden?), (404, .notFound?):
                break
            default:
                XCTFail("Unexpected error for \(code): \(String(describing: calls.first?.error))")
            }
        }
    }

    func test_multipartUploadStatusFailure_passesServerErrorWithBody() async throws {
        Self.stub(Self.status(500, body: "oops"))
        let recorder = RetryInputRecorder()
        let parts: [MultipartPart] = [.data(Data("bytes".utf8), name: "file", filename: "a.bin", mimeType: nil)]
        _ = try? await makeClient(recorder).upload(MultipartEndpoint(parts: parts, method: .post), as: Echo.self)

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.statusCode), [500])
        Self.assertServerError(try XCTUnwrap(calls.first).error, statusCode: 500, data: Data("oops".utf8))
    }

    func test_downloadStatusFailure_passesServerErrorWithoutBody() async throws {
        Self.stub(Self.status(503, body: "busy"))
        let recorder = RetryInputRecorder()
        _ = try? await makeClient(recorder, retry: .none)
            .download(EchoEndpoint(), to: .temporary(filename: "NetworkingKitTests-\(UUID().uuidString)"))

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.statusCode), [503])
        Self.assertServerError(try XCTUnwrap(calls.first).error, statusCode: 503, data: nil)
    }

    // MARK: - Transport

    func test_transportFailure_passesNilResponseAndURLError() async {
        Self.stub(.failing(.timedOut))
        let recorder = RetryInputRecorder()
        _ = try? await makeClient(recorder).sendVoid(EchoEndpoint())

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(calls.map(\.statusCode), [nil, nil, nil])
        calls.forEach { Self.assertURLError($0.error, .timedOut) }
    }

    func test_transportFailureAfterStatusFailure_passesNilResponse() async throws {
        let attempts = LockedCounter()
        StubProtocol.reset { _ in attempts.increment() == 1 ? Self.status(503, body: "busy") : .failing(.timedOut) }
        let recorder = RetryInputRecorder()
        do {
            try await makeClient(recorder).sendVoid(EchoEndpoint())
            XCTFail("Expected error")
        } catch APIError.transport(let error) {
            Self.assertURLError(error, .timedOut)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.statusCode), [503, nil, nil])
        Self.assertServerError(try XCTUnwrap(calls.first).error, statusCode: 503, data: Data("busy".utf8))
        calls.dropFirst().forEach { Self.assertURLError($0.error, .timedOut) }
    }

    // MARK: - After the response

    func test_decodingFailure_doesNotReachRetry() async {
        Self.stub(.init(statusCode: 200, data: Data("{}".utf8), headers: ["Content-Type": "application/json"], delay: 0))
        let recorder = RetryInputRecorder()
        do {
            _ = try await makeClient(recorder).send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.decoding {
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// An empty body is the case in which a response serializer fails in the Alamofire transport.
    func test_nonHTTPResponse_isNotRetriedAndDoesNotReachRetry() async throws {
        var nonHTTP = Self.status(200)
        nonHTTP.isHTTP = false
        let stub = nonHTTP
        let parts: [MultipartPart] = [.data(Data("bytes".utf8), name: "file", filename: "a.bin", mimeType: nil)]
        let raw = PutEndpoint(body: .raw(Data("bytes".utf8), contentType: "application/octet-stream"))
        let operations: [(String, (APIClientProtocol) async throws -> Void)] = [
            ("send", { _ = try await $0.send(PutEndpoint(), as: Echo.self) }),
            ("sendVoid", { try await $0.sendVoid(PutEndpoint()) }),
            ("raw upload", { _ = try await $0.upload(raw, as: Echo.self) }),
            ("multipart upload", { _ = try await $0.upload(MultipartEndpoint(parts: parts), as: Echo.self) }),
            ("download", {
                _ = try await $0.download(PutEndpoint(), to: .temporary(filename: "NetworkingKitTests-\(UUID().uuidString)"))
            }),
        ]
        for (name, operation) in operations {
            StubProtocol.reset { _ in stub }
            let recorder = RetryInputRecorder()
            do {
                try await operation(makeClient(recorder))
                XCTFail("\(name): expected error")
            } catch APIError.invalidResponse {
            } catch {
                XCTFail("\(name): unexpected \(error)")
            }
            let calls = await recorder.calls
            XCTAssertTrue(calls.isEmpty, name)
            XCTAssertEqual(StubProtocol.recordedRequests.count, 1, name)
        }
    }

    func test_cancellation_doesNotReachRetry() async throws {
        Self.stub(.init(statusCode: 200, data: Data(), headers: [:], delay: 5))
        let recorder = RetryInputRecorder()
        let client = makeClient(recorder)

        let task = Task { try await client.sendVoid(EchoEndpoint()) }
        try await StubProtocol.waitForRequests(1)
        task.cancel()
        let outcome = await task.result(timeout: .seconds(3))

        XCTAssertCancelled(outcome)
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }
}
