import Foundation

/// Прокидывает события в NetworkLogger. Транспорт вызывает `willSend` через `adapt`,
/// а `didReceive`/`didFail` — напрямую (они вне жизненного цикла interceptor).
public struct LoggingInterceptor: RequestInterceptor {
    public let logger: any NetworkLogger
    public init(logger: any NetworkLogger) { self.logger = logger }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        logger.willSend(request)
        return request
    }
}
