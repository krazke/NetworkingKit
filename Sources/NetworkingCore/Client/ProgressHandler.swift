import Foundation

/// Progress callback for `upload` and `download`: the fraction (0.0...1.0) of the current attempt's request body
/// sent (`upload`) or response body received (`download`).
///
/// Every attempt reports from its own start. When the transport retries a request, after a 401 refresh or a
/// retryable status or transport error, the reported values start over near 0, so they can decrease, and a failed
/// attempt may already have reported 1.0. Both transports behave this way.
///
/// The Alamofire transport calls the handler on the main queue; the URLSession transport calls it on its session's
/// delegate queue.
public typealias ProgressHandler = @Sendable (Double) -> Void
