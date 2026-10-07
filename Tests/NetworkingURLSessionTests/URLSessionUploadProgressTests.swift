import XCTest
@testable import NetworkingURLSession
import NetworkingCore
import NetworkingTesting

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct RawUploadEndpoint: APIEndpoint {
    var path: String { "/upload" }
    var method: HTTPMethod { .post }
    var body: RequestBody { .raw(Data(repeating: 0x2A, count: 1000), contentType: "application/octet-stream") }
}

private struct MultipartEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: HTTPMethod { .post }
    var body: RequestBody {
        .multipart([.data(Data("payload".utf8), name: "file", filename: "file.txt", mimeType: "text/plain")])
    }
}

/// `ProgressHandler` calls for `upload`. `StubProtocol` reports the body as sent through the task's delegate,
/// which URLSession itself does not do for a URLProtocol (see `StubProtocol.Stub.sentBodyFractions`).
final class URLSessionUploadProgressTests: XCTestCase {

    private static let ok = StubProtocol.Stub(statusCode: 200, data: Data(#"{"value":"ok"}"#.utf8),
                                              headers: ["Content-Type": "application/json"], delay: 0,
                                              sentBodyFractions: [0.5, 1])

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset { _ in Self.ok }
    }

    private func makeClient(retry: RetryConfiguration = .none) -> URLSessionAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: retry
        )
        return URLSessionAPIClient(configuration: config)
    }

    func test_upload_nonMultipart_reportsProgress() async throws {
        let progress = ProgressRecorder()

        let result = try await makeClient().upload(RawUploadEndpoint(), as: Echo.self, progress: progress.handler)

        XCTAssertEqual(result, Echo(value: "ok"))
        XCTAssertEqual(progress.values, [0.5, 1])
        XCTAssertEqual(StubProtocol.recordedBodies.last??.count, 1000)
    }

    func test_upload_multipart_reportsProgress() async throws {
        let progress = ProgressRecorder()

        _ = try await makeClient().upload(MultipartEndpoint(), as: Echo.self, progress: progress.handler)

        // The encoded body has an odd length, so half of it is not exactly 0.5.
        let values = progress.values
        XCTAssertEqual(values.count, 2, "\(values)")
        XCTAssertEqual(values.first ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(values.last, 1)
    }

    func test_upload_nonMultipart_retry_restartsProgressForEachAttempt() async throws {
        let attempts = LockedCounter()
        StubProtocol.reset { _ in
            attempts.increment() == 1
                ? .init(statusCode: 503, data: Data(), headers: [:], delay: 0, sentBodyFractions: [0.5, 1])
                : Self.ok
        }
        var retry = RetryConfiguration(limit: 2, baseDelay: 0.001, maxDelay: 0.01, jitter: 1.0...1.0)
        retry.retryableMethods = [.post]
        let progress = ProgressRecorder()

        let result = try await makeClient(retry: retry).upload(RawUploadEndpoint(), as: Echo.self,
                                                               progress: progress.handler)

        XCTAssertEqual(result, Echo(value: "ok"))
        XCTAssertEqual(StubProtocol.recordedRequests.count, 2)
        XCTAssertEqual(progress.values, [0.5, 1, 0.5, 1])
    }

    func test_upload_nonMultipart_cancelledInFlight_throwsCancelledWithoutCompletingProgress() async throws {
        StubProtocol.reset { _ in .init(statusCode: 200, data: Data(#"{"value":"ok"}"#.utf8),
                                        headers: ["Content-Type": "application/json"], delay: 30,
                                        sentBodyFractions: [0.5]) }
        let client = makeClient()
        let progress = ProgressRecorder()

        let task = Task { try await client.upload(RawUploadEndpoint(), as: Echo.self, progress: progress.handler) }
        defer { task.cancel() }
        try await progress.waitForValues(1)
        task.cancel()
        let outcome = await task.result(timeout: .seconds(5))

        XCTAssertCancelled(outcome)
        XCTAssertEqual(progress.values, [0.5])
    }
}

/// Collects the values reported to a `ProgressHandler`.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var handler: ProgressHandler {
        { [self] value in lock.withLock { recorded.append(value) } }
    }

    var values: [Double] { lock.withLock { recorded } }

    struct WaitTimeout: Error { let expected: Int; let received: [Double] }

    /// Polls until at least `count` values have been reported.
    ///
    /// - Throws: `WaitTimeout` when they have not been reported within `timeout`.
    func waitForValues(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while values.count < count {
            guard ContinuousClock.now < deadline else { throw WaitTimeout(expected: count, received: values) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
