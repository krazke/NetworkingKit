import Foundation
import NetworkingCore

/// APIClient на чистом URLSession. Без сторонних зависимостей.
public final class URLSessionAPIClient: APIClientProtocol {
    private let configuration: NetworkConfiguration
    private let session: URLSession
    private let interceptor: CompositeInterceptor
    private let pinningDelegate: PinningDelegate?

    public init(configuration: NetworkConfiguration) {
        self.configuration = configuration

        let pinning = configuration.pinning.contains(where: { _, p in
            if case .none = p { return false } else { return true }
        }) ? PinningDelegate(pinning: configuration.pinning) : nil
        self.pinningDelegate = pinning

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: configuration.sessionConfiguration,
                                  delegate: pinning,
                                  delegateQueue: queue)

        var chain: [any RequestInterceptor] = []
        chain.append(HeadersInterceptor(globalHeaders: configuration.globalHeaders,
                                        dynamicHeaders: configuration.dynamicHeaders))
        if let logger = configuration.logger {
            chain.append(LoggingInterceptor(logger: logger))
        }
        if let refresh = configuration.refreshAction {
            chain.append(AuthInterceptor(tokenStore: configuration.tokenStore,
                                         refreshWindow: configuration.refreshWindow,
                                         refresh: refresh))
        }
        chain.append(contentsOf: configuration.additionalInterceptors)
        chain.append(RetryInterceptor(configuration: configuration.retry))
        self.interceptor = CompositeInterceptor(chain)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - APIClientProtocol

