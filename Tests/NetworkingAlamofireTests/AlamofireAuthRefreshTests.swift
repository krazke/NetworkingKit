import XCTest
@testable import NetworkingAlamofire
import NetworkingCore
import NetworkingTesting

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct EchoEndpoint: APIEndpoint {
    var path: String { "/echo" }
    var method: HTTPMethod { .get }
}

private struct AvatarUploadEndpoint: APIEndpoint {
    var path: String { "/avatar" }
    var method: HTTPMethod { .post }
    var body: RequestBody {
        .multipart([.data(Data("avatar-bytes".utf8), name: "avatar", filename: "avatar.jpg", mimeType: "image/jpeg")])
    }
}

private struct FileEndpoint: APIEndpoint {
    var path: String { "/files/1" }
    var method: HTTPMethod { .get }
}

/// 401 → refresh → retry through the real Alamofire transport.
final class AlamofireAuthRefreshTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    private func makeClient(server: RotatingAuthServer,
                            store: MockTokenStore,
                            retry: RetryConfiguration = .none) -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: retry,
            tokenStore: store,
            refreshAction: { try await server.refresh($0) }
        )
        return AlamofireAPIClient(configuration: config)
    }

    /// Answers 200 only to requests that carry `validToken`, 401 otherwise.
    private static func respond(to request: URLRequest,
                                validToken: String,
                                delay: TimeInterval = 0) -> StubProtocol.Stub {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(validToken)" else {
            return .init(statusCode: 401, data: Data(), headers: [:], delay: delay)
        }
        let data = try! JSONEncoder().encode(Echo(value: "ok"))
        return .init(statusCode: 200, data: data, headers: ["Content-Type": "application/json"], delay: delay)
    }

    private static let initialTokens = AuthTokens(accessToken: "access-0", refreshToken: "refresh-0")

    func test_401_refreshesAndRetriesWithNewToken() async throws {
        StubProtocol.reset { Self.respond(to: $0, validToken: "access-1") }
        let server = RotatingAuthServer()
        let client = makeClient(server: server, store: MockTokenStore(initial: Self.initialTokens))

        let result: Echo = try await client.send(EchoEndpoint(), as: Echo.self)

        XCTAssertEqual(result, Echo(value: "ok"))
        XCTAssertEqual(StubProtocol.recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-0", "Bearer access-1"])
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_503Then401_refreshesAndSucceeds() async throws {
        let attempts = LockedCounter()
        StubProtocol.reset { request in
            if attempts.increment() == 1 {
                return .init(statusCode: 503, data: Data(), headers: [:], delay: 0)
            }
            return Self.respond(to: request, validToken: "access-1")
        }
        let server = RotatingAuthServer()
        let client = makeClient(server: server,
                                store: MockTokenStore(initial: Self.initialTokens),
                                retry: RetryConfiguration(limit: 5, baseDelay: 0.001, maxDelay: 0.01,
                                                          jitter: 1.0...1.0))

        let result: Echo = try await client.send(EchoEndpoint(), as: Echo.self)

        XCTAssertEqual(result, Echo(value: "ok"))
        XCTAssertEqual(attempts.value, 3)
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_concurrent401s_refreshOnce() async throws {
        // Staggered responses: some 401s for the old token arrive after the refresh has finished.
        let arrivals = LockedCounter()
        StubProtocol.reset { request in
            Self.respond(to: request, validToken: "access-1", delay: 0.015 * Double(arrivals.increment()))
        }
        let server = RotatingAuthServer()
        let client = makeClient(server: server, store: MockTokenStore(initial: Self.initialTokens))

        let results = try await withThrowingTaskGroup(of: Echo.self) { group in
            for _ in 0..<5 {
                group.addTask { try await client.send(EchoEndpoint(), as: Echo.self) }
            }
            return try await group.reduce(into: [Echo]()) { $0.append($1) }
        }

        XCTAssertEqual(results, Array(repeating: Echo(value: "ok"), count: 5))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
    }

    func test_401_multipartUpload_refreshesAndResendsTheSameBody() async throws {
        StubProtocol.reset { Self.respond(to: $0, validToken: "access-1") }
        let server = RotatingAuthServer()
        let client = makeClient(server: server, store: MockTokenStore(initial: Self.initialTokens))
        let bodiesBefore = try TemporaryFiles.multipartBodies()

        let result: Echo = try await client.upload(AvatarUploadEndpoint(), as: Echo.self)

        XCTAssertEqual(result, Echo(value: "ok"))
        XCTAssertEqual(StubProtocol.recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-0", "Bearer access-1"])
        let bodies = StubProtocol.recordedBodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        XCTAssertTrue(String(decoding: try XCTUnwrap(bodies.last ?? nil), as: UTF8.self).contains("avatar-bytes"))
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(try TemporaryFiles.multipartBodies(), bodiesBefore)
    }

    func test_401_download_refreshesAndPlacesOnlyTheSuccessfulBody() async throws {
        StubProtocol.reset { Self.respond(to: $0, validToken: "access-1") }
        let server = RotatingAuthServer()
        let client = makeClient(server: server, store: MockTokenStore(initial: Self.initialTokens))
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkingKitTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: target) }
        let downloadsBefore = try TemporaryFiles.downloads()

        let url = try await client.download(FileEndpoint(), to: .fileURL(target))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try JSONDecoder().decode(Echo.self, from: Data(contentsOf: target)), Echo(value: "ok"))
        XCTAssertEqual(StubProtocol.recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-0", "Bearer access-1"])
        let refreshCount = await server.refreshCount
        XCTAssertEqual(refreshCount, 1)
        try XCTExpectFailure(KnownIssue.retriedDownloadsLeak) {
            XCTAssertEqual(try TemporaryFiles.downloads(), downloadsBefore)
        }
    }

    func test_rejectedRefresh_throwsUnauthorized() async {
        StubProtocol.reset { Self.respond(to: $0, validToken: "access-1") }
        let server = RotatingAuthServer()
        let revoked = AuthTokens(accessToken: "access-0", refreshToken: "revoked")
        let client = makeClient(server: server, store: MockTokenStore(initial: revoked))

        do {
            _ = try await client.send(EchoEndpoint(), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.unauthorized {
            // ok
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
    }
}

final class LockedCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }

    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
