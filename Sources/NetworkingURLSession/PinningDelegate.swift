import Foundation
import Security
import NetworkingCore

/// Answers server trust challenges according to `PinningPolicy`.
///
/// For a pinned host the system first evaluates the trust as URLSession presents it, so expiry, the host name
/// and the chain to a trusted root are checked as with default handling; only then are the pins compared with
/// the evaluated chain. A failure of either cancels the challenge, which fails the task with `URLError.cancelled`,
/// and is recorded for `failure(forHost:)`. An unpinned host gets default handling.
final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinning: [String: PinningPolicy]
    private let lock = NSLock()
    private var failures: [String: PinningError] = [:]

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
        let matchesPin: (SecTrust) -> Bool
        switch pinning[host] ?? .none {
        case .none:
            return completionHandler(.performDefaultHandling, nil)
        case .certificates(let pinned):
            matchesPin = { self.validateCertificates(trust: $0, pinned: pinned) }
        case .publicKeys(let pinned):
            matchesPin = { self.validatePublicKeys(trust: $0, pinned: pinned) }
        }

        guard evaluate(trust) else {
            return reject(host, because: .trustEvaluationFailed, completionHandler)
        }
        guard matchesPin(trust) else {
            return reject(host, because: .pinMismatch, completionHandler)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// The last rejection of `host`'s trust, or `nil` when none was rejected.
    ///
    /// URLSession reports a cancelled challenge only as `URLError.cancelled`, without the reason, so the client
    /// looks the reason up by host. A later accepted challenge keeps the record: the client asks only about a task
    /// that failed with `URLError.cancelled` while its caller was not cancelled, which in this client only a
    /// rejected challenge causes, and clearing the record could race with that task's own failure.
    func failure(forHost host: String) -> PinningError? {
        lock.withLock { failures[host] }
    }

    private func reject(_ host: String,
                        because reason: PinningError.Reason,
                        _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.withLock { failures[host] = PinningError(host: host, reason: reason) }
        completionHandler(.cancelAuthenticationChallenge, nil)
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
