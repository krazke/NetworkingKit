import Foundation
import Alamofire
import NetworkingCore

/// Мост между NetworkingCore.RequestInterceptor (async) и Alamofire.RequestInterceptor (callback).
final class InterceptorBridge: Alamofire.RequestInterceptor {
    private let core: any NetworkingCore.RequestInterceptor
    private let decidedAttempts = DecidedAttempts()

    init(_ core: any NetworkingCore.RequestInterceptor) { self.core = core }

    func adapt(_ urlRequest: URLRequest,
               for session: Alamofire.Session,
               completion: @escaping (Result<URLRequest, Error>) -> Void) {
        let core = self.core
        let box = SendableCompletionBox(completion)
        Task {
            do {
                let adapted = try await core.adapt(urlRequest)
                box.value(.success(adapted))
            } catch {
                box.value(.failure(error))
            }
        }
    }

    func retry(_ request: Alamofire.Request,
               for session: Alamofire.Session,
               dueTo error: Error,
               completion: @escaping (RetryResult) -> Void) {
        // After a cancellation Alamofire finishes the request and its response serializer asks again.
        // Asking for a retry then would never complete the request: `Session` skips retries of cancelled requests.
        guard !request.isCancelled else {
            completion(.doNotRetry)
            return
        }
        // Alamofire also asks after failures that `URLSessionAPIClient` never passes to `retry`.
        guard let inputs = Self.retryInputs(for: error, of: request) else {
            completion(.doNotRetry)
            return
        }
        // Alamofire asks again from the response serializer after the request finishes with this attempt's
        // error. Asking the chain twice would, for example, call `refreshAction` twice for a rejected refresh.
        guard decidedAttempts.claim(request) else {
            completion(.doNotRetry)
            return
        }
        let core = self.core
        let box = SendableRetryBox(completion)
        // Alamofire forgets a retried download's file without deleting it, so it is deleted here.
        let failedDownload = (request as? DownloadRequest)?.fileURL
        let urlRequest = request.request ?? URLRequest(url: URL(string: "about:blank")!)
        let attempt = request.retryCount + 1

        Task {
            let decision = await core.retry(urlRequest,
                                            response: inputs.response,
                                            error: inputs.error,
                                            attempt: attempt)
            switch decision.validated {
            case .doNotRetry:
                box.value(.doNotRetry)
            case .retry:
                Self.discard(failedDownload)
                box.value(.retry)
            case .retryAfter(let delay):
                Self.discard(failedDownload)
                box.value(.retryWithDelay(delay))
            }
        }
    }

    private static func discard(_ download: URL?) {
        if let download { try? FileManager.default.removeItem(at: download) }
    }

    /// The `response` and `error` that `NetworkingCore.RequestInterceptor.retry` gets for `error`, as
    /// `URLSessionAPIClient` passes them, or `nil` when the failure must not reach the chain.
    ///
    /// - Returns: `nil` for a failure before the request is sent (building the request or the multipart
    ///   body, `adapt`, or Alamofire's request validation) and for a 2xx response whose body cannot be
    ///   serialized. No response and the `URLError` for a transport error, even when the task received
    ///   headers before it failed. Otherwise the attempt's response and the `APIError` the request fails
    ///   with, which for a non-2xx status carries the response body of a data or upload request (`nil` when
    ///   the body is empty).
    private static func retryInputs(for error: any Error,
                                    of request: Alamofire.Request) -> (response: HTTPURLResponse?, error: any Error & Sendable)? {
        guard let af = error as? AFError else {
            return (request.response, AlamofireAPIClient.mapError(error))
        }
        switch af {
        case .createURLRequestFailed, .urlRequestValidationFailed, .requestAdaptationFailed,
             .multipartEncodingFailed, .createUploadableFailed:
            return nil
        case .responseSerializationFailed:
            return nil
        case .sessionTaskFailed(error: let urlError as URLError):
            return (nil, urlError)
        default:
            return (request.response, AlamofireAPIClient.mapError(af, responseBody: (request as? DataRequest)?.data))
        }
    }
}

/// The attempts whose failure the chain has already been asked about.
private final class DecidedAttempts: @unchecked Sendable {
    private struct Entry {
        weak var request: Alamofire.Request?
        let retryCount: Int
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    /// Claims `request`'s current attempt.
    ///
    /// - Returns: `false` when the attempt was already claimed. A retried request starts a new attempt,
    ///   so a second claim for the same attempt can only follow a decision not to retry.
    func claim(_ request: Alamofire.Request) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let retryCount = request.retryCount
        if entries[request.id]?.retryCount == retryCount { return false }
        // Entries live as long as their request; dropping released ones keeps the table small.
        entries = entries.filter { $0.value.request != nil }
        entries[request.id] = Entry(request: request, retryCount: retryCount)
        return true
    }
}

/// Sendable-обёртки над AF callback-замыканиями (AF 5.11 ещё не Sendable).
private struct SendableCompletionBox: @unchecked Sendable {
    let value: (Result<URLRequest, Error>) -> Void
    init(_ v: @escaping (Result<URLRequest, Error>) -> Void) { self.value = v }
}

private struct SendableRetryBox: @unchecked Sendable {
    let value: (RetryResult) -> Void
    init(_ v: @escaping (RetryResult) -> Void) { self.value = v }
}
