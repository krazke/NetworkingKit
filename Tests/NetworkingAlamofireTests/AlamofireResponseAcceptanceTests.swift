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

private struct ArchiveEndpoint: APIEndpoint {
    var path: String { "/archive" }
    var method: HTTPMethod { .get }
    var headers: HTTPHeaders? { ["Accept": "application/zip"] }
}

/// Which 2xx responses the real Alamofire transport accepts: any `Content-Type`, whatever the request's
/// `Accept`, and an empty body for `sendVoid`. `URLSessionResponseAcceptanceTests` checks the same for the
/// URLSession transport.
final class AlamofireResponseAcceptanceTests: XCTestCase {
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

    private func makeClient() -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            retry: .none
        )
        return AlamofireAPIClient(configuration: config)
    }

    private static func stub(status: Int = 200, body: Data, contentType: String?) {
        StubProtocol.reset { _ in
            .init(statusCode: status, data: body,
                  headers: contentType.map { ["Content-Type": $0] } ?? [:], delay: 0)
        }
    }

    private static let echoJSON = Data(#"{"value":"ok"}"#.utf8)

    // MARK: - Content-Type

    func test_send_2xxWithNonJSONContentType_decodesBody() async throws {
        Self.stub(body: Self.echoJSON, contentType: "text/plain")
        let echo = try await makeClient().send(EchoEndpoint(), as: Echo.self)
        XCTAssertEqual(echo, Echo(value: "ok"))
    }

    func test_sendVoid_2xxWithNonJSONContentType_returns() async throws {
        Self.stub(body: Data("OK".utf8), contentType: "text/plain")
        try await makeClient().sendVoid(CreateEndpoint())
    }

    func test_upload_2xxWithNonJSONContentType_decodesBody() async throws {
        Self.stub(body: Self.echoJSON, contentType: "text/plain")
        let echo = try await makeClient().upload(CreateEndpoint(), as: Echo.self)
        XCTAssertEqual(echo, Echo(value: "ok"))
    }

    func test_multipartUpload_2xxWithNonJSONContentType_decodesBody() async throws {
        Self.stub(body: Self.echoJSON, contentType: "text/plain")
        let echo = try await makeClient().upload(MultipartEndpoint(), as: Echo.self)
        XCTAssertEqual(echo, Echo(value: "ok"))
    }

    func test_download_2xxWithBinaryContentType_placesFile() async throws {
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF])
        Self.stub(body: bytes, contentType: "application/zip")
        let target = directory.appendingPathComponent("file.zip")

        let url = try await makeClient().download(EchoEndpoint(), to: .fileURL(target))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func test_2xxWithoutContentType_returns() async throws {
        Self.stub(body: Data("OK".utf8), contentType: nil)
        try await makeClient().sendVoid(CreateEndpoint())
    }

    // MARK: - Accept

    func test_accept_defaultsToJSON() async throws {
        Self.stub(body: Self.echoJSON, contentType: "application/json")
        _ = try await makeClient().send(EchoEndpoint(), as: Echo.self)
        XCTAssertEqual(StubProtocol.recordedRequests.last?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    /// The endpoint's `Accept` is sent unchanged and does not restrict the response's `Content-Type`.
    func test_endpointAccept_isSentAndDoesNotRestrictContentType() async throws {
        let bytes = Data("not a zip".utf8)
        Self.stub(body: bytes, contentType: "text/plain")
        let target = directory.appendingPathComponent("file.zip")

        _ = try await makeClient().download(ArchiveEndpoint(), to: .fileURL(target))

        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(StubProtocol.recordedRequests.last?.value(forHTTPHeaderField: "Accept"), "application/zip")
    }

    // MARK: - Empty body

    func test_sendVoid_emptyBodyWithAny2xx_returns() async {
        for status in [200, 201, 202, 204, 205] {
            Self.stub(status: status, body: Data(), contentType: nil)
            do {
                try await makeClient().sendVoid(CreateEndpoint())
            } catch {
                XCTFail("\(status): unexpected \(error)")
            }
        }
    }
}
