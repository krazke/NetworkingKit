import Foundation

public enum WebSocketEvent<Message: Sendable>: Sendable {
    case connected
    case message(Message)
    case raw(Data)
    case disconnected(reason: DisconnectReason)
}

public enum DisconnectReason: Sendable {
    case closedByPeer(code: Int, reason: String?)
    case error(any Error & Sendable)
    case clientInitiated
    case reconnecting(attempt: Int, delay: TimeInterval)
    case givenUp
}
