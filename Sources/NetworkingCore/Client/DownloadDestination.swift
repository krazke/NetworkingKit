import Foundation

/// Where `download` stores the downloaded file.
///
/// Both transports place the file the same way:
/// - The file is moved to the destination only after a 2xx response has been downloaded completely.
///   If the request fails, including a non-2xx status, the destination is left untouched.
/// - If a file already exists at the destination, it is replaced, except for
///   `.fileURL(_, removeIfExists: false)`, which fails and keeps the existing file.
/// - An existing directory at the destination is never replaced.
/// - Missing intermediate directories are created.
/// - When the file cannot be placed, `download` throws `APIError.transport` wrapping a `CocoaError`;
///   an existing file or directory gives the code `.fileWriteFileExists`. The downloaded data is discarded.
public enum DownloadDestination: Sendable {
    /// An explicit file URL. With `removeIfExists: false`, an existing file makes the download fail.
    case fileURL(URL, removeIfExists: Bool = true)
    /// `subpath` relative to the user's Documents directory. Replaces an existing file.
    case documents(subpath: String)
    /// `filename` in `FileManager.temporaryDirectory`, for ephemeral downloads. Replaces an existing file.
    case temporary(filename: String)

    /// Resolves the destination URL and creates missing intermediate directories.
    ///
    /// For `.fileURL(_, removeIfExists: true)` it also removes an existing file right away. The transports
    /// do not call it, so that a failed download keeps the existing file.
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

// MARK: - Transport support

extension DownloadDestination {
    /// The destination URL, without touching the file system.
    ///
    /// - Throws: `APIError.transport` wrapping the `CocoaError` when the Documents directory cannot be located.
    package func targetURL(fileManager: FileManager = .default) throws -> URL {
        switch self {
        case .fileURL(let url, _):
            return url
        case .documents(let subpath):
            let docs = try placing {
                try fileManager.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: false)
            }
            return docs.appendingPathComponent(subpath)
        case .temporary(let filename):
            return fileManager.temporaryDirectory.appendingPathComponent(filename)
        }
    }

    /// Moves a completely downloaded file from `location` to `target` (from `targetURL`), following the
    /// rules in the type's documentation. Call it only after the response has been validated.
    ///
    /// - Throws: `APIError.transport` wrapping a `CocoaError`. `location` is left in place on failure;
    ///   the caller owns it.
    package func moveDownloadedFile(at location: URL,
                                    to target: URL,
                                    fileManager: FileManager = .default) throws {
        try placing {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                guard replacesExistingFile, !isDirectory.boolValue else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
                }
                try fileManager.removeItem(at: target)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
            }
            try fileManager.moveItem(at: location, to: target)
        }
    }

    private var replacesExistingFile: Bool {
        if case .fileURL(_, let removeIfExists) = self { return removeIfExists }
        return true
    }

    private func placing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CocoaError {
            throw APIError.transport(error)
        } catch {
            throw APIError.transport(CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: error]))
        }
    }
}
