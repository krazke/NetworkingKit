import Foundation
import NetworkingCore

/// URLSessionTaskDelegate, прокидывающий прогресс в ProgressHandler.
final class ProgressObserver: NSObject,
                              URLSessionTaskDelegate,
                              URLSessionDataDelegate,
                              URLSessionDownloadDelegate,
                              @unchecked Sendable {
    private let handler: ProgressHandler?

    init(handler: ProgressHandler?) { self.handler = handler }

    // Upload
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0, let handler else { return }
        handler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    // Download
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let handler else { return }
        handler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Async URLSession.download(...) уже сам обрабатывает финализацию.
    }
}
