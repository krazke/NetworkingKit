import Foundation
import NetworkingCore

/// APIClient на чистом URLSession. Без сторонних зависимостей.
public final class URLSessionAPIClient: APIClientProtocol {
    private let configuration: NetworkConfiguration
    private let session: URLSession
    private let interceptor: CompositeInterceptor
    /// `nil` when no host is pinned. Internal so that tests can answer a server trust challenge with it.
    let pinningDelegate: PinningDelegate?

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
        let target = try destination.targetURL()
        let observer = ProgressObserver(handler: progress)

        let (location, response) = try await sendWithRetry(
            initial: built,
            perform: { try await self.session.download(for: $0, delegate: observer) },
            responseBody: { _ in nil },
            discard: { try? FileManager.default.removeItem(at: $0) }
        )
        // Discards the download when it cannot be placed; a no-op once the file has been moved.
        defer { try? FileManager.default.removeItem(at: location) }
        try validate(response: response, data: nil)
        try destination.moveDownloadedFile(at: location, to: target)
        return target
    }

    // MARK: - Internal

    private func execute(_ endpoint: APIEndpoint) async throws -> (Data, URLResponse) {
        let encoder = configuration.encoderFactory()
        let (built, _) = try URLRequestBuilder.build(endpoint,
                                                     configuration: configuration,
                                                     encoder: encoder)
        return try await sendWithRetry(initial: built) { try await self.session.data(for: $0) }
    }

    private func executeUpload(_ endpoint: APIEndpoint,
                               progress: ProgressHandler?) async throws -> (Data, URLResponse) {
        let encoder = configuration.encoderFactory()
        let (built, parts) = try URLRequestBuilder.build(endpoint,
                                                         configuration: configuration,
                                                         encoder: encoder)

        guard let parts else {
            // The body stays in `httpBody`, as for `send`; the task delegate reports it being sent.
            // URLSession calls `didSendBodyData` for a data task with a body as it does for an upload task.
            let observer = ProgressObserver(handler: progress)
            return try await sendWithRetry(initial: built) {
                try await self.session.data(for: $0, delegate: observer)
            }
        }

        let builder = MultipartFormDataBuilder()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).multipart")
        // Declared before writing: a failed write leaves a partial file behind.
        // Every attempt uploads this one file; it is removed once, after the last attempt.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            _ = try builder.writeBody(parts: parts, to: tempURL)
        } catch let error as CocoaError {
            // `AlamofireAPIClient` maps Alamofire's `multipartEncodingFailed` the same way.
            throw APIError.encoding(error)
        } catch {
            throw APIError.encoding(SendableErrorBox(error))
        }

        var request = built
        request.setValue(builder.contentType, forHTTPHeaderField: "Content-Type")
        let observer = ProgressObserver(handler: progress)

        return try await sendWithRetry(initial: request) {
            try await self.session.upload(for: $0, fromFile: tempURL, delegate: observer)
        }
    }

    /// `sendWithRetry(initial:perform:responseBody:discard:)` for a response body loaded into memory.
    private func sendWithRetry(initial: URLRequest,
                               perform: (URLRequest) async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        try await sendWithRetry(initial: initial, perform: perform, responseBody: { $0 }, discard: { _ in })
    }

    /// Sends `initial` through the interceptor chain until an attempt succeeds or `retry` declines.
    ///
    /// Every attempt runs `adapt` again, so a retry after a 401 refresh carries the new token.
    /// `retry` gets the inputs documented on `RequestInterceptor.retry(_:response:error:attempt:)`.
    ///
    /// - Parameters:
    ///   - perform: Sends one adapted request. Called once per attempt.
    ///   - responseBody: The in-memory response body, for logging and `APIError.server`;
    ///     `nil` when the body was written to a file.
    ///   - discard: Releases the payload of an attempt that is not returned, such as a downloaded file.
    ///     Called once for every failed or retried attempt.
    /// - Returns: The payload and response of the first 2xx or non-HTTP response. The caller owns the payload.
    /// - Throws: `APIError`. `.cancelled` when the task is cancelled, also during a retry delay. `.transport`
    ///   with a `PinningError`, without asking `retry`, when `PinningDelegate` rejects the server trust.
    private func sendWithRetry<Payload>(initial: URLRequest,
                                        perform: (URLRequest) async throws -> (Payload, URLResponse),
                                        responseBody: (Payload) -> Data?,
                                        discard: (Payload) -> Void) async throws -> (Payload, URLResponse) {
        var attempt = 0

        while true {
            attempt += 1
            guard !Task.isCancelled else { throw APIError.cancelled }

            let request: URLRequest
            do {
                request = try await interceptor.adapt(initial)
            } catch {
                throw mapError(error)
            }

            let start = Date()
            let decision: RetryDecision
            let failure: APIError
            do {
                let (payload, response) = try await perform(request)
                var returnsPayload = false
                defer { if !returnsPayload { discard(payload) } }
                try Task.checkCancellation()
                try await fireDidReceive(request: request,
                                         response: response,
                                         data: responseBody(payload),
                                         start: start)

                guard let http = response as? HTTPURLResponse, !HTTPStatus.is2xx(http.statusCode) else {
                    returnsPayload = true
                    return (payload, response)
                }
                failure = statusError(http, data: responseBody(payload))
                decision = await interceptor.retry(request,
                                                   response: http,
                                                   error: failure,
                                                   attempt: attempt)
            } catch is CancellationError {
                throw APIError.cancelled
            } catch let urlError as URLError where urlError.code == .cancelled {
                // A rejected server trust is not retried: another attempt would get the same certificate.
                if !Task.isCancelled, let failure = pinningFailure(for: urlError, of: request) {
                    configuration.logger?.didFail(request, error: failure)
                    throw APIError.transport(failure)
                }
                throw APIError.cancelled
            } catch let urlError as URLError {
                configuration.logger?.didFail(request, error: urlError)
                failure = .transport(urlError)
                // No response: an earlier attempt's response, such as the 401 that triggered a refresh,
                // would make the chain decide by a status this attempt never received.
                decision = await interceptor.retry(request,
                                                   response: nil,
                                                   error: urlError,
                                                   attempt: attempt)
            } catch let apiError as APIError {
                throw apiError
            } catch {
                throw APIError.unknown(SendableErrorBox(error))
            }

            switch decision.validated {
            case .doNotRetry:
                throw failure
            case .retry:
                continue
            case .retryAfter(let delay):
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw APIError.cancelled
                }
            }
        }
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard HTTPStatus.is2xx(http.statusCode) else {
            throw statusError(http, data: data)
        }
    }

    /// The error for a non-2xx response. `.server` carries an empty body as `nil`, as the Alamofire transport does.
    private func statusError(_ http: HTTPURLResponse, data: Data?) -> APIError {
        switch http.statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        default:
            return .server(statusCode: http.statusCode,
                           data: data?.isEmpty == false ? data : nil,
                           message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
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

    /// The rejected server trust that made URLSession cancel `request`'s task, or `nil` for any other cancellation.
    ///
    /// The error's `failingURL` comes first, because a redirect can take the task to another host than
    /// `request`'s. Only `PinningDelegate` cancels a task while its caller is not cancelled.
    private func pinningFailure(for error: URLError, of request: URLRequest) -> PinningError? {
        guard let host = error.failingURL?.host ?? request.url?.host else { return nil }
        return pinningDelegate?.failure(forHost: host)
    }

    /// Maps an error thrown by an interceptor's `adapt`. `AlamofireAPIClient.mapError` applies the same rules.
    private func mapError(_ error: any Error) -> APIError {
        if let api = error as? APIError { return api }
        if error is CancellationError { return .cancelled }
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
