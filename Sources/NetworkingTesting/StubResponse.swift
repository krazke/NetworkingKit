import Foundation
import NetworkingCore

/// Программируемый ответ для MockAPIClient.
public enum StubResponse: Sendable {
    case success(any Encodable & Sendable)
    case successData(Data)
    case void
    case failure(APIError)
    /// Задержка перед возвратом — имитирует latency / racing условия.
    case delayed(TimeInterval, StubResponseInner)

    public indirect enum StubResponseInner: Sendable {
        case success(any Encodable & Sendable)
        case successData(Data)
        case void
        case failure(APIError)
    }

}
