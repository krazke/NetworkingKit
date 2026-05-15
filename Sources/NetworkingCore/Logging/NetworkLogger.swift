import Foundation

/// Транспорт-агностичный логгер. Адаптеры (Pulse/OSLog) реализуются на стороне приложения.
public protocol NetworkLogger: Sendable {
    func willSend(_ request: URLRequest)
    func didReceive(_ request: URLRequest,
                    response: HTTPURLResponse?,
                    data: Data?,
                    duration: TimeInterval)
    func didFail(_ request: URLRequest, error: any Error & Sendable)
}

/// Дефолтный print-логгер — для разработки.
public struct ConsoleNetworkLogger: NetworkLogger {
    public init() {}

    public func willSend(_ request: URLRequest) {
        let m = request.httpMethod ?? "?"
        let u = request.url?.absoluteString ?? "?"
        print("→ \(m) \(u)")
    }

    public func didReceive(_ request: URLRequest,
                           response: HTTPURLResponse?,
                           data: Data?,
                           duration: TimeInterval) {
        let code = response?.statusCode ?? 0
        let u = request.url?.absoluteString ?? "?"
        let symbol = (200..<300).contains(code) ? "←" : "✗"
        print("\(symbol) \(code) \(u) [\(Int(duration * 1000))ms, \(data?.count ?? 0)B]")
    }

    public func didFail(_ request: URLRequest, error: any Error & Sendable) {
        let u = request.url?.absoluteString ?? "?"
        print("✗ \(u) — \(error)")
    }
}
