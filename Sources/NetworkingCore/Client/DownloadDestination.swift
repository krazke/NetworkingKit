import Foundation

/// Куда писать загружаемый файл. Опции выбраны под типичные iOS-паттерны.
public enum DownloadDestination: Sendable {
    /// Конкретный URL — транспорт перезаписывает существующий файл.
    case fileURL(URL, removeIfExists: Bool = true)
    /// В Documents/<subpath>, где subpath — относительный путь от Documents/.
    case documents(subpath: String)
    /// Во временную папку (caches), для эфемерных скачиваний.
    case temporary(filename: String)

    /// Резолвит финальный URL, создавая промежуточные директории.
    public func resolve(fileManager: FileManager = .default) throws -> URL {
        switch self {
        case .fileURL(let url, let removeIfExists):
            if removeIfExists, fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            return url

        case .documents(let subpath):
            let docs = try fileManager.url(for: .documentDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
            let target = docs.appendingPathComponent(subpath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            return target

        case .temporary(let filename):
            return fileManager.temporaryDirectory.appendingPathComponent(filename)
        }
    }
}
