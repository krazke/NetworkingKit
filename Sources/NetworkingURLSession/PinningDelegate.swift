import Foundation
import Security
import NetworkingCore

/// URLSessionDelegate, валидирующий server trust по `PinningPolicy`.
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
            guard validateCertificates(trust: trust, pinned: pinned) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        case .publicKeys(let pinned):
            guard validatePublicKeys(trust: trust, pinned: pinned) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
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
