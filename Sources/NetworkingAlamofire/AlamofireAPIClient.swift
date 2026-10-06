import Foundation
import Alamofire
import NetworkingCore

/// Production-транспорт на Alamofire 5.11+. Реализует APIClientProtocol.
public final class AlamofireAPIClient: APIClientProtocol {
    private let configuration: NetworkConfiguration
    private let session: Session
    private let baseURL: URL

    /// Стандартный init — собирает Session из конфига.
    public convenience init(configuration: NetworkConfiguration) {
        let session = Self.buildSession(configuration: configuration, additionalMonitors: [])
        self.init(session: session, configuration: configuration)
    }

    /// Escape-hatch — для подключения PulseAlamofire или кастомных EventMonitor'ов.
    public init(session: Session, configuration: NetworkConfiguration) {
        self.configuration = configuration
        self.session = session
        self.baseURL = configuration.baseURL
    }

    /// Альтернативный init с дополнительными EventMonitor (например, PulseAlamofire).
    public convenience init(configuration: NetworkConfiguration,
                            additionalMonitors: [EventMonitor]) {
        let session = Self.buildSession(configuration: configuration,
                                        additionalMonitors: additionalMonitors)
        self.init(session: session, configuration: configuration)
    }

    private static func buildSession(configuration: NetworkConfiguration,
                                     additionalMonitors: [EventMonitor]) -> Session {
        var monitors: [EventMonitor] = additionalMonitors
        if let logger = configuration.logger {
            monitors.append(EventLoggerAdapter(logger: logger))
        }

        // Цепочка интерсепторов из Core
        var chain: [any NetworkingCore.RequestInterceptor] = []
        chain.append(NetworkingCore.HeadersInterceptor(globalHeaders: configuration.globalHeaders,
                                                       dynamicHeaders: configuration.dynamicHeaders))
        if let refresh = configuration.refreshAction {
            chain.append(NetworkingCore.AuthInterceptor(tokenStore: configuration.tokenStore,
                                                        refreshWindow: configuration.refreshWindow,
                                                        refresh: refresh))
        }
        chain.append(contentsOf: configuration.additionalInterceptors)
        chain.append(NetworkingCore.RetryInterceptor(configuration: configuration.retry))
        let composite = NetworkingCore.CompositeInterceptor(chain)
        let bridge = InterceptorBridge(composite)

        let trust = ServerTrustFactory.makeManager(configuration.pinning)

        return Session(configuration: configuration.sessionConfiguration,
                       interceptor: bridge,
                       serverTrustManager: trust,
                       eventMonitors: monitors)
    }

    // MARK: - APIClientProtocol

