import Foundation

/// Escapes field names and filenames for a multipart `Content-Disposition` header, following the
/// multipart/form-data encoding algorithm of the WHATWG HTML Standard. Both transports interpolate the
/// results into `name="…"` and `filename="…"`; without escaping, a `"`, CR or LF ends the quoted
/// string or the header line early.
///
/// The standard replaces `"` with `%22`, CR with `%0D` and LF with `%0A`, and forbids any other escape,
/// so a literal `%` is sent as is. Before that, it normalizes every lone CR or LF in a field name to
/// CRLF; filenames are not normalized.
package enum MultipartDisposition {
    package static func escapeName(_ name: String) -> String {
        escape(normalizingLineBreaks(name))
    }

    package static func escapeFilename(_ filename: String) -> String {
        escape(filename)
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "%22"
            case "\r": result += "%0D"
            case "\n": result += "%0A"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func normalizingLineBreaks(_ string: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\r":
                result.append(contentsOf: ["\r", "\n"])
                previousWasCR = true
            case "\n":
                // The LF of a CRLF pair was already emitted together with its CR.
                if !previousWasCR { result.append(contentsOf: ["\r", "\n"]) }
                previousWasCR = false
            default:
                result.append(scalar)
                previousWasCR = false
            }
        }
        return String(result)
    }
}
