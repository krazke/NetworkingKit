import Foundation

/// Транспорт-агностичный эндпоинт. Замена Moya `TargetType`.
/// Каждый запрос проекта реализует этот протокол.
public protocol APIEndpoint: Sendable {
    var path: String { get }
    var method: HTTPMethod { get }
    var query: [URLQueryItem]? { get }
    var headers: HTTPHeaders? { get }
    var body: RequestBody { get }

    /// Опциональный override timeout'а из NetworkConfiguration.
    var timeout: TimeInterval? { get }
}

public extension APIEndpoint {
    var query: [URLQueryItem]? { nil }
    var headers: HTTPHeaders? { nil }
    var body: RequestBody { .empty }
    var timeout: TimeInterval? { nil }
}
