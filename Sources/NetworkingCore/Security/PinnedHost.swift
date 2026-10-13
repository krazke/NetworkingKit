import Foundation

/// The form in which both transports compare `NetworkConfiguration.pinning` keys with the host a server trust
/// challenge names.
///
/// URLSession names the host in lowercase, keeps a trailing dot and writes an IPv6 address without brackets and
/// as the URL spells it. The system trusts a certificate for `api.example.com` also for `api.example.com.`, so the
/// canonical form drops one trailing dot: otherwise a URL with the dot would bypass the host's pins. An
/// internationalized name reaches the challenge in punycode, because `URL` converts it.
package enum PinnedHost {
    /// `host`, as a server trust challenge names it, in canonical form: lowercased, without one trailing dot, and
    /// an IPv6 address in its shortest spelling.
    package static func canonical(_ host: String) -> String {
        if let address = ipv6Address(host) { return address }
        let lowered = host.lowercased()
        return lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
    }

    /// `key` in the canonical form of `canonical(_:)`.
    ///
    /// - Throws: `PinningKeyError` when `key` is not a host name or an IP address: it is empty, has a scheme,
    ///   port, path, query, fragment, user info, wildcard, whitespace or an empty label, or is not ASCII.
    package static func canonicalKey(_ key: String) throws -> String {
        if key.hasPrefix("[") && key.hasSuffix("]") {
            guard let address = ipv6Address(String(key.dropFirst().dropLast())) else {
                throw PinningKeyError(key: key, problem: "has brackets but is not an IPv6 address")
            }
            return address
        }
        if let address = ipv6Address(key) { return address }

        if let invalid = key.unicodeScalars.first(where: { !allowed.contains($0) }) {
            throw PinningKeyError(key: key, problem: problem(with: invalid))
        }
        let name = key.hasSuffix(".") ? String(key.dropLast()) : key
        guard !name.isEmpty, !name.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else {
            throw PinningKeyError(key: key, problem: "is empty or has an empty label")
        }
        return name.lowercased()
    }

    /// `pinning` with every key in canonical form. Keys that name the same host and have the same policy become
    /// one key.
    ///
    /// - Throws: `PinningKeyError` for a key that `canonicalKey(_:)` rejects, and for keys that name the same
    ///   host with different policies, because which one applied would depend on the dictionary's order.
    package static func canonicalKeys(_ pinning: [String: PinningPolicy]) throws -> [String: PinningPolicy] {
        var result: [String: (key: String, policy: PinningPolicy)] = [:]
        // Sorted, so that the error for several invalid keys does not depend on the dictionary's order.
        for key in pinning.keys.sorted() {
            let policy = pinning[key]!
            let host = try canonicalKey(key)
            if let earlier = result[host], !isSame(earlier.policy, policy) {
                throw PinningKeyError(key: key,
                                      problem: "names the same host as \"\(earlier.key)\" with a different policy")
            }
            result[host] = (key, policy)
        }
        return result.mapValues(\.policy)
    }

    /// `pinning` with canonical keys, for a transport's initializer. Stops the app on a key that
    /// `canonicalKeys(_:)` rejects: a key that names no host would leave the host it was meant for unpinned.
    package static func requireCanonicalKeys(_ pinning: [String: PinningPolicy]) -> [String: PinningPolicy] {
        do {
            return try canonicalKeys(pinning)
        } catch {
            preconditionFailure("NetworkConfiguration.pinning: \(error)")
        }
    }

    /// Letters, digits, `-`, `_` and `.`: an ASCII host name or an IPv4 address.
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        .union(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."))

    private static func problem(with scalar: Unicode.Scalar) -> String {
        switch scalar {
        case ":": return "has a scheme or a port; write the host name only"
        case "/", "?", "#": return "has a path, query or fragment; write the host name only"
        case "@": return "has user info; write the host name only"
        case "*": return "has a wildcard; list every host"
        case _ where !scalar.isASCII:
            return "is not ASCII; write an internationalized name in punycode (xn--…)"
        default: return "has \"\(scalar.escaped(asASCII: true))\", which a host name cannot contain"
        }
    }

    /// `string` in the shortest spelling of an IPv6 address, or `nil` when it is not one.
    private static func ipv6Address(_ string: String) -> String? {
        guard string.contains(":") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, string, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func isSame(_ lhs: PinningPolicy, _ rhs: PinningPolicy) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.certificates(let l), .certificates(let r)), (.publicKeys(let l), .publicKeys(let r)): return l == r
        default: return false
        }
    }
}

/// A `NetworkConfiguration.pinning` key that names no host, or names the same host as another key with a
/// different policy.
package struct PinningKeyError: Error, CustomStringConvertible {
    package let key: String
    package let problem: String

    package var description: String { "the key \"\(key)\" \(problem)" }
}
