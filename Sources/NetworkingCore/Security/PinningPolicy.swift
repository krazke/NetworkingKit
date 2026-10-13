import Foundation

/// How a transport checks one host's server trust, as a value in `NetworkConfiguration.pinning`.
///
/// The keys of `pinning` are compared exactly with the host the server trust challenge names, which URLSession
/// lowercases. A host that is not a key, or whose policy is `.none`, gets the system's trust evaluation without
/// pins in both transports, also while other hosts are pinned.
public enum PinningPolicy: Sendable {
    /// No pinning: the system's trust evaluation only.
    case none
    /// Public-key pinning. Takes DER-encoded certificates; the keys are extracted from them.
    case publicKeys([Data])
    /// Certificate pinning: a byte-for-byte comparison of DER-encoded certificates.
    case certificates([Data])
}
