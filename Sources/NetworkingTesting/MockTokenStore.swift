import Foundation
import NetworkingCore

/// Программируемый TokenStore для тестов. Позволяет инспектировать save/clear через counters.
public actor MockTokenStore: TokenStore {
    public private(set) var stored: AuthTokens?
    public private(set) var saveCount: Int = 0
    public private(set) var clearCount: Int = 0

    public init(initial: AuthTokens? = nil) { self.stored = initial }

    public func current() async -> AuthTokens? { stored }

    public func save(_ tokens: AuthTokens) async {
        stored = tokens
        saveCount += 1
    }

    public func clear() async {
        stored = nil
        clearCount += 1
    }

    /// Сброс счётчиков и состояния для следующего теста.
    public func reset(initial: AuthTokens? = nil) {
        stored = initial
        saveCount = 0
        clearCount = 0
    }
}
