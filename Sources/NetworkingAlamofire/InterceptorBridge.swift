import Foundation
import Alamofire
import NetworkingCore

/// Мост между NetworkingCore.RequestInterceptor (async) и Alamofire.RequestInterceptor (callback).
final class InterceptorBridge: Alamofire.RequestInterceptor {
    private let core: any NetworkingCore.RequestInterceptor

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
        let core = self.core
        let box = SendableRetryBox(completion)
        // Alamofire forgets a retried download's file without deleting it, so it is deleted here.
        let failedDownload = (request as? DownloadRequest)?.fileURL
        let urlRequest = request.request ?? URLRequest(url: URL(string: "about:blank")!)
        let response = request.response
        let attempt = request.retryCount + 1
        let sendableError: any Error & Sendable = NonSendableErrorBox(error)

        Task {
            let decision = await core.retry(urlRequest,
                                            response: response,
                                            error: sendableError,
                                            attempt: attempt)
            switch decision {
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
