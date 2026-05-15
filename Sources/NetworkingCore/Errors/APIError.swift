import Foundation

public enum APIError: Error, Sendable, CustomStringConvertible {
    case unauthorized
    case forbidden
    case notFound
    case server(statusCode: Int, data: Data?, message: String?)
    case decoding(any Error & Sendable)
    case encoding(any Error & Sendable)
    case transport(any Error & Sendable)
    case invalidResponse
    case cancelled
    case unknown(any Error & Sendable)

    public var description: String {
        switch self {
        case .unauthorized: return "401 Unauthorized"
        case .forbidden: return "403 Forbidden"
        case .notFound: return "404 Not Found"
        case .server(let code, _, let msg):
            return "Server \(code)" + (msg.map { ": \($0)" } ?? "")
        case .decoding(let e): return "Decoding error: \(e)"
        case .encoding(let e): return "Encoding error: \(e)"
        case .transport(let e): return "Transport error: \(e)"
        case .invalidResponse: return "Invalid response"
        case .cancelled: return "Cancelled"
        case .unknown(let e): return "Unknown: \(e)"
        }
    }
}
