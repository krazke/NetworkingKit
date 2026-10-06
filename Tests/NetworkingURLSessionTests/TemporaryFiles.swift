import Foundation

/// Files that the transport leaves in the temporary directory, for leak checks.
/// Compare a snapshot taken before a request with one taken after it.
enum TemporaryFiles {
    /// Multipart bodies written by `URLSessionAPIClient.upload` (`<UUID>.multipart`).
    static func multipartBodies() throws -> Set<String> {
        try names(in: FileManager.default.temporaryDirectory) { $0.hasSuffix(".multipart") }
    }

    /// Downloaded files that were never placed at a destination (`CFNetworkDownload_*.tmp`).
    static func downloads() throws -> Set<String> {
        try names(in: FileManager.default.temporaryDirectory) { $0.contains("CFNetworkDownload_") }
    }

    private static func names(in directory: URL, where include: (String) -> Bool) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(include))
    }
}
