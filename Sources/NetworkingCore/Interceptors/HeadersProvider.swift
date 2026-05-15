import Foundation

/// Провайдер динамических заголовков — читается на каждый запрос.
public typealias HeadersProvider = @Sendable () -> [String: String]
