import Foundation

/// Транспорт-агностичный API-клиент. Реализуется AlamofireAPIClient и URLSessionAPIClient.
///
/// Cancellation: все методы корректно реагируют на `Task.cancel()` —
/// в этом случае выбрасывается `APIError.cancelled`.
public protocol APIClientProtocol: Sendable {

    /// Декодирует ответ в `T`. `decoder == nil` использует дефолтный из конфигурации.
    func send<T: Decodable & Sendable>(
        _ endpoint: APIEndpoint,
        as type: T.Type,
        decoder: JSONDecoder?
    ) async throws -> T

    /// Запрос без ожидания тела ответа (status-only).
    func sendVoid(_ endpoint: APIEndpoint) async throws

    /// Multipart upload с прогрессом.
    func upload<T: Decodable & Sendable>(
        _ endpoint: APIEndpoint,
        as type: T.Type,
        decoder: JSONDecoder?,
        progress: ProgressHandler?
    ) async throws -> T

    /// Streamed download прямо на диск с прогрессом.
    func download(
        _ endpoint: APIEndpoint,
        to destination: DownloadDestination,
        progress: ProgressHandler?
    ) async throws -> URL
}

/// Удобные перегрузки.
public extension APIClientProtocol {
    func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        try await send(endpoint, as: type, decoder: nil)
    }

    func upload<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                         as type: T.Type,
                                         progress: ProgressHandler? = nil) async throws -> T {
        try await upload(endpoint, as: type, decoder: nil, progress: progress)
    }

    func download(_ endpoint: APIEndpoint,
                  to destination: DownloadDestination,
                  progress: ProgressHandler? = nil) async throws -> URL {
        try await download(endpoint, to: destination, progress: progress)
    }
}
