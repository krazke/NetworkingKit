import Foundation

/// Главная конфигурация сетевого слоя. Собирается один раз в composition root.
public struct NetworkConfiguration: @unchecked Sendable {
    public var baseURL: URL
    public var sessionConfiguration: URLSessionConfiguration
    public var globalHeaders: [String: String]
    public var dynamicHeaders: HeadersProvider
    /// Pins by host. A key is a host name or an IP address, without a scheme, port or path; an internationalized
    /// name is written in punycode (`xn--…`). Keys are compared case-insensitively, ignoring one trailing dot.
    ///
    /// `URLSessionAPIClient(configuration:)` and the `AlamofireAPIClient` initializers that build their own
    /// session stop the app with `preconditionFailure` when a key is not a host name or an IP address, or when
    /// two keys name the same host with different policies. See `PinningPolicy`.
    public var pinning: [String: PinningPolicy]
    public var retry: RetryConfiguration
    public var tokenStore: any TokenStore
    public var refreshAction: AuthInterceptor.RefreshAction?
    public var refreshWindow: AuthInterceptor.RefreshWindow
    public var additionalInterceptors: [any RequestInterceptor]
    public var logger: (any NetworkLogger)?
    public var decoderFactory: @Sendable () -> JSONDecoder
    public var encoderFactory: @Sendable () -> JSONEncoder

    public init(baseURL: URL,
                sessionConfiguration: URLSessionConfiguration = .default,
                globalHeaders: [String: String] = [:],
                dynamicHeaders: @escaping HeadersProvider = { [:] },
                pinning: [String: PinningPolicy] = [:],
                retry: RetryConfiguration = .default,
                tokenStore: any TokenStore = InMemoryTokenStore(),
                refreshAction: AuthInterceptor.RefreshAction? = nil,
                refreshWindow: AuthInterceptor.RefreshWindow = .default,
                additionalInterceptors: [any RequestInterceptor] = [],
                logger: (any NetworkLogger)? = nil,
                decoderFactory: @escaping @Sendable () -> JSONDecoder = NetworkConfiguration.defaultDecoder,
                encoderFactory: @escaping @Sendable () -> JSONEncoder = NetworkConfiguration.defaultEncoder) {
        self.baseURL = baseURL
        self.sessionConfiguration = sessionConfiguration
        self.globalHeaders = globalHeaders
        self.dynamicHeaders = dynamicHeaders
        self.pinning = pinning
        self.retry = retry
        self.tokenStore = tokenStore
        self.refreshAction = refreshAction
        self.refreshWindow = refreshWindow
        self.additionalInterceptors = additionalInterceptors
        self.logger = logger
        self.decoderFactory = decoderFactory
        self.encoderFactory = encoderFactory
    }

    public static let defaultDecoder: @Sendable () -> JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static let defaultEncoder: @Sendable () -> JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