    public func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                              as type: T.Type,
                                              decoder: JSONDecoder?) async throws -> T {
        let convertible = adapter(for: endpoint)
        let usedDecoder = decoder ?? configuration.decoderFactory()

        return try await value(of: session.request(convertible)
            .validate()
            .serializingDecodable(T.self, decoder: usedDecoder))
    }

    public func sendVoid(_ endpoint: APIEndpoint) async throws {
        let convertible = adapter(for: endpoint)
        _ = try await value(of: session.request(convertible)
            .validate()
            .serializingData())
    }

    public func upload<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                                as type: T.Type,
                                                decoder: JSONDecoder?,
                                                progress: ProgressHandler?) async throws -> T {
        let convertible = adapter(for: endpoint)
        let usedDecoder = decoder ?? configuration.decoderFactory()

        // Если не multipart — обычный upload через httpBody
        guard case .multipart(let parts) = endpoint.body else {
            let request = session.request(convertible).validate()
            if let progress {
                request.uploadProgress { p in progress(p.fractionCompleted) }
            }
            return try await value(of: request.serializingDecodable(T.self, decoder: usedDecoder))
        }

        let request = session.upload(multipartFormData: { [self] form in
            self.appendParts(parts, to: form)
        }, with: convertible).validate()

        if let progress {
            request.uploadProgress { p in progress(p.fractionCompleted) }
        }

        return try await value(of: request.serializingDecodable(T.self, decoder: usedDecoder))
    }

    public func download(_ endpoint: APIEndpoint,
                         to destination: DownloadDestination,
                         progress: ProgressHandler?) async throws -> URL {
        let convertible = adapter(for: endpoint)
        let target = try destination.targetURL()

        // No `to:` destination: Alamofire moves the file to its destination before `validate()` runs,
        // so an error response would replace the target. The default destination keeps the file in the
        // temporary directory, and `moveDownloadedFile` places it only after validation, as the
        // URLSession transport does.
        let request = session.download(convertible).validate()
        if let progress {
            request.downloadProgress { p in progress(p.fractionCompleted) }
        }
        let response = await request.serializingDownloadedFileURL().response
        // Discards the download when it fails or cannot be placed; a no-op once the file has been moved.
        defer { if let location = response.fileURL { try? FileManager.default.removeItem(at: location) } }

        switch response.result {
        case .success(let location):
            try destination.moveDownloadedFile(at: location, to: target)
            return target
        case .failure(let error):
            throw mapError(error, cancelled: Task.isCancelled)
        }
    }

    // MARK: - Internal

    /// Awaits `task` and maps a failure together with the response body.
    /// `DataTask.value` would throw only the `AFError`, which does not carry the body.
    private func value<Value>(of task: DataTask<Value>) async throws -> Value {
        let response = await task.response
        switch response.result {
        case .success(let value):
            return value
        case .failure(let error):
            throw mapError(error, responseBody: response.data, cancelled: Task.isCancelled)
        }
    }

    private func adapter(for endpoint: APIEndpoint) -> EndpointAdapter {
        EndpointAdapter(endpoint: endpoint,
                        baseURL: baseURL,
                        encoder: configuration.encoderFactory())
    }

    /// Alamofire 5.11 interpolates names and filenames into `Content-Disposition` unescaped,
    /// so they are escaped here.
    private func appendParts(_ parts: [MultipartPart], to form: MultipartFormData) {
        for part in parts {
            let name = MultipartDisposition.escapeName(part.name)
            switch part.source {
            case .data(let data):
                if let filename = part.filename {
                    form.append(data,
                                withName: name,
                                fileName: MultipartDisposition.escapeFilename(filename),
                                mimeType: part.mimeType ?? "application/octet-stream")
                } else if let mime = part.mimeType {
                    form.append(data, withName: name, mimeType: mime)
                } else {
                    form.append(data, withName: name)
                }
            case .fileURL(let url):
                form.append(url,
                            withName: name,
                            fileName: MultipartDisposition.escapeFilename(part.filename ?? url.lastPathComponent),
                            mimeType: part.mimeType ?? "application/octet-stream")
            }
        }
    }

    /// - Parameter cancelled: Whether the calling task was cancelled. A request cancelled while it waits for a
    ///   retry delay fails with the error of its last attempt, which then becomes `.cancelled`.
    private func mapError(_ error: any Error, responseBody: Data? = nil, cancelled: Bool = false) -> APIError {
        if cancelled { return .cancelled }
        if let api = error as? APIError { return api }

        if let af = error as? AFError {
            if af.isExplicitlyCancelledError { return .cancelled }
            switch af.responseCode {
            case 401: return .unauthorized
            case 403: return .forbidden
            case 404: return .notFound
            case let code? where (400..<600).contains(code):
                return .server(statusCode: code, data: responseBody, message: af.errorDescription)
            default: break
            }
            if case .responseSerializationFailed(let reason) = af,
               case .decodingFailed(let underlying) = reason {
                return .decoding(NonSendableErrorBox(underlying))
            }
            return .transport(NonSendableErrorBox(af))
        }

        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .transport(urlError)
        }

        return .unknown(NonSendableErrorBox(error))
    }
}
