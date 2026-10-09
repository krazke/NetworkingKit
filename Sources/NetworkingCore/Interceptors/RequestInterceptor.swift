import Foundation

/// Adapts outgoing requests and decides whether a failed attempt is sent again.
///
/// `AlamofireAPIClient` and `URLSessionAPIClient` run the same chain and call both methods with the same
/// inputs, so an interceptor behaves the same with either transport.
public protocol RequestInterceptor: Sendable {
    /// Modifies an outgoing request, for example to add headers or authorization.
    ///
    /// Called before every attempt, so a retried request is adapted again. When it throws, the request
    /// fails without calling `retry`.
    func adapt(_ request: URLRequest) async throws -> URLRequest

    /// Decides whether to send another attempt after one failed.
    ///
    /// Called once for every attempt that was sent and failed with a non-2xx HTTP status or a transport
    /// error. Not called when the request fails before it is sent (building the request or its multipart
    /// body, or `adapt`, throws), when the calling task is cancelled, when a pinned host's server trust is
    /// rejected (the request then fails with `APIError.transport` wrapping a `PinningError`) or the Alamofire
    /// transport rejects a host it has no trust evaluator for, when the system rejects the certificate of a host
    /// without pinning (the request then fails with `APIError.transport` wrapping a `URLError` such as
    /// `.serverCertificateUntrusted`), or after a 2xx response, also when its body cannot be decoded.
    ///
    /// - Parameters:
    ///   - request: The adapted request of the failed attempt.
    ///   - response: The attempt's response for a non-2xx status. `nil` after a transport error, also
    ///     when an earlier attempt of the same request received a response.
    ///   - error: For a non-2xx status, the `APIError` the request fails with if it is not retried:
    ///     `.unauthorized`, `.forbidden`, `.notFound`, or `.server` carrying the response body (`nil`
    ///     when the body is empty, and for `download`). For a transport error, the `URLError`. For any
    ///     other failure after sending, which only the Alamofire transport produces, the `APIError` the
    ///     request fails with.
    ///   - attempt: The number of the failed attempt, starting at 1.
    /// - Returns: `.retry` or `.retryAfter(_:)` to send another attempt; `.doNotRetry` to fail the request.
    func retry(_ request: URLRequest,
               response: HTTPURLResponse?,
               error: any Error & Sendable,
               attempt: Int) async -> RetryDecision
}

public extension RequestInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest { request }
    func retry(_ request: URLRequest,
               response: HTTPURLResponse?,
               error: any Error & Sendable,
               attempt: Int) async -> RetryDecision { .doNotRetry }
}
