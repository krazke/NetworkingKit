import XCTest
@testable import NetworkingCore
import NetworkingTesting

private struct Horse: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

private struct GetHorse: APIEndpoint {
    let horseId: Int
    var path: String { "/horses/\(horseId)" }
    var method: HTTPMethod { .get }
}

private struct DeleteHorse: APIEndpoint {
    let horseId: Int
    var path: String { "/horses/\(horseId)" }
    var method: HTTPMethod { .delete }
}

final class MockAPIClientTests: XCTestCase {

    func test_send_returnsStubbedValue() async throws {
        let client = MockAPIClient()
        await client.stub(path: "/horses/1", with: .success(Horse(id: 1, name: "Bucephalus")))
        let result: Horse = try await client.send(GetHorse(horseId: 1), as: Horse.self)
        XCTAssertEqual(result, Horse(id: 1, name: "Bucephalus"))
    }

    func test_send_throwsStubbedFailure() async {
        let client = MockAPIClient()
        await client.stub(path: "/horses/1", with: .failure(.notFound))
        do {
            _ = try await client.send(GetHorse(horseId: 1), as: Horse.self)
            XCTFail("Expected error")
        } catch APIError.notFound {
            // ok
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_recordedCalls_tracksAllInvocations() async throws {
        let client = MockAPIClient()
        await client.stub(path: "/horses/1", with: .success(Horse(id: 1, name: "B")))
        await client.stub(path: "/horses/2", with: .void)

        _ = try await client.send(GetHorse(horseId: 1), as: Horse.self)
        try await client.sendVoid(DeleteHorse(horseId: 2))

        let calls = await client.recordedCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].path, "/horses/1")
        XCTAssertEqual(calls[0].kind, .send)
        XCTAssertEqual(calls[1].path, "/horses/2")
        XCTAssertEqual(calls[1].kind, .sendVoid)
    }

    func test_delayed_stub_introducesLatency() async throws {
        let client = MockAPIClient()
        await client.stub(path: "/horses/1",
                          with: .delayed(0.05, .success(Horse(id: 1, name: "B"))))
        let start = Date()
        _ = try await client.send(GetHorse(horseId: 1), as: Horse.self)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
    }

    /// `download(_:to:)` without `progress` is a convenience overload that forwards to the requirement.
    func test_download_withoutProgress_forwardsToRequirement() async throws {
        let mock = MockAPIClient()
        await mock.stub(path: "/horses/1", with: .successData(Data("file".utf8)))
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkingKitTests-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: target) }

        let client: any APIClientProtocol = mock
        let url = try await client.download(GetHorse(horseId: 1), to: .fileURL(target))

        XCTAssertEqual(url, target)
        XCTAssertEqual(try Data(contentsOf: target), Data("file".utf8))
        let calls = await mock.recordedCalls
        XCTAssertEqual(calls.map(\.kind), [.download])
    }
}
