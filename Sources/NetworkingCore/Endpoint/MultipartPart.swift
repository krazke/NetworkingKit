import Foundation

/// Описание одной части multipart/form-data запроса. Транспорт (AF/URLSession)
/// собирает реальный body — здесь только данные.
public struct MultipartPart: Sendable {
    public enum Source: Sendable {
        case data(Data)
        case fileURL(URL)
    }

    public let name: String
    public let filename: String?
    public let mimeType: String?
    public let source: Source

    public init(name: String,
                filename: String? = nil,
                mimeType: String? = nil,
                source: Source) {
        self.name = name
        self.filename = filename
        self.mimeType = mimeType
        self.source = source
    }

    public static func data(_ data: Data,
                            name: String,
                            filename: String? = nil,
                            mimeType: String? = nil) -> MultipartPart {
        .init(name: name, filename: filename, mimeType: mimeType, source: .data(data))
    }

    public static func file(_ url: URL,
                            name: String,
                            filename: String? = nil,
                            mimeType: String? = nil) -> MultipartPart {
        .init(name: name,
              filename: filename ?? url.lastPathComponent,
              mimeType: mimeType,
              source: .fileURL(url))
    }
}
