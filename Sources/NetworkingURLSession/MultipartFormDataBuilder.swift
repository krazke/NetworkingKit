import Foundation
import NetworkingCore

/// Ручная сборка multipart/form-data. Альтернатива Alamofire's MultipartFormData.
/// Для больших файлов читает с диска чанками, не загружая всё в память.
struct MultipartFormDataBuilder {
    let boundary: String
    private let lineBreak = "\r\n"

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Writes the encoded body to `url` and returns its size in bytes.
    ///
    /// - Throws: The Foundation error that stopped the write. A `.file` part whose file does not exist
    ///   gives `CocoaError.fileReadNoSuchFile`, as Alamofire's `MultipartFormData` reports it.
    ///   A partially written file may be left at `url`.
    func writeBody(parts: [MultipartPart], to url: URL) throws -> Int64 {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var total: Int64 = 0
        for part in parts {
            let header = headerData(for: part)
            try handle.write(contentsOf: header)
            total += Int64(header.count)

            switch part.source {
            case .data(let data):
                try handle.write(contentsOf: data)
                total += Int64(data.count)
            case .fileURL(let fileURL):
                // Throws `.fileReadNoSuchFile` for a missing file; `FileHandle` would throw `.fileNoSuchFile`.
                _ = try fileURL.checkResourceIsReachable()
                let read = try FileHandle(forReadingFrom: fileURL)
                defer { try? read.close() }
                while let chunk = try read.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                    total += Int64(chunk.count)
                }
            }

            try handle.write(contentsOf: Data(lineBreak.utf8))
            total += Int64(lineBreak.utf8.count)
        }

        let closing = "--\(boundary)--\(lineBreak)"
        try handle.write(contentsOf: Data(closing.utf8))
        total += Int64(closing.utf8.count)
        return total
    }

    private func headerData(for part: MultipartPart) -> Data {
        var s = "--\(boundary)\(lineBreak)"
        s += "Content-Disposition: form-data; name=\"\(MultipartDisposition.escapeName(part.name))\""
        if let filename = part.filename {
            s += "; filename=\"\(MultipartDisposition.escapeFilename(filename))\""
        }
        s += lineBreak
        if let mime = part.mimeType {
            s += "Content-Type: \(mime)\(lineBreak)"
        }
        s += lineBreak
        return Data(s.utf8)
    }
}
