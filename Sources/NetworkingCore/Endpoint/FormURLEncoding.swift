import Foundation

/// Serializes `RequestBody.urlEncoded` fields as `application/x-www-form-urlencoded`, following the
/// WHATWG URL Standard's urlencoded serializer: every UTF-8 byte except ASCII alphanumerics and
/// `*`, `-`, `.`, `_` is percent-encoded, and a space becomes `+`.
///
/// Both transports use it so they send identical bodies. `URLComponents.percentEncodedQuery` is not a
/// substitute: it leaves `+` as is, which servers decode as a space.
package enum FormURLEncoding {
    /// Fields are sorted by name, because `[String: String]` has no order and a stable body is easier
    /// to log, sign and compare.
    package static func encode(_ fields: [String: String]) -> Data {
        let pairs = fields
            .sorted { $0.key < $1.key }
            .map { escape($0.key) + "=" + escape($0.value) }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func escape(_ string: String) -> String {
        let hexDigits = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                bytes.append(byte)
            case UInt8(ascii: " "):
                bytes.append(UInt8(ascii: "+"))
            default:
                bytes += [UInt8(ascii: "%"), hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]]
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
