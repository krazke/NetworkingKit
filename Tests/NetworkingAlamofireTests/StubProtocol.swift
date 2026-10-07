import Foundation

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
        let delay: TimeInterval
        /// Fails the request with this error instead of responding.
        var failure: URLError? = nil
        /// Responds with a plain `URLResponse`, as a non-HTTP URL scheme would.
        var isHTTP = true

        static func failing(_ code: URLError.Code, delay: TimeInterval = 0) -> Stub {
            .init(statusCode: 0, data: Data(), headers: [:], delay: delay, failure: URLError(code))
        }
    }

    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) static private(set) var requests: [URLRequest] = []
    nonisolated(unsafe) static private(set) var bodies: [Data?] = []
    static let queue = DispatchQueue(label: "stub-protocol-af")

    static func reset(responder: (@Sendable (URLRequest) -> Stub)? = nil) {
        queue.sync {
            requests.removeAll()
            bodies.removeAll()
            self.responder = responder
        }
    }

    static var recordedRequests: [URLRequest] { queue.sync { requests } }

    /// Request bodies in the order they arrived. URLProtocol usually receives the body as
    /// `httpBodyStream` rather than `httpBody`, so it is read in `startLoading`.
    static var recordedBodies: [Data?] { queue.sync { bodies } }

    struct WaitTimeout: Error { let expected: Int; let received: Int }

    /// Polls until at least `count` requests have arrived.
    ///
    /// - Throws: `WaitTimeout` when they have not arrived within `timeout`.
    static func waitForRequests(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while recordedRequests.count < count {
            guard ContinuousClock.now < deadline else {
                throw WaitTimeout(expected: count, received: recordedRequests.count)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = self.request
        let body = req.httpBody ?? req.httpBodyStream.map(Self.readAll)
        Self.queue.sync {
            Self.requests.append(req)
            Self.bodies.append(body)
        }

        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = responder(req)
        let proto = self
        let send: @Sendable () -> Void = {
            if let failure = stub.failure {
                proto.client?.urlProtocol(proto, didFailWithError: failure)
                return
            }
            let response = stub.isHTTP
                ? HTTPURLResponse(url: req.url!,
                                  statusCode: stub.statusCode,
                                  httpVersion: "HTTP/1.1",
                                  headerFields: stub.headers)!
                : URLResponse(url: req.url!,
                              mimeType: stub.headers["Content-Type"],
                              expectedContentLength: stub.data.count,
                              textEncodingName: nil)
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

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return c
    }
}
