import Foundation

public enum APIError: Error, Sendable, CustomStringConvertible {
    /// 401. `data` is the response body, as for `.server`.
    case unauthorized(data: Data?)
    /// 403. `data` is the response body, as for `.server`.
    case forbidden(data: Data?)
    /// 404. `data` is the response body, as for `.server`.
    case notFound(data: Data?)
    /// Any other non-2xx status. `data` is the response body: `nil` when it is empty, and for `download`.
    case server(statusCode: Int, data: Data?, message: String?)
    case decoding(any Error & Sendable)
    case encoding(any Error & Sendable)
    case transport(any Error & Sendable)
    case invalidResponse
    case cancelled
    case unknown(any Error & Sendable)

    /// The HTTP status the request failed with, or `nil` for a failure without a non-2xx response.
    public var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .server(let code, _, _): return code
        case .decoding, .encoding, .transport, .invalidResponse, .cancelled, .unknown: return nil
        }
    }

    /// The body of the non-2xx response the request failed with, whatever its status, so that an app can
    /// decode its API's error format without matching each case. `nil` when the body is empty, for `download`,
    /// and for a failure without a non-2xx response.
    public var responseBody: Data? {
        switch self {
        case .unauthorized(let data), .forbidden(let data), .notFound(let data), .server(_, let data, _):
            return data
        case .decoding, .encoding, .transport, .invalidResponse, .cancelled, .unknown:
            return nil
        }
    }

    /// Omits the response body, which can be large or carry personal data.
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
