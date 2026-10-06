import Foundation
import Alamofire
import NetworkingCore

/// Превращает APIEndpoint → URLRequest для Alamofire.
/// Multipart-варианты обрабатываются отдельно (см. AlamofireAPIClient.upload).
struct EndpointAdapter: URLRequestConvertible {
    let endpoint: APIEndpoint
    let baseURL: URL
    let encoder: JSONEncoder

    func asURLRequest() throws -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint.path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query = endpoint.query, !query.isEmpty {
            let existing = components?.queryItems ?? []
            components?.queryItems = existing + query
        }

        guard let finalURL = components?.url else {
            throw APIError.transport(URLError(.badURL))
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = endpoint.method.rawValue
        if let timeout = endpoint.timeout { request.timeoutInterval = timeout }

        // Per-endpoint headers
        if let headers = endpoint.headers {
            for (name, value) in headers.dictionary {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        // Body
        switch endpoint.body {
        case .empty:
            break

        case .json(let encodable):
            do {
                request.httpBody = try encoder.encode(AnyEncodable(encodable))
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } catch {
                throw APIError.encoding(NonSendableErrorBox(error))
            }

        case .urlEncoded(let dict):
            request.httpBody = FormURLEncoding.encode(dict)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                                 forHTTPHeaderField: "Content-Type")
            }

        case .multipart:
            // Multipart body строится в AlamofireAPIClient.upload, здесь — только заголовки.
            break

        case .raw(let data, let contentType):
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        return request
    }
}

/// Стирает existential `any Encodable & Sendable`.
private struct AnyEncodable: Encodable {
    let value: any Encodable & Sendable
    init(_ value: any Encodable & Sendable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Боксирует non-Sendable Error.
struct NonSendableErrorBox: Error, @unchecked Sendable {
    let underlying: any Error
    init(_ underlying: any Error) { self.underlying = underlying }
    var localizedDescription: String { underlying.localizedDescription }
}
