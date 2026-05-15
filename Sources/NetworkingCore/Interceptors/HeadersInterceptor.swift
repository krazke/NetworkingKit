import Foundation

/// Применяет глобальные + динамические заголовки к каждому запросу.
/// Per-endpoint заголовки уже стоят в URLRequest до вызова adapt — этот интерсептор
/// не перетирает то, что уже задано.
public struct HeadersInterceptor: RequestInterceptor {
    public let globalHeaders: [String: String]
    public let dynamicHeaders: HeadersProvider

    public init(globalHeaders: [String: String],
                dynamicHeaders: @escaping HeadersProvider) {
        self.globalHeaders = globalHeaders
        self.dynamicHeaders = dynamicHeaders
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var req = request
        let combined = globalHeaders.merging(dynamicHeaders()) { _, new in new }
        for (name, value) in combined where req.value(forHTTPHeaderField: name) == nil {
            req.setValue(value, forHTTPHeaderField: name)
        }
        return req
    }
}
