import Foundation
import Security

/// Certificates and server trusts for pinning tests.
///
/// The certificates are DER-encoded P-256 certificates made with OpenSSL 3.6:
/// - `ca`: a self-signed CA, valid 2026-10-08…2036-10-05.
/// - `leaf`: issued by `ca` for `pinned.test` and `localhost` (SAN, `serverAuth`), valid 2026-10-08…2027-10-08.
/// - `expiredLeaf`: the same subject and key as `leaf`, issued by `ca`, valid 2024-01-01…2025-01-01.
/// - `unrelated`: a self-signed certificate for `other.test` with its own key.
///
/// ```sh
/// openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 3650 \
///   -subj "/CN=NetworkingKit Test CA" -addext "basicConstraints=critical,CA:TRUE" \
///   -addext "keyUsage=critical,keyCertSign,cRLSign"
/// openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=pinned.test"
/// # leaf.ext: basicConstraints=critical,CA:FALSE; keyUsage=critical,digitalSignature;
/// #           extendedKeyUsage=serverAuth; subjectAltName=DNS:pinned.test,DNS:localhost
/// openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 365 -extfile leaf.ext
/// openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -out expired.pem \
///   -not_before 20240101000000Z -not_after 20250101000000Z -extfile leaf.ext
/// openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout other.key -out other.pem \
///   -days 365 -subj "/CN=other.test"
/// openssl x509 -in leaf.pem -outform der | base64   # likewise for the others
/// ```
///
/// The same file is in `NetworkingURLSessionTests` and `NetworkingAlamofireTests`; keep both copies identical.
enum PinningFixtures {
    /// The host `leaf` is issued for.
    static let host = "pinned.test"
    /// A host `leaf` is not issued for.
    static let wrongHost = "other.test"

    /// Every trust is evaluated at this date, inside the validity of `ca` and `leaf` and after `expiredLeaf`
    /// expired, so the tests do not depend on the clock.
    static let verifyDate = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01T00:00:00Z

    static let ca = der("""
        MIIBpTCCAUugAwIBAgIUJl/w8Qgs1DaoQEfL8vIRYdbRRsgwCgYIKoZIzj0EAwIwIDEeMBwGA1UEAwwVTmV0d29ya2luZ0tpdCBU
        ZXN0IENBMB4XDTI2MTAwODEyMjUwMVoXDTM2MTAwNTEyMjUwMVowIDEeMBwGA1UEAwwVTmV0d29ya2luZ0tpdCBUZXN0IENBMFkw
        EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEax2jJ4OFTY3MW34JTXzKyrhjBKEjzYYNioBrTuMJvbgBcBA8U2blI2tb+2caT8dRMgx7
        9J4EJsTmXH9VCDaty6NjMGEwHQYDVR0OBBYEFHq2TbtIHNSfjbSwHRvKoAAMonGvMB8GA1UdIwQYMBaAFHq2TbtIHNSfjbSwHRvK
        oAAMonGvMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gAMEUCIGWydMCqHfrK+U+evF8xSBEm
        XW5Qj+PxIstpkg5cP5FmAiEA2KJxc5F3vtCpQOIb12FajLSP7FIkV51sgvi/LsJYazw=
        """)

    static let leaf = der("""
        MIIB0zCCAXigAwIBAgIUHw68hIcE6hMhYNzOsXbMTr+HXlcwCgYIKoZIzj0EAwIwIDEeMBwGA1UEAwwVTmV0d29ya2luZ0tpdCBU
        ZXN0IENBMB4XDTI2MTAwODEyMjUwMVoXDTI3MTAwODEyMjUwMVowFjEUMBIGA1UEAwwLcGlubmVkLnRlc3QwWTATBgcqhkjOPQIB
        BggqhkjOPQMBBwNCAAQs5dC9ZQtAJgMXFGubOneYh6bNmlDf3o2+UkGhzncK8Gnfto3uPHTG4yQmpQZdjqoHAj84FjNQtVp68z2Q
        cKrfo4GZMIGWMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCEGA1UdEQQaMBiCC3Bp
        bm5lZC50ZXN0gglsb2NhbGhvc3QwHQYDVR0OBBYEFI2IJzDHiWP9KEndnn6Siz/EI8zzMB8GA1UdIwQYMBaAFHq2TbtIHNSfjbSw
        HRvKoAAMonGvMAoGCCqGSM49BAMCA0kAMEYCIQDTAZHUDKDa/paV7IBDxmVON9WP1WHnmXMc6D0xSrphZQIhAKFcPe2bocJHPWot
        cWPdaKJz3aJdJDXG6196ZdpqYYhI
        """)

