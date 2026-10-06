import Foundation
import NetworkingCore

/// Превращает APIEndpoint + NetworkConfiguration → URLRequest.
/// Per-endpoint headers побеждают глобальные/динамические (последние ставятся в HeadersInterceptor).
enum URLRequestBuilder {

    static func build(_ endpoint: APIEndpoint,
                      configuration: NetworkConfiguration,
                      encoder: JSONEncoder) throws -> (request: URLRequest, multipart: [MultipartPart]?) {

        // 1. URL + query
        let base = configuration.baseURL.appendingPathComponent(endpoint.path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if let query = endpoint.query, !query.isEmpty {
            let existing = components?.queryItems ?? []
            components?.queryItems = existing + query
        }
        guard let url = components?.url else {
            throw APIError.transport(URLError(.badURL))
        }

        // 2. Метод и timeout
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        if let timeout = endpoint.timeout { request.timeoutInterval = timeout }

        // 3. Per-endpoint headers (глобальные ставит HeadersInterceptor.adapt позже)
        if let headers = endpoint.headers {
            for (name, value) in headers.dictionary {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        // 4. Body
        var multipart: [MultipartPart]?
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
                throw APIError.encoding(SendableErrorBox(error))
            }

        case .urlEncoded(let dict):
            request.httpBody = FormURLEncoding.encode(dict)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                                 forHTTPHeaderField: "Content-Type")
            }

        case .multipart(let parts):
            // Транспорт сам построит multipart body — отдадим parts наружу.
            multipart = parts

        case .raw(let data, let contentType):
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        return (request, multipart)
    }
}

/// Стирает existential `any Encodable & Sendable` для JSONEncoder.
private struct AnyEncodable: Encodable {
    let value: any Encodable & Sendable
    init(_ value: any Encodable & Sendable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
