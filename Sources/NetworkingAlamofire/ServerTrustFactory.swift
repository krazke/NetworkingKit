import Foundation
import Security
import Alamofire
import NetworkingCore

/// Превращает [host: PinningPolicy] в Alamofire.ServerTrustManager.
enum ServerTrustFactory {
    static func makeManager(_ pinning: [String: PinningPolicy]) -> ServerTrustManager? {
        var evaluators: [String: ServerTrustEvaluating] = [:]

        for (host, policy) in pinning {
            switch policy {
            case .none:
                continue

            case .certificates(let derList):
                let certs = derList.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                guard !certs.isEmpty else { continue }
                evaluators[host] = PinnedCertificatesTrustEvaluator(certificates: certs)

            case .publicKeys(let derList):
                let keys: [SecKey] = derList.compactMap { der in
                    guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                          let key = SecCertificateCopyKey(cert) else { return nil }
                    return key
                }
                guard !keys.isEmpty else { continue }
                evaluators[host] = PublicKeysTrustEvaluator(keys: keys)
            }
        }

        return evaluators.isEmpty ? nil : ServerTrustManager(evaluators: evaluators)
    }
}
