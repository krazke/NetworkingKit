import Foundation

/// Parses the HTTP-date of RFC 9110 §5.6.7, the format of the `Date` and `Retry-After` headers.
enum HTTPDate {
    /// The date `value` names, or `nil` when it is not an HTTP-date.
    ///
    /// Accepts the preferred IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) and the obsolete RFC 850
    /// (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime (`Sun Nov  6 08:49:37 1994`) formats, all of which
    /// recipients must accept.
    ///
    /// - Parameter reference: The current time. An RFC 850 two-digit year that would be more than 50 years
    ///   after it is read as the most recent year in the past with those digits, as RFC 9110 requires.
    static func parse(_ value: String, relativeTo reference: Date) -> Date? {
        let value = value.trimmingCharacters(in: .whitespaces)

        if let date = formatter("EEE, dd MMM yyyy HH:mm:ss 'GMT'").date(from: value) {
            return date
        }

        let rfc850 = formatter("EEEE, dd-MMM-yy HH:mm:ss 'GMT'")
        rfc850.twoDigitStartDate = rfc850.calendar.date(byAdding: .year, value: -50, to: reference)
        if let date = rfc850.date(from: value) {
            return date
        }

        // asctime pads a one-digit day with a second space.
        let asctime = value.split(separator: " ").joined(separator: " ")
        return formatter("EEE MMM d HH:mm:ss yyyy").date(from: asctime)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }
}
