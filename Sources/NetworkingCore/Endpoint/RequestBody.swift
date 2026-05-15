import Foundation

/// Тело запроса. Транспорт сам решает, как это сериализовать.
public enum RequestBody: Sendable {
    case empty
    case json(any Encodable & Sendable)
    case urlEncoded([String: String])
    case multipart([MultipartPart])
    case raw(Data, contentType: String)
}
