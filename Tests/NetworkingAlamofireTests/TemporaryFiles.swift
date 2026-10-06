import Foundation

/// Files that the transport leaves in the temporary directory, for leak checks.
/// Compare a snapshot taken before a request with one taken after it.
enum TemporaryFiles {
    /// Multipart bodies that Alamofire encodes to disk, which it does only above
    /// `MultipartFormData.encodingMemoryThreshold` (10 MB); smaller bodies stay in memory.
    static func multipartBodies() throws -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("org.alamofire.manager/multipart.form.data")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try names(in: directory) { _ in true }
    }

    /// Downloaded files that were never placed at a destination. Without a `to:` destination, Alamofire moves
    /// URLSession's `CFNetworkDownload_*.tmp` to `Alamofire_CFNetworkDownload_*.tmp` in the same directory.
    static func downloads() throws -> Set<String> {
        try names(in: FileManager.default.temporaryDirectory) { $0.contains("CFNetworkDownload_") }
    }

    private static func names(in directory: URL, where include: (String) -> Bool) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(include))
    }
}
