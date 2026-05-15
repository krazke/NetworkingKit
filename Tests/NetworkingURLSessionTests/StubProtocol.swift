import Foundation

/// URLProtocol-стаб для тестов транспорта без реальной сети.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
        let delay: TimeInterval
    }

    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) static private(set) var requests: [URLRequest] = []
    static let queue = DispatchQueue(label: "stub-protocol")

    static func reset(responder: (@Sendable (URLRequest) -> Stub)? = nil) {
        queue.sync {
            requests.removeAll()
            self.responder = responder
        }
    }

    static var recordedRequests: [URLRequest] {
        queue.sync { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = self.request
        Self.queue.sync { Self.requests.append(req) }

        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = responder(req)

        let proto = self
        let send: @Sendable () -> Void = {
            let response = HTTPURLResponse(url: req.url!,
                                           statusCode: stub.statusCode,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: stub.headers)!
            proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocol(proto, didLoad: stub.data)
            proto.client?.urlProtocolDidFinishLoading(proto)
        }

        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: send)
        } else {
            send()
        }
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return c
    }
}
