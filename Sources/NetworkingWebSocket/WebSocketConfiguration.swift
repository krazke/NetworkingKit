import Foundation
import NetworkingCore

public struct WebSocketConfiguration: @unchecked Sendable {
    public var url: URL
    public var pingInterval: TimeInterval
    public var reconnect: ReconnectPolicy
    public var headers: [String: String]
    public var dynamicHeaders: HeadersProvider
    public var tokenStore: (any TokenStore)?
    public var sessionConfiguration: URLSessionConfiguration
    public var decoderFactory: @Sendable () -> JSONDecoder
    public var encoderFactory: @Sendable () -> JSONEncoder

    public init(url: URL,
                pingInterval: TimeInterval = 30,
                reconnect: ReconnectPolicy = .exponential(),
                headers: [String: String] = [:],
                dynamicHeaders: @escaping HeadersProvider = { [:] },
                tokenStore: (any TokenStore)? = nil,
                sessionConfiguration: URLSessionConfiguration = .default,
                decoderFactory: @escaping @Sendable () -> JSONDecoder = NetworkConfiguration.defaultDecoder,
                encoderFactory: @escaping @Sendable () -> JSONEncoder = NetworkConfiguration.defaultEncoder) {
        self.url = url
        self.pingInterval = pingInterval
        self.reconnect = reconnect
        self.headers = headers
        self.dynamicHeaders = dynamicHeaders
        self.tokenStore = tokenStore
        self.sessionConfiguration = sessionConfiguration
        self.decoderFactory = decoderFactory
        self.encoderFactory = encoderFactory
    }
}
