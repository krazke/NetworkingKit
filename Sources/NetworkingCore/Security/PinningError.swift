import Foundation

/// A pinned host whose server trust was rejected, so the connection was not used.
///
/// Both transports throw it wrapped in `APIError.transport` and do not call `RequestInterceptor.retry` for it,
/// because another attempt would get the same certificate. Match it with
/// `catch APIError.transport(let error as PinningError)`; a network failure is wrapped as a `URLError` instead.
public struct PinningError: Error, Sendable, Equatable {
    /// Why the server trust was rejected.
    public enum Reason: Sendable, Equatable {
        /// The system rejected the trust before the pins were compared: for example, the certificate has expired,
        /// is issued for another host, or does not chain to a root the device trusts.
        case trustEvaluationFailed
        /// The system trusts the chain, but no certificate or public key in it matches a pin.
        case pinMismatch
    }

    /// The host whose trust was rejected, as the server trust challenge names it.
    public let host: String
    public let reason: Reason

    public init(host: String, reason: Reason) {
        self.host = host
        self.reason = reason
    }
}
