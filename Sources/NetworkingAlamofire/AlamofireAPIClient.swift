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

    /// The statuses a response is accepted with. Only the status is validated, as in the URLSession transport:
    /// Alamofire's `validate()` would also reject a non-empty body whose `Content-Type` does not match `Accept`.
    private static let acceptedStatusCodes = 200..<300

    // MARK: - APIClientProtocol

    public func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                              as type: T.Type,
                                              decoder: JSONDecoder?) async throws -> T {
        let convertible = adapter(for: endpoint)
        let usedDecoder = decoder ?? configuration.decoderFactory()

        let request = session.request(convertible).validate(statusCode: Self.acceptedStatusCodes)
        return try await value(of: request.serializingDecodable(T.self, decoder: usedDecoder), from: request)
    }

    public func sendVoid(_ endpoint: APIEndpoint) async throws {
        let convertible = adapter(for: endpoint)
        // Alamofire accepts an empty body only for 204 and 205; the URLSession transport accepts it for any 2xx.
        let request = session.request(convertible).validate(statusCode: Self.acceptedStatusCodes)
        _ = try await value(of: request.serializingData(emptyResponseCodes: Set(Self.acceptedStatusCodes)),
                            from: request)
    }

    public func upload<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                                as type: T.Type,
                                                decoder: JSONDecoder?,
                                                progress: ProgressHandler?) async throws -> T {
        let convertible = adapter(for: endpoint)
        let usedDecoder = decoder ?? configuration.decoderFactory()

        // Если не multipart — обычный upload через httpBody
        guard case .multipart(let parts) = endpoint.body else {
            let request = session.request(convertible).validate(statusCode: Self.acceptedStatusCodes)
            if let progress {
                request.uploadProgress { p in progress(p.fractionCompleted) }
            }
            return try await value(of: request.serializingDecodable(T.self, decoder: usedDecoder), from: request)
        }

        let request = session.upload(multipartFormData: { [self] form in
            self.appendParts(parts, to: form)
        }, with: convertible).validate(statusCode: Self.acceptedStatusCodes)

        if let progress {
            request.uploadProgress { p in progress(p.fractionCompleted) }
        }

        return try await value(of: request.serializingDecodable(T.self, decoder: usedDecoder), from: request)
    }

    public func download(_ endpoint: APIEndpoint,
                         to destination: DownloadDestination,
                         progress: ProgressHandler?) async throws -> URL {
        let convertible = adapter(for: endpoint)
        let target = try destination.targetURL()

        // No `to:` destination: Alamofire moves the file to its destination before validation runs,
        // so an error response would replace the target. The default destination keeps the file in the
        // temporary directory, and `moveDownloadedFile` places it only after validation, as the
        // URLSession transport does.
        let request = session.download(convertible).validate(statusCode: Self.acceptedStatusCodes)
        if let progress {
            request.downloadProgress { p in progress(p.fractionCompleted) }
        }
        let response = await request.serializingDownloadedFileURL().response
        // Discards the download when it fails or cannot be placed; a no-op once the file has been moved.
        defer { if let location = response.fileURL { try? FileManager.default.removeItem(at: location) } }

        switch response.result {
        case .success(let location):
            // Validation checks only HTTP responses, so a non-HTTP response arrives here as a success.
            guard response.response != nil else { throw APIError.invalidResponse }
            try destination.moveDownloadedFile(at: location, to: target)
            return target
        case .failure(let error):
            throw Self.mapError(error, cancelled: Task.isCancelled)
        }
    }

    // MARK: - Internal

    /// Awaits `task` and maps a failure together with the response body.
    /// `DataTask.value` would throw only the `AFError`, which does not carry the body.
    ///
    /// - Parameter request: The request `task` serializes. Its last task's response is checked
    ///   before the result, because Alamofire exposes only an `HTTPURLResponse`.
    /// - Throws: `.invalidResponse` for a response that is not an `HTTPURLResponse`, whatever its body,
    ///   as `URLSessionAPIClient` validates the response before decoding it; `.cancelled` instead when the
    ///   calling task was cancelled.
    private func value<Value>(of task: DataTask<Value>, from request: DataRequest) async throws -> Value {
        let response = await task.response
        // Validation skips a non-HTTP response, and the serializer then fails on an empty or undecodable
        // body, or succeeds on any other; neither outcome is the request's result.
        if let received = request.task?.response, !(received is HTTPURLResponse) {
            throw Task.isCancelled ? APIError.cancelled : APIError.invalidResponse
        }
        switch response.result {
        case .success(let value):
            return value
        case .failure(let error):
            throw Self.mapError(error, responseBody: response.data, cancelled: Task.isCancelled)
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

    /// Maps a failure to the `APIError` that `URLSessionAPIClient` throws for the same cause.
    /// `InterceptorBridge` passes the result to `retry` for a failure that is not a transport error.
    ///
    /// Alamofire wraps an error thrown while building the request (`EndpointAdapter`), by an interceptor's
    /// `adapt`, or by the session task in an `AFError`. That error is unwrapped and mapped by the rules
    /// `URLSessionAPIClient` uses: an `APIError` passes through unchanged, a `URLError` becomes `.transport`
    /// with the `URLError` itself, and `CancellationError` or `URLError.cancelled` becomes `.cancelled`.
    ///
    /// - Parameter cancelled: Whether the calling task was cancelled. A request cancelled while it waits for a
    ///   retry delay fails with the error of its last attempt, which then becomes `.cancelled`.
    static func mapError(_ error: any Error, responseBody: Data? = nil, cancelled: Bool = false) -> APIError {
        if cancelled { return .cancelled }
        guard let af = error as? AFError else { return Self.mapUnderlying(error) }
        if af.isExplicitlyCancelledError { return .cancelled }

        switch af.responseCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case let code? where (400..<600).contains(code):
            // An empty body is `nil` in both transports.
            return .server(statusCode: code, data: responseBody?.isEmpty == false ? responseBody : nil,
                           message: af.errorDescription)
        default: break
        }

        switch af {
        case .createURLRequestFailed(error: let underlying),
             .requestAdaptationFailed(error: let underlying),
             .sessionTaskFailed(error: let underlying):
            return mapError(underlying)
        case .multipartEncodingFailed:
            // A `.file` part is missing or unreadable, or the body could not be written to disk.
            if let cocoa = af.underlyingError as? CocoaError { return .encoding(cocoa) }
            return .encoding(NonSendableErrorBox(af))
        case .responseSerializationFailed(reason: .decodingFailed(error: let underlying)):
            return .decoding(NonSendableErrorBox(underlying))
        case .responseSerializationFailed(reason: .inputDataNilOrZeroLength),
             .responseSerializationFailed(reason: .invalidEmptyResponse):
            // An empty 2xx body where a value was expected; `JSONDecoder` rejects it in the URLSession transport.
            return .decoding(NonSendableErrorBox(af))
        default:
            return .transport(NonSendableErrorBox(af))
        }
    }

    private static func mapUnderlying(_ error: any Error) -> APIError {
        if let api = error as? APIError { return api }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .transport(urlError)
        }
        return .unknown(NonSendableErrorBox(error))
    }
}
