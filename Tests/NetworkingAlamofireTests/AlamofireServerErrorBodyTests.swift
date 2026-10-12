import XCTest
@testable import NetworkingAlamofire
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

/// Non-2xx responses must reach their `APIError` case with the response body,
/// checked through the real Alamofire transport.
final class AlamofireServerErrorBodyTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    private func makeClient() -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: .none
        )
        return AlamofireAPIClient(configuration: config)
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

    // MARK: - 401, 403 and 404

    /// The body of the case `error` must be for `status`; fails the test for any other error.
    private static func statusCaseBody(_ error: any Error, status: Int, _ context: String,
                                       file: StaticString = #filePath, line: UInt = #line) -> Data? {
        switch (status, error as? APIError) {
        case (401, .unauthorized(let data)?), (403, .forbidden(let data)?), (404, .notFound(let data)?):
            return data
        default:
            XCTFail("\(context): unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    private static func operations(_ client: some APIClientProtocol) -> [(String, () async throws -> Void)] {
        [
            ("send", { _ = try await client.send(EchoEndpoint(), as: Echo.self) }),
            ("sendVoid", { try await client.sendVoid(CreateEndpoint()) }),
            ("upload", { _ = try await client.upload(CreateEndpoint(), as: Echo.self) }),
            ("multipart upload", { _ = try await client.upload(MultipartEndpoint(), as: Echo.self) }),
        ]
    }

    func test_401_403_404_keepBody() async {
        for status in [401, 403, 404] {
            Self.stubError(status: status)
            for (name, operation) in Self.operations(makeClient()) {
                let context = "\(status) \(name)"
                do {
                    try await operation()
                    XCTFail("\(context): expected error")
                } catch {
                    XCTAssertEqual(Self.statusCaseBody(error, status: status, context),
                                   Self.envelope(status: status), context)
                    XCTAssertEqual((error as? APIError)?.responseBody, Self.envelope(status: status), context)
                    XCTAssertEqual((error as? APIError)?.statusCode, status, context)
                }
            }
        }
    }

    func test_401_403_404_emptyBody_givesNilData() async {
        for status in [401, 403, 404] {
            StubProtocol.reset { _ in .init(statusCode: status, data: Data(), headers: [:], delay: 0) }
            for (name, operation) in Self.operations(makeClient()) {
                let context = "\(status) \(name)"
                do {
                    try await operation()
                    XCTFail("\(context): expected error")
                } catch {
                    XCTAssertNil(Self.statusCaseBody(error, status: status, context), context)
                }
            }
        }
    }

    /// `download` writes the body to a file it discards, so its status cases carry no body, as `.server` does.
    func test_download_401_403_404_carryNoBody() async {
        for status in [401, 403, 404] {
            Self.stubError(status: status)
            let context = "\(status) download"
            do {
                _ = try await makeClient()
                    .download(EchoEndpoint(), to: .temporary(filename: "NetworkingKitTests-\(UUID().uuidString)"))
                XCTFail("\(context): expected error")
            } catch {
                XCTAssertNil(Self.statusCaseBody(error, status: status, context), context)
            }
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
