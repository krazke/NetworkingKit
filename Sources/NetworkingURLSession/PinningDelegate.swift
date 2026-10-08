import Foundation
import Security
import NetworkingCore

/// Answers server trust challenges according to `PinningPolicy`.
///
/// For a pinned host the system first evaluates the trust as URLSession presents it, so expiry, the host name
/// and the chain to a trusted root are checked as with default handling; only then are the pins compared with
/// the evaluated chain. A failure of either cancels the challenge, which fails the task with `URLError.cancelled`.
/// An unpinned host gets default handling.
final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinning: [String: PinningPolicy]

    init(pinning: [String: PinningPolicy]) { self.pinning = pinning }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        let policy = pinning[host] ?? .none

        switch policy {
        case .none:
            completionHandler(.performDefaultHandling, nil)

        case .certificates(let pinned):
            guard evaluate(trust), validateCertificates(trust: trust, pinned: pinned) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        case .publicKeys(let pinned):
            guard evaluate(trust), validatePublicKeys(trust: trust, pinned: pinned) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// Whether the system trusts `trust`. A pin match alone must not accept the connection: answering
    /// `.useCredential` skips URLSession's own evaluation.
    ///
    /// The trust keeps the policies URLSession set, including the SSL policy for the challenge's host.
    /// Evaluation can block on network fetches (revocation, missing intermediates); it runs on the session's
    /// delegate queue, never on the main thread.
    private func evaluate(_ trust: SecTrust) -> Bool {
        SecTrustEvaluateWithError(trust, nil)
    }

    private func validateCertificates(trust: SecTrust, pinned: [Data]) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return false
        }
        let serverDERs = chain.map { SecCertificateCopyData($0) as Data }
        return serverDERs.contains(where: { pinned.contains($0) })
    }

    private func validatePublicKeys(trust: SecTrust, pinned: [Data]) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return false
        }
        let serverKeys = chain.compactMap { cert -> Data? in
            guard let key = SecCertificateCopyKey(cert),
                  let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
            return keyData
        }

        let pinnedKeys: [Data] = pinned.compactMap { der in
            guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let key = SecCertificateCopyKey(cert),
                  let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
            return keyData
        }

        return serverKeys.contains(where: { pinnedKeys.contains($0) })
    }
}
