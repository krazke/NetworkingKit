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

        do {
            return try await session.request(convertible)
                .validate()
                .serializingDecodable(T.self, decoder: usedDecoder)
                .value
        } catch {
            throw mapError(error)
        }
    }

    public func sendVoid(_ endpoint: APIEndpoint) async throws {
        let convertible = adapter(for: endpoint)
        do {
            _ = try await session.request(convertible)
                .validate()
                .serializingData()
                .value
        } catch {
            throw mapError(error)
        }
    }

    public func upload<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                                as type: T.Type,
                                                decoder: JSONDecoder?,
                                                progress: ProgressHandler?) async throws -> T {
        let convertible = adapter(for: endpoint)
        let usedDecoder = decoder ?? configuration.decoderFactory()

        // Если не multipart — обычный upload через httpBody
        guard case .multipart(let parts) = endpoint.body else {
            do {
                let request = session.request(convertible).validate()
                if let progress {
                    request.uploadProgress { p in progress(p.fractionCompleted) }
                }
                return try await request.serializingDecodable(T.self, decoder: usedDecoder).value
            } catch {
                throw mapError(error)
            }
        }

        do {
            let request = session.upload(multipartFormData: { [self] form in
                self.appendParts(parts, to: form)
            }, with: convertible).validate()

            if let progress {
                request.uploadProgress { p in progress(p.fractionCompleted) }
            }

            return try await request.serializingDecodable(T.self, decoder: usedDecoder).value
        } catch {
            throw mapError(error)
        }
    }

    public func download(_ endpoint: APIEndpoint,
                         to destination: DownloadDestination,
                         progress: ProgressHandler?) async throws -> URL {
        let convertible = adapter(for: endpoint)
        let target = try destination.resolve()
        let dest: DownloadRequest.Destination = { _, _ in
            (target, [.removePreviousFile, .createIntermediateDirectories])
        }

        do {
            let request = session.download(convertible, to: dest).validate()
            if let progress {
                request.downloadProgress { p in progress(p.fractionCompleted) }
            }
            let url = try await request.serializingDownloadedFileURL().value
            return url
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Internal

    private func adapter(for endpoint: APIEndpoint) -> EndpointAdapter {
        EndpointAdapter(endpoint: endpoint,
                        baseURL: baseURL,
                        encoder: configuration.encoderFactory())
    }

    private func appendParts(_ parts: [MultipartPart], to form: MultipartFormData) {
        for part in parts {
            switch part.source {
            case .data(let data):
                if let filename = part.filename {
                    form.append(data,
                                withName: part.name,
                                fileName: filename,
                                mimeType: part.mimeType ?? "application/octet-stream")
                } else if let mime = part.mimeType {
                    form.append(data, withName: part.name, mimeType: mime)
                } else {
                    form.append(data, withName: part.name)
                }
            case .fileURL(let url):
                form.append(url,
                            withName: part.name,
                            fileName: part.filename ?? url.lastPathComponent,
                            mimeType: part.mimeType ?? "application/octet-stream")
            }
        }
    }

    private func mapError(_ error: any Error) -> APIError {
        if let api = error as? APIError { return api }

        if let af = error as? AFError {
            if af.isExplicitlyCancelledError { return .cancelled }
            switch af.responseCode {
            case 401: return .unauthorized
            case 403: return .forbidden
            case 404: return .notFound
            case let code? where (400..<600).contains(code):
                let data: Data? = {
                    if case .responseValidationFailed(let reason) = af,
                       case .unacceptableStatusCode = reason { return nil }
                    return nil
                }()
                return .server(statusCode: code, data: data, message: af.errorDescription)
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
