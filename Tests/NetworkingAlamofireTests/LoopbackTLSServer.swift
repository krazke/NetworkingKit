import Foundation
import Network
import Security

/// A TLS server on 127.0.0.1 for tests that need a real TLS connection and server trust challenge.
///
/// It presents a self-signed certificate that the system does not trust, so a connection to it always fails
/// system trust evaluation, whichever pin the client has. It answers any request with an empty 200 response,
/// which a client reaches only if it accepts the certificate. The identity is created in memory, without the
/// keychain.
///
/// The certificates are DER-encoded P-256 certificates for `CN=127.0.0.1` (SAN `IP:127.0.0.1`, `serverAuth`)
/// with one key, made with OpenSSL 3.6:
/// - `certificate`: valid 2026-10-08…2036-10-05.
/// - `expiredCertificate`: valid 2024-01-01…2025-01-01.
///
/// ```sh
/// openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out key.pem
/// # ext: basicConstraints=critical,CA:FALSE; keyUsage=critical,digitalSignature;
/// #      extendedKeyUsage=serverAuth; subjectAltName=IP:127.0.0.1
/// openssl req -new -key key.pem -subj "/CN=127.0.0.1" -out csr
/// openssl x509 -req -in csr -signkey key.pem -out cert.pem -days 3650 -extfile ext
/// openssl x509 -req -in csr -signkey key.pem -out expired.pem \
///   -not_before 20240101000000Z -not_after 20250101000000Z -extfile ext
/// openssl x509 -in cert.pem -outform der | base64   # likewise for expired.pem
/// # `privateKey` is the X9.63 encoding SecKeyCreateWithData expects: the `pub` bytes (04 || X || Y)
/// # followed by the 32 `priv` bytes printed by `openssl ec -in key.pem -noout -text`.
/// ```
///
/// The same file is in `NetworkingURLSessionTests` and `NetworkingAlamofireTests`; keep both copies identical.
final class LoopbackTLSServer: @unchecked Sendable {
    static let host = "127.0.0.1"

    static let certificate = der("""
        MIIBjzCCATWgAwIBAgIUSjI/mV0W6MVCvcUMFqA9MWLIxU4wCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2
        MTAwODE3NDQ1OVoXDTM2MTAwNTE3NDQ1OVowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE
        UOOjRwU/IoZ0NX4WBHRGgeYksh5PJZRQ40JZCDy2s9CkL6SyV47KUpztyksVS9cINeNzpkHW5ZHOuWX0JNnaIaNlMGMwDAYDVR0T
        AQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0RBAgwBocEfwAAATAdBgNVHQ4EFgQU1OiO
        gg3ajCUWFc9Vz5Z0pADEDyswCgYIKoZIzj0EAwIDSAAwRQIhAKE3gI3nJvRW5QkDyHzIztWXJV6WFttEp9ZixAkKdFKVAiBOocIN
        MHiARoC/e4c5O1WXvhN2tpeJlMpHGvXMTpDclQ==
        """)

    static let expiredCertificate = der("""
        MIIBjzCCATWgAwIBAgIUbcHeVCakFVVOCk7mb6WZhOXPBacwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI0
        MDEwMTAwMDAwMFoXDTI1MDEwMTAwMDAwMFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE
        UOOjRwU/IoZ0NX4WBHRGgeYksh5PJZRQ40JZCDy2s9CkL6SyV47KUpztyksVS9cINeNzpkHW5ZHOuWX0JNnaIaNlMGMwDAYDVR0T
        AQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0RBAgwBocEfwAAATAdBgNVHQ4EFgQU1OiO
        gg3ajCUWFc9Vz5Z0pADEDyswCgYIKoZIzj0EAwIDSAAwRQIhAIrV4Re8ARzWTbFY/84lzGGs2rQkh1mGaMR6bAx9AOLrAiA2fus6
        74sQMNLI/9he3LU1aA1dwJpPLpmt3o8z6JUGsg==
        """)

    private static let privateKey = der("""
        BFDjo0cFPyKGdDV+FgR0RoHmJLIeTyWUUONCWQg8trPQpC+ksleOylKc7cpLFUvXCDXjc6ZB1uWRzrll9CTZ2iHiQK7U2QcDou4/
        oA5YY/4OJwYS25jwBb/1IFo5dD2xRQ==
        """)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-tls-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    /// Starts a server that presents `certificate`, a DER certificate for `privateKey`.
    init(presenting certificate: Data) async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions,
                                                sec_identity_create(try Self.identity(for: certificate))!)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.host), port: .any)
        listener = try NWListener(using: parameters)

        let readiness = Readiness()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: readiness.finish(nil)
            case .failed(let error): readiness.finish(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        try await readiness.wait()
    }

    /// `https://127.0.0.1:<port>/`.
    var baseURL: URL { URL(string: "https://\(Self.host):\(listener.port!.rawValue)/")! }

    /// The TCP connections accepted so far, including those whose TLS handshake failed. Each attempt of a
    /// request opens one.
    var connectionCount: Int { lock.withLock { connections.count } }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func identity(for certificate: Data) throws -> SecIdentity {
        var error: Unmanaged<CFError>?
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                          kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes, &error) else {
            throw error!.takeRetainedValue()
        }
        guard let certificate = SecCertificateCreateWithData(nil, certificate as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw URLError(.cannotLoadFromNetwork)
        }
        return identity
    }

    private static func der(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }
}

/// Resumes one waiter with the listener's first `.ready` or `.failed` state.
private final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    func finish(_ error: (any Error)?) {
        lock.withLock {
            guard outcome == nil else { return }
            let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
            outcome = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                if let outcome { continuation.resume(with: outcome) } else { self.continuation = continuation }
            }
        }
    }
}
