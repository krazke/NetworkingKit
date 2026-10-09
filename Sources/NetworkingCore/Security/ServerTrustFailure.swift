import Foundation

extension URLError {
    /// Whether URLSession failed the task because the system rejected the server's certificate: it has expired
    /// or is not yet valid, is issued for another host, or does not chain to a root the device trusts.
    ///
    /// Both transports fail such a request at once, without asking `RequestInterceptor.retry`, because another
    /// attempt would get the same certificate. `.secureConnectionFailed` is not included: a TLS handshake can also
    /// fail for a transient reason, such as a connection reset during the handshake.
    package var isServerTrustFailure: Bool {
        switch code {
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }
}
