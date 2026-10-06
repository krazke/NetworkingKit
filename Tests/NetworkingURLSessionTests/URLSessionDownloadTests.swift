import XCTest
@testable import NetworkingURLSession
import NetworkingCore
import NetworkingTesting

private struct FileEndpoint: APIEndpoint {
    var path: String { "/files/1" }
    var method: HTTPMethod { .get }
}

/// Overwrite semantics of every `DownloadDestination` case, checked through the real URLSession transport.
final class URLSessionDownloadTests: XCTestCase {
    private var directory: URL!
    private var cleanup: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkingKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup = [directory]
    }

    override func tearDown() async throws {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        try await super.tearDown()
    }

    /// Retries idempotent methods with a negligible delay.
    private static let fastRetry = RetryConfiguration(limit: 3, baseDelay: 0.001, maxDelay: 0.01, jitter: 1.0...1.0)

    private func makeClient(retry: RetryConfiguration = .none) -> URLSessionAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: retry
        )
        return URLSessionAPIClient(configuration: config)
    }

    /// Responds with `Content-Type: application/json`: Alamofire's `validate()` also checks it
    /// against the default `Accept: application/json`, which is not what these tests cover.
    private static func stub(status: Int, body: String) {
        StubProtocol.reset { _ in
            .init(statusCode: status, data: Data(body.utf8),
                  headers: ["Content-Type": "application/json"], delay: 0)
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func assertFileExistsError(file: StaticString = #filePath,
                                       line: UInt = #line,
                                       _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected error", file: file, line: line)
        } catch APIError.transport(let error) {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists, "\(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected: \(error)", file: file, line: line)
        }
    }

    func test_fileURL_replacesExistingFile() async throws {
        let target = directory.appendingPathComponent("file.bin")
        try Self.write("old", to: target)
        Self.stub(status: 200, body: "new")

        let url = try await makeClient().download(FileEndpoint(), to: .fileURL(target))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Self.contents(of: target), "new")
    }

    func test_fileURL_withoutRemoveIfExists_failsAndKeepsExistingFile() async throws {
        let target = directory.appendingPathComponent("file.bin")
        try Self.write("old", to: target)
        Self.stub(status: 200, body: "new")
        let client = makeClient()

        await assertFileExistsError {
            _ = try await client.download(FileEndpoint(), to: .fileURL(target, removeIfExists: false))
        }
        XCTAssertEqual(try Self.contents(of: target), "old")
    }

    func test_fileURL_withoutRemoveIfExists_writesNewFile() async throws {
        let target = directory.appendingPathComponent("nested/file.bin")
        Self.stub(status: 200, body: "new")

        let url = try await makeClient().download(FileEndpoint(),
                                                  to: .fileURL(target, removeIfExists: false))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Self.contents(of: target), "new")
    }

    func test_documents_replacesExistingFile() async throws {
        let folder = "NetworkingKitTests-\(UUID().uuidString)"
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        cleanup.append(documents.appendingPathComponent(folder))
        let target = documents.appendingPathComponent("\(folder)/file.bin")
        try Self.write("old", to: target)
        Self.stub(status: 200, body: "new")

        let url = try await makeClient().download(FileEndpoint(), to: .documents(subpath: "\(folder)/file.bin"))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Self.contents(of: target), "new")
    }

    func test_temporary_replacesExistingFile() async throws {
        let filename = "NetworkingKitTests-\(UUID().uuidString).bin"
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        cleanup.append(target)
        try Self.write("old", to: target)
        Self.stub(status: 200, body: "new")

        let url = try await makeClient().download(FileEndpoint(), to: .temporary(filename: filename))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Self.contents(of: target), "new")
    }

    func test_httpError_keepsExistingFile() async throws {
        let target = directory.appendingPathComponent("file.bin")
        try Self.write("old", to: target)
        Self.stub(status: 404, body: "error body")

        do {
            _ = try await makeClient().download(FileEndpoint(), to: .fileURL(target))
            XCTFail("Expected error")
        } catch APIError.notFound {
            // ok
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(try Self.contents(of: target), "old")
    }

    func test_existingDirectory_isNotReplaced() async throws {
        let target = directory.appendingPathComponent("folder")
        let child = target.appendingPathComponent("keep.txt")
        try Self.write("keep", to: child)
        Self.stub(status: 200, body: "new")
        let client = makeClient()

        await assertFileExistsError {
            _ = try await client.download(FileEndpoint(), to: .fileURL(target))
        }
        XCTAssertEqual(try Self.contents(of: child), "keep")
    }

    // MARK: - Retry

    func test_retryable503_isRetriedAndOnlyTheSuccessfulBodyIsPlaced() async throws {
        let target = directory.appendingPathComponent("file.bin")
        try Self.write("old", to: target)
        let attempts = LockedCounter()
        StubProtocol.reset { _ in
            let status = attempts.increment() == 1 ? 503 : 200
            return .init(statusCode: status, data: Data(status == 200 ? "new".utf8 : "unavailable".utf8),
                         headers: ["Content-Type": "application/json"], delay: 0)
        }
        let downloadsBefore = try TemporaryFiles.downloads()

        let url = try await makeClient(retry: Self.fastRetry).download(FileEndpoint(), to: .fileURL(target))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Self.contents(of: target), "new")
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(try TemporaryFiles.downloads(), downloadsBefore)
    }

    func test_retryable503_whenRetriesRunOut_keepsExistingFileAndDiscardsEveryAttempt() async throws {
        let target = directory.appendingPathComponent("file.bin")
        try Self.write("old", to: target)
        Self.stub(status: 503, body: "unavailable")
        let downloadsBefore = try TemporaryFiles.downloads()

        do {
            _ = try await makeClient(retry: Self.fastRetry).download(FileEndpoint(), to: .fileURL(target))
            XCTFail("Expected error")
        } catch APIError.server(let statusCode, _, _) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, Self.fastRetry.limit)
        XCTAssertEqual(try Self.contents(of: target), "old")
        XCTAssertEqual(try TemporaryFiles.downloads(), downloadsBefore)
    }

    func test_cancellationDuringRetryDelay_throwsCancelled() async throws {
        let target = directory.appendingPathComponent("file.bin")
        Self.stub(status: 503, body: "unavailable")
        let client = makeClient(retry: RetryConfiguration(limit: 3, baseDelay: 30, maxDelay: 30, jitter: 1.0...1.0))
        let downloadsBefore = try TemporaryFiles.downloads()

        let task = Task { try await client.download(FileEndpoint(), to: .fileURL(target)) }
        try await StubProtocol.waitForRequests(1)
        // Lets the transport receive the 503 and start waiting out the 30-second delay.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let outcome = await task.result(timeout: .seconds(5))

        XCTAssertCancelled(outcome)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try TemporaryFiles.downloads(), downloadsBefore)
    }
}
