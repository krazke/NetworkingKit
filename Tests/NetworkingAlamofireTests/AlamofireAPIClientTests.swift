import XCTest
@testable import NetworkingAlamofire
import NetworkingCore
import NetworkingTesting

private struct Echo: Codable, Sendable, Equatable { let value: String }

private struct EchoEndpoint: APIEndpoint {
    let value: String
    var path: String { "/echo" }
    var method: HTTPMethod { .get }
    var query: [URLQueryItem]? { [URLQueryItem(name: "v", value: value)] }
}

final class AlamofireAPIClientTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
    }

    private func makeClient(globalHeaders: [String: String] = [:],
                            retry: RetryConfiguration = .none) -> AlamofireAPIClient {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.test")!,
            sessionConfiguration: .stubbed,
            globalHeaders: globalHeaders,
            retry: retry
        )
        return AlamofireAPIClient(configuration: config)
    }

    func test_get_decodesResponse() async throws {
        StubProtocol.reset { _ in
            let data = try! JSONEncoder().encode(Echo(value: "hi"))
            return .init(statusCode: 200, data: data, headers: ["Content-Type": "application/json"], delay: 0)
        }
        let client = makeClient()
        let result: Echo = try await client.send(EchoEndpoint(value: "hi"), as: Echo.self)
        XCTAssertEqual(result, Echo(value: "hi"))
    }

    func test_404_throwsNotFound() async {
        StubProtocol.reset { _ in .init(statusCode: 404, data: Data(), headers: [:], delay: 0) }
        let client = makeClient()
        do {
            _ = try await client.send(EchoEndpoint(value: "x"), as: Echo.self)
            XCTFail("Expected error")
        } catch APIError.notFound {
            // ok
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_globalHeader_attached() async throws {
        StubProtocol.reset { _ in
            let data = try! JSONEncoder().encode(Echo(value: "ok"))
            return .init(statusCode: 200, data: data, headers: ["Content-Type": "application/json"], delay: 0)
        }
        let client = makeClient(globalHeaders: ["X-App-Platform": "ios"])
        _ = try await client.send(EchoEndpoint(value: "x"), as: Echo.self)
        let req = StubProtocol.recordedRequests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-App-Platform"), "ios")
    }

    func test_cancellationDuringRetryDelay_throwsCancelled() async throws {
        StubProtocol.reset { _ in .init(statusCode: 503, data: Data(), headers: [:], delay: 0) }
        let client = makeClient(retry: RetryConfiguration(limit: 3, baseDelay: 30, maxDelay: 30, jitter: 1.0...1.0))

        let task = Task { try await client.send(EchoEndpoint(value: "x"), as: Echo.self) }
        try await StubProtocol.waitForRequests(1)
        // Lets the transport receive the 503 and start waiting out the 30-second delay.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let outcome = await task.result(timeout: .seconds(5))

        XCTAssertCancelled(outcome)
        XCTAssertEqual(StubProtocol.recordedRequests.count, 1)
    }

}
