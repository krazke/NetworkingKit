import Foundation

public enum HTTPStatus {
    public static func is2xx(_ code: Int) -> Bool { (200..<300).contains(code) }
    public static func is3xx(_ code: Int) -> Bool { (300..<400).contains(code) }
    public static func is4xx(_ code: Int) -> Bool { (400..<500).contains(code) }
    public static func is5xx(_ code: Int) -> Bool { (500..<600).contains(code) }
    public static func isRetryable(_ code: Int) -> Bool {
        code == 408 || code == 425 || code == 429 || (500..<600).contains(code)
    }
}