    public func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                              as type: T.Type,
                                              decoder: JSONDecoder?) async throws -> T {
        let (data, response) = try await execute(endpoint)
        try validate(response: response, data: data)
        return try decode(T.self, from: data, decoder: decoder)
    }

    public func sendVoid(_ endpoint: APIEndpoint) async throws {
        let (data, response) = try await execute(endpoint)
        try validate(response: response, data: data)
    }

    public func upload<T: Decodable & Sendable>(_ endpoint: APIEndpoint,
                                                as type: T.Type,
                                                decoder: JSONDecoder?,
                                                progress: ProgressHandler?) async throws -> T {
        let (data, response) = try await executeUpload(endpoint, progress: progress)
        try validate(response: response, data: data)
        return try decode(T.self, from: data, decoder: decoder)
    }

    public func download(_ endpoint: APIEndpoint,
                         to destination: DownloadDestination,
                         progress: ProgressHandler?) async throws -> URL {
        let encoder = configuration.encoderFactory()
        let (built, _) = try URLRequestBuilder.build(endpoint,
                                                     configuration: configuration,
                                                     encoder: encoder)
        let request = try await interceptor.adapt(built)

        let target = try destination.targetURL()

        let observer = ProgressObserver(handler: progress)
        let start = Date()

        do {
            let (location, response) = try await session.download(for: request, delegate: observer)
            // Discards the download when any step below fails; a no-op once the file has been moved.
            defer { try? FileManager.default.removeItem(at: location) }
            try Task.checkCancellation()
            try await fireDidReceive(request: request,
                                     response: response,
                                     data: nil,
                                     start: start)
            try validate(response: response, data: nil)
            try destination.moveDownloadedFile(at: location, to: target)
            return target
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Internal

    private func execute(_ endpoint: APIEndpoint) async throws -> (Data, URLResponse) {
        let encoder = configuration.encoderFactory()
        let (built, _) = try URLRequestBuilder.build(endpoint,
                                                     configuration: configuration,
                                                     encoder: encoder)
        return try await sendWithRetry(initial: built)
    }

    private func executeUpload(_ endpoint: APIEndpoint,
                               progress: ProgressHandler?) async throws -> (Data, URLResponse) {
        let encoder = configuration.encoderFactory()
        let (built, parts) = try URLRequestBuilder.build(endpoint,
                                                         configuration: configuration,
                                                         encoder: encoder)

        guard let parts else {
            // Не multipart — обычный upload через body
            return try await sendWithRetry(initial: built)
        }

        let builder = MultipartFormDataBuilder()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).multipart")
        // Declared before writing: a failed write leaves a partial file behind.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try builder.writeBody(parts: parts, to: tempURL)

        var request = built
        request.setValue(builder.contentType, forHTTPHeaderField: "Content-Type")

        let request2 = try await interceptor.adapt(request)
        let observer = ProgressObserver(handler: progress)
        let start = Date()

        do {
            let (data, response) = try await session.upload(for: request2,
                                                            fromFile: tempURL,
                                                            delegate: observer)
            try Task.checkCancellation()
            try await fireDidReceive(request: request2,
                                     response: response,
                                     data: data,
                                     start: start)
            return (data, response)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            throw mapError(error)
        }
    }

    private func sendWithRetry(initial: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        var lastResponse: HTTPURLResponse?

        while true {
            attempt += 1
            try Task.checkCancellation()

            let request: URLRequest
            do {
                request = try await interceptor.adapt(initial)
            } catch {
                throw mapError(error)
            }

            let start = Date()
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                let http = response as? HTTPURLResponse
                try await fireDidReceive(request: request,
                                         response: response,
                                         data: data,
                                         start: start)

                if let http, !HTTPStatus.is2xx(http.statusCode) {
                    let mapped: APIError = {
                        switch http.statusCode {
                        case 401: return .unauthorized
                        case 403: return .forbidden
                        case 404: return .notFound
                        default:
                            return .server(statusCode: http.statusCode,
                                           data: data,
                                           message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
                        }
                    }()
                    let decision = await interceptor.retry(request,
                                                           response: http,
                                                           error: mapped,
                                                           attempt: attempt)
                    switch decision {
                    case .doNotRetry:
                        throw mapped
                    case .retry:
                        lastResponse = http
                        continue
                    case .retryAfter(let delay):
                        try await Task.sleep(for: .seconds(delay))
                        lastResponse = http
                        continue
                    }
                }

                return (data, response)
            } catch is CancellationError {
                throw APIError.cancelled
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw APIError.cancelled
            } catch let urlError as URLError {
                configuration.logger?.didFail(request, error: urlError)
                let decision = await interceptor.retry(request,
                                                       response: lastResponse,
                                                       error: urlError,
                                                       attempt: attempt)
                switch decision {
                case .doNotRetry:
                    throw APIError.transport(urlError)
                case .retry:
                    continue
                case .retryAfter(let delay):
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
            } catch let apiError as APIError {
                throw apiError
            } catch {
                throw APIError.unknown(SendableErrorBox(error))
            }
        }
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard HTTPStatus.is2xx(http.statusCode) else {
            switch http.statusCode {
            case 401: throw APIError.unauthorized
            case 403: throw APIError.forbidden
            case 404: throw APIError.notFound
            default:
                throw APIError.server(statusCode: http.statusCode,
                                      data: data,
                                      message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder override: JSONDecoder?) throws -> T {
        let decoder = override ?? configuration.decoderFactory()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(SendableErrorBox(error))
        }
    }

    private func fireDidReceive(request: URLRequest,
                                response: URLResponse,
                                data: Data?,
                                start: Date) async throws {
        configuration.logger?.didReceive(request,
                                         response: response as? HTTPURLResponse,
                                         data: data,
                                         duration: Date().timeIntervalSince(start))
    }

    private func mapError(_ error: any Error) -> APIError {
        if let api = error as? APIError { return api }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .transport(urlError)
        }
        return .unknown(SendableErrorBox(error))
    }
}

/// Боксирует non-Sendable ошибки в Sendable.
struct SendableErrorBox: Error, @unchecked Sendable {
    let underlying: any Error
    init(_ underlying: any Error) { self.underlying = underlying }
    var localizedDescription: String { underlying.localizedDescription }
}
