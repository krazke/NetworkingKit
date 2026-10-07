import XCTest
@testable import NetworkingURLSession
import NetworkingCore
import NetworkingTesting

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct EchoEndpoint: APIEndpoint {
    var path: String { "/echo" }
    var method: HTTPMethod { .get }
}

private struct CreateEndpoint: APIEndpoint {
    var path: String { "/items" }
    var method: HTTPMethod { .post }
    var body: RequestBody { .json(Echo(value: "new")) }
}

private struct MultipartEndpoint: APIEndpoint {
    var path: String { "/files" }
    var method: HTTPMethod { .post }
    var body: RequestBody {
        .multipart([.data(Data("payload".utf8), name: "file", filename: "a.txt", mimeType: "text/plain")])
    }
}

/// Non-2xx responses other than 401/403/404 must reach `APIError.server` with the response body,
/// checked through the real URLSession transport.
final class URLSessionServerErrorBodyTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    private func makeClient() -> URLSessionAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: .none
        )
        return URLSessionAPIClient(configuration: config)
    }

    /// A JSON:API error envelope in the shape App Store Connect returns.
    private static func envelope(status: Int) -> Data {
        Data(#"{"errors":[{"status":"\#(status)","code":"ENTITY_ERROR","title":"Rejected"}]}"#.utf8)
    }

    private static func stubError(status: Int) {
        StubProtocol.reset { _ in
            .init(statusCode: status, data: envelope(status: status),
                  headers: ["Content-Type": "application/json"], delay: 0)
        }
    }

    private func assertServerError(status expectedStatus: Int,
                                   file: StaticString = #filePath,
                                   line: UInt = #line,
                                   _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected error", file: file, line: line)
        } catch APIError.server(let statusCode, let data, _) {
            XCTAssertEqual(statusCode, expectedStatus, file: file, line: line)
            XCTAssertEqual(data, Self.envelope(status: expectedStatus), file: file, line: line)
        } catch {
            XCTFail("Unexpected: \(error)", file: file, line: line)
        }
    }

    func test_send_400_keepsBody() async {
        Self.stubError(status: 400)
        let client = makeClient()
        await assertServerError(status: 400) {
            _ = try await client.send(EchoEndpoint(), as: Echo.self)
        }
    }

    func test_send_409_keepsBody() async {
        Self.stubError(status: 409)
        let client = makeClient()
        await assertServerError(status: 409) {
            _ = try await client.send(CreateEndpoint(), as: Echo.self)
        }
    }

    func test_sendVoid_409_keepsBody() async {
        Self.stubError(status: 409)
        let client = makeClient()
        await assertServerError(status: 409) {
            try await client.sendVoid(CreateEndpoint())
        }
    }

    func test_upload_409_keepsBody() async {
        Self.stubError(status: 409)
        let client = makeClient()
        await assertServerError(status: 409) {
            _ = try await client.upload(CreateEndpoint(), as: Echo.self)
        }
    }

    func test_multipartUpload_400_keepsBody() async {
        Self.stubError(status: 400)
        let client = makeClient()
        await assertServerError(status: 400) {
            _ = try await client.upload(MultipartEndpoint(), as: Echo.self)
        }
    }

    // MARK: - Empty body

    /// An empty body gives `nil` rather than empty `Data`, so `data` is `nil` exactly when there is nothing to decode.
    func test_emptyBody_givesNilData() async {
        StubProtocol.reset { _ in .init(statusCode: 500, data: Data(), headers: [:], delay: 0) }
        let client = makeClient()
        let operations: [(String, () async throws -> Void)] = [
            ("send", { _ = try await client.send(EchoEndpoint(), as: Echo.self) }),
            ("sendVoid", { try await client.sendVoid(CreateEndpoint()) }),
            ("upload", { _ = try await client.upload(CreateEndpoint(), as: Echo.self) }),
            ("multipart upload", { _ = try await client.upload(MultipartEndpoint(), as: Echo.self) }),
        ]
        for (name, operation) in operations {
            do {
                try await operation()
                XCTFail("\(name): expected error")
            } catch APIError.server(let statusCode, let data, _) {
                XCTAssertEqual(statusCode, 500, name)
                XCTAssertNil(data, "\(name): \(data.map { "\($0.count) bytes" } ?? "nil")")
            } catch {
                XCTFail("\(name): unexpected \(error)")
            }
        }
    }
}
