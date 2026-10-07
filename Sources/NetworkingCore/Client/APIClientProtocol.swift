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

    /// Sends the endpoint's body, multipart or any other, reporting its progress, and decodes the response into `T`.
    /// `decoder == nil` uses the configuration's decoder.
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

    // Deliberately no `progress: ProgressHandler? = nil` variant: with the requirement's exact signature
    // it would become a default implementation that calls itself, so a conformer without `download`
    // would compile and then recurse forever.
    func download(_ endpoint: APIEndpoint,
                  to destination: DownloadDestination) async throws -> URL {
        try await download(endpoint, to: destination, progress: nil)
    }
}
