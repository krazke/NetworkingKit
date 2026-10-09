import Foundation
import Security
import Alamofire
import NetworkingCore

/// Builds the Alamofire `ServerTrustManager` for `NetworkConfiguration.pinning`.
enum ServerTrustFactory {
    /// The manager with an evaluator for every pinned host, or `nil` when no host is pinned.
    ///
    /// Every evaluator runs the system's trust evaluation, with host validation, before it compares pins, as
    /// `PinningDelegate` does in the URLSession transport. A host whose list is empty or holds no certificate that
    /// can be parsed gets an evaluator that rejects every trust: no pin can match, and skipping the host would
    /// leave it unpinned.
    static func makeManager(_ pinning: [String: PinningPolicy]) -> ServerTrustManager? {
        var evaluators: [String: ServerTrustEvaluating] = [:]

        for (host, policy) in pinning {
            switch policy {
            case .none:
                continue

            case .certificates(let derList):
                let certs = derList.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                evaluators[host] = certs.isEmpty
                    ? unmatchableEvaluator()
                    : PinnedCertificatesTrustEvaluator(certificates: certs)

            case .publicKeys(let derList):
                let keys: [SecKey] = derList.compactMap { der in
                    guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                          let key = SecCertificateCopyKey(cert) else { return nil }
                    return key
                }
                evaluators[host] = keys.isEmpty ? unmatchableEvaluator() : PublicKeysTrustEvaluator(keys: keys)
            }
        }

        return evaluators.isEmpty ? nil : ServerTrustManager(evaluators: evaluators)
    }

    /// Rejects every trust: the system's evaluation first, then `noCertificatesFound`, which
    /// `PinnedCertificatesTrustEvaluator` throws for an empty list before it evaluates anything. The request then
    /// fails with the same `PinningError` reason as in the URLSession transport.
    private static func unmatchableEvaluator() -> ServerTrustEvaluating {
        CompositeTrustEvaluator(evaluators: [DefaultTrustEvaluator(),
                                             PinnedCertificatesTrustEvaluator(certificates: [])])
    }
}