    static let expiredLeaf = der("""
        MIIB0zCCAXigAwIBAgIUHw68hIcE6hMhYNzOsXbMTr+HXlgwCgYIKoZIzj0EAwIwIDEeMBwGA1UEAwwVTmV0d29ya2luZ0tpdCBU
        ZXN0IENBMB4XDTI0MDEwMTAwMDAwMFoXDTI1MDEwMTAwMDAwMFowFjEUMBIGA1UEAwwLcGlubmVkLnRlc3QwWTATBgcqhkjOPQIB
        BggqhkjOPQMBBwNCAAQs5dC9ZQtAJgMXFGubOneYh6bNmlDf3o2+UkGhzncK8Gnfto3uPHTG4yQmpQZdjqoHAj84FjNQtVp68z2Q
        cKrfo4GZMIGWMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCEGA1UdEQQaMBiCC3Bp
        bm5lZC50ZXN0gglsb2NhbGhvc3QwHQYDVR0OBBYEFI2IJzDHiWP9KEndnn6Siz/EI8zzMB8GA1UdIwQYMBaAFHq2TbtIHNSfjbSw
        HRvKoAAMonGvMAoGCCqGSM49BAMCA0kAMEYCIQDsi4N4D4YLjxKwfsPvBPeejsIcgtzwbxqYO1EkWKy04gIhAPFLuIQyIPK1Ihuz
        Q7k8h729WtOi7KB+AcVzOFLjL4ex
        """)

    static let unrelated = der("""
        MIIBfzCCASWgAwIBAgIUR1Vrd1N9HBZd6vx+o0ydKpogXewwCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKb3RoZXIudGVzdDAeFw0y
        NjEwMDgxMjI1MDFaFw0yNzEwMDgxMjI1MDFaMBUxEzARBgNVBAMMCm90aGVyLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
        AAQLpSV6f1kqw67VMBcJg6wSklSbEnvcsDMXfKowxkpSkFSEmGX9t3jW/dJfICUP54mCMXpNGUvUhLBojkz3833eo1MwUTAdBgNV
        HQ4EFgQUmtGXvBW+L+sxZfsqeDNGpg9IKAkwHwYDVR0jBBgwFoAUmtGXvBW+L+sxZfsqeDNGpg9IKAkwDwYDVR0TAQH/BAUwAwEB
        /zAKBggqhkjOPQQDAgNIADBFAiAx+kFthM1WdySSKahvEGIG7hEOrEBpFhh62q9E5p8wawIhAKd9/e0Z6MJB52WGOC7ywhfyH461
        u29Eev9Wck+SCL6U
        """)

    /// A trust for `certificate` presented by `host`, set up as URLSession sets up the trust of a server trust
    /// challenge: an SSL server policy for `host` and no intermediates.
    ///
    /// - Parameter anchored: Whether `ca` is the trust's only anchor. Without it the chain ends in a root the
    ///   system does not trust.
    static func serverTrust(presenting certificate: Data, forHost host: String, anchored: Bool = true) -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates([secCertificate(certificate)] as CFArray,
                                                    SecPolicyCreateSSL(true, host as CFString),
                                                    &trust)
        precondition(status == errSecSuccess, "SecTrustCreateWithCertificates failed: \(status)")
        if anchored {
            SecTrustSetAnchorCertificates(trust!, [secCertificate(ca)] as CFArray)
        }
        SecTrustSetVerifyDate(trust!, verifyDate as CFDate)
        return trust!
    }

    static func secCertificate(_ der: Data) -> SecCertificate {
        SecCertificateCreateWithData(nil, der as CFData)!
    }

    private static func der(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
    }
}
