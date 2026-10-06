import Foundation

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
        let delay: TimeInterval
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
