import Foundation

/// In-memory реализация для превью / демо / unit-тестов на стороне потребителя.
/// Для production используй Keychain-обёртку в проекте.
public actor InMemoryTokenStore: TokenStore {
    private var tokens: AuthTokens?

    public init(initial: AuthTokens? = nil) { self.tokens = initial }

    public func current() async -> AuthTokens? { tokens }
    public func save(_ tokens: AuthTokens) async { self.tokens = tokens }
    public func clear() async { tokens = nil }
}
