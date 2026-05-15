import Foundation

/// Абстракция над хранилищем токенов. Реализация (Keychain / UserDefaults / in-memory)
/// — на стороне приложения. Пакет НЕ диктует, как хранить.
public protocol TokenStore: Sendable {
    func current() async -> AuthTokens?
    func save(_ tokens: AuthTokens) async
    func clear() async
}
