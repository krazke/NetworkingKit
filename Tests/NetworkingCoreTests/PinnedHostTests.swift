import XCTest
import NetworkingCore

/// The form in which both transports compare `NetworkConfiguration.pinning` keys with the host a server trust
/// challenge names, and which keys they reject. `URLSessionPinningFailureTests`, `AlamofirePinningFailureTests`
/// and the `*PinningTLSTests` check that the transports use it.
final class PinnedHostTests: XCTestCase {

    // MARK: - Challenge hosts

    func testChallengeHostKeepsCanonicalForm() {
        XCTAssertEqual(PinnedHost.canonical("api.example.com"), "api.example.com")
        XCTAssertEqual(PinnedHost.canonical("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(PinnedHost.canonical("::1"), "::1")
    }

    /// URLSession keeps a trailing dot in the challenge host, and the system trusts a certificate for the host
    /// without it, so the dot must not take the host out of pinning.
    func testChallengeHostDropsTrailingDot() {
        XCTAssertEqual(PinnedHost.canonical("api.example.com."), "api.example.com")
    }

    /// URLSession does not rewrite an IPv6 address, so the same address can arrive in several spellings.
    func testChallengeHostWritesIPv6AddressCanonically() {
        XCTAssertEqual(PinnedHost.canonical("0:0:0:0:0:0:0:1"), "::1")
        XCTAssertEqual(PinnedHost.canonical("2001:DB8::0001"), "2001:db8::1")
    }

    func testChallengeHostIsLowercased() {
        XCTAssertEqual(PinnedHost.canonical("API.Example.COM"), "api.example.com")
    }

    // MARK: - Keys

    func testKeyFormsOfOneHostShareCanonicalForm() throws {
        for key in ["api.example.com", "API.Example.COM", "api.example.com.", "Api.Example.Com."] {
            XCTAssertEqual(try PinnedHost.canonicalKey(key), "api.example.com", key)
        }
    }

    func testIPAddressKeys() throws {
        XCTAssertEqual(try PinnedHost.canonicalKey("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(try PinnedHost.canonicalKey("::1"), "::1")
        XCTAssertEqual(try PinnedHost.canonicalKey("[::1]"), "::1")
        XCTAssertEqual(try PinnedHost.canonicalKey("[2001:DB8:0:0::1]"), "2001:db8::1")
    }

    func testPunycodeKeyIsAccepted() throws {
        XCTAssertEqual(try PinnedHost.canonicalKey("XN--BCHER-KVA.example"), "xn--bcher-kva.example")
    }

    func testKeyThatIsNotHostNameIsRejected() {
        let keys = [
            "",
            ".",
            " api.example.com",
            "api example.com",
            "https://api.example.com",
            "api.example.com:443",
            "[::1]:443",
            "[api.example.com]",
            "api.example.com/v1",
            "api.example.com?x=1",
            "api.example.com#x",
            "user@api.example.com",
            "*.example.com",
            ".api.example.com",
            "api..example.com",
            "api.example.com..",
            "bücher.example",
        ]
        for key in keys {
            XCTAssertThrowsError(try PinnedHost.canonicalKey(key), "\"\(key)\"") { error in
                XCTAssertTrue(error is PinningKeyError, "\"\(key)\": \(error)")
            }
        }
    }

    // MARK: - Pinning dictionaries

    func testCanonicalKeysKeepPolicies() throws {
        let pinning = try PinnedHost.canonicalKeys(["API.Example.com": .certificates([Data([1])]),
                                                    "cdn.example.com.": .none])

        XCTAssertEqual(Set(pinning.keys), ["api.example.com", "cdn.example.com"])
        guard case .certificates(let pins)? = pinning["api.example.com"] else {
            return XCTFail("Expected .certificates, got \(String(describing: pinning["api.example.com"]))")
        }
        XCTAssertEqual(pins, [Data([1])])
        guard case PinningPolicy.none? = pinning["cdn.example.com"] else {
            return XCTFail("Expected .none, got \(String(describing: pinning["cdn.example.com"]))")
        }
    }

    func testKeysOfOneHostWithSamePolicyAreMerged() throws {
        let pinning = try PinnedHost.canonicalKeys(["api.example.com": .publicKeys([Data([1])]),
                                                    "API.example.com.": .publicKeys([Data([1])])])

        XCTAssertEqual(Array(pinning.keys), ["api.example.com"])
    }

    /// Which policy would win depends on the dictionary's order, so neither does.
    func testKeysOfOneHostWithDifferentPoliciesAreRejected() {
        let conflicts: [[String: PinningPolicy]] = [
            ["api.example.com": .publicKeys([Data([1])]), "API.example.com": .publicKeys([Data([2])])],
            ["api.example.com": .publicKeys([Data([1])]), "api.example.com.": .certificates([Data([1])])],
            ["api.example.com": .certificates([Data([1])]), "Api.Example.Com": .none],
            ["::1": .certificates([Data([1])]), "[0:0:0:0:0:0:0:1]": .certificates([])],
        ]
        for pinning in conflicts {
            XCTAssertThrowsError(try PinnedHost.canonicalKeys(pinning), "\(pinning.keys.sorted())") { error in
                XCTAssertTrue(error is PinningKeyError, "\(error)")
            }
        }
    }

    func testInvalidKeyIsRejectedInDictionary() {
        XCTAssertThrowsError(try PinnedHost.canonicalKeys(["api.example.com": .none,
                                                           "https://api.example.com": .certificates([])]))
    }
}
