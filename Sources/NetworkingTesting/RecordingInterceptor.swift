import Foundation
import NetworkingCore

/// Запоминает все adapt-вызовы. Полезен в unit-тестах для проверки headers/auth логики.
public actor RecordingInterceptor: RequestInterceptor {
    public private(set) var recordedRequests: [URLRequest] = []
    public private(set) var retryAttempts: [(URLRequest, HTTPURLResponse?, Int)] = []

    public init() {}

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        recordedRequests.append(request)
        return request
    }

    public func retry(_ request: URLRequest,
                      response: HTTPURLResponse?,
                      error: any Error & Sendable,
                      attempt: Int) async -> RetryDecision {
        retryAttempts.append((request, response, attempt))
        return .doNotRetry
    }

    public func reset() {
        recordedRequests.removeAll()
        retryAttempts.removeAll()
    }
}
