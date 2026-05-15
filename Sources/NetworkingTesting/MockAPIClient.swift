import Foundation
import NetworkingCore

/// Программируемая реализация APIClientProtocol для unit-тестов.
///
/// Использование:
/// ```swift
/// let client = MockAPIClient()
/// await client.stub(path: "/horses", with: .success(MockHorses.list))
/// let result = try await service.list()
/// let calls = await client.recordedCalls
/// ```
public actor MockAPIClient: APIClientProtocol {
    public struct Call: Sendable, Hashable {
        public let path: String
        public let method: HTTPMethod
        public let kind: Kind
        public enum Kind: String, Sendable, Hashable { case send, sendVoid, upload, download }
    }

    public private(set) var recordedCalls: [Call] = []
    private var stubs: [String: StubResponse] = [:]
    private var defaultStub: StubResponse = .failure(.notFound)
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(decoder: JSONDecoder = MockAPIClient.defaultDecoder(),
                encoder: JSONEncoder = MockAPIClient.defaultEncoder()) {
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: - Stub management

    public func stub(path: String, with response: StubResponse) {
        stubs[path] = response
    }

    public func setDefaultStub(_ response: StubResponse) {
        defaultStub = response
    }

    public func reset() {
        recordedCalls.removeAll()
        stubs.removeAll()
        defaultStub = .failure(.notFound)
    }

    public func calls(for path: String) -> [Call] {
        recordedCalls.filter { $0.path == path }
    }

    // MARK: - APIClientProtocol

    nonisolated public func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                                          as type: T.Type,
                                                          decoder: JSONDecoder?) async throws -> T {
        let response = await record(endpoint, kind: .send)
        return try await decode(response, as: T.self, override: decoder)
    }

    nonisolated public func sendVoid(_ endpoint: APIEndpoint) async throws {
        let response = await record(endpoint, kind: .sendVoid)
        try await applyVoid(response)
    }

    nonisolated public func upload<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                                            as type: T.Type,
                                                            decoder: JSONDecoder?,
                                                            progress: ProgressHandler?) async throws -> T {
        progress?(0.0); progress?(1.0)
        let response = await record(endpoint, kind: .upload)
        return try await decode(response, as: T.self, override: decoder)
    }

    nonisolated public func download(_ endpoint: APIEndpoint,
                                     to destination: DownloadDestination,
                                     progress: ProgressHandler?) async throws -> URL {
        progress?(0.0); progress?(1.0)
        let response = await record(endpoint, kind: .download)
        let target = try destination.resolve()
        switch await resolveResponse(response) {
        case .data(let data):
            try data.write(to: target)
            return target
        case .void:
            FileManager.default.createFile(atPath: target.path, contents: nil)
            return target
        case .error(let error):
            throw error
        }
    }

    // MARK: - Internal

    private func record(_ endpoint: APIEndpoint, kind: Call.Kind) -> StubResponse {
        let call = Call(path: endpoint.path, method: endpoint.method, kind: kind)
        recordedCalls.append(call)
        return stubs[endpoint.path] ?? defaultStub
    }

    private enum Resolved { case data(Data), void, error(APIError) }

    private func resolveResponse(_ response: StubResponse) async -> Resolved {
        switch response {
        case .success(let value):
            do { return .data(try encoder.encode(AnyEncodable(value))) }
            catch { return .error(.encoding(SendableErrorBox(error))) }
        case .successData(let data):
            return .data(data)
        case .void:
            return .void
        case .failure(let error):
            return .error(error)
        case .delayed(let seconds, let inner):
            try? await Task.sleep(for: .seconds(seconds))
            switch inner {
            case .success(let value):
                do { return .data(try encoder.encode(AnyEncodable(value))) }
                catch { return .error(.encoding(SendableErrorBox(error))) }
            case .successData(let data): return .data(data)
            case .void: return .void
            case .failure(let error): return .error(error)
            }
        }
    }

    private func decode<T: Decodable & Sendable>(_ response: StubResponse,
                                                 as type: T.Type,
                                                 override: JSONDecoder?) async throws -> T {
        let used = override ?? decoder
        switch await resolveResponse(response) {
        case .data(let data):
            do { return try used.decode(T.self, from: data) }
            catch { throw APIError.decoding(SendableErrorBox(error)) }
        case .void:
            throw APIError.invalidResponse
        case .error(let error):
            throw error
        }
    }

    private func applyVoid(_ response: StubResponse) async throws {
        switch await resolveResponse(response) {
        case .data, .void: return
        case .error(let error): throw error
        }
    }

    // MARK: - Defaults

    public static func defaultDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func defaultEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}

/// Existential erasure для encoder.
private struct AnyEncodable: Encodable {
    let value: any Encodable & Sendable
    init(_ value: any Encodable & Sendable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private struct SendableErrorBox: Error, @unchecked Sendable {
    let underlying: any Error
    init(_ underlying: any Error) { self.underlying = underlying }
}
