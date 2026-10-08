import Foundation
import Security

/// Server trust challenges for pinning tests, built as URLSession builds them for a TLS connection.
///
/// The same file is in `NetworkingURLSessionTests` and `NetworkingAlamofireTests`; keep both copies identical.
enum ServerTrustChallenge {
    /// A challenge from `host` on port 443 that presents `trust`. Its sender ignores every answer, so the
    /// delegate under test must answer through its completion handler.
    static func make(host: String, trust: SecTrust) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(protectionSpace: ServerTrustProtectionSpace(host: host, trust: trust),
                                   proposedCredential: nil,
                                   previousFailureCount: 0,
                                   failureResponse: nil,
                                   error: nil,
                                   sender: IgnoringChallengeSender())
    }
}

/// A server trust protection space with a given trust. `URLProtectionSpace` has no initializer that takes one.
private final class ServerTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust) {
        self.trust = trust
        super.init(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                   authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

/// The delegates answer through their completion handlers, so the sender is never used.
private final class IgnoringChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
