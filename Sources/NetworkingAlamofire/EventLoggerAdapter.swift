import Foundation
import Alamofire
import NetworkingCore

/// Мост между Alamofire.EventMonitor и NetworkingCore.NetworkLogger.
final class EventLoggerAdapter: EventMonitor {
    let queue = DispatchQueue(label: "networkingkit.eventlogger")
    private let logger: any NetworkLogger

    init(logger: any NetworkLogger) { self.logger = logger }

    func requestDidResume(_ request: Alamofire.Request) {
        guard let req = request.request else { return }
        logger.willSend(req)
    }

    func request<Value>(_ request: DataRequest,
                        didParseResponse response: DataResponse<Value, AFError>) {
        guard let req = response.request else { return }
        let duration = response.metrics?.taskInterval.duration ?? 0
        let data = response.data
        logger.didReceive(req,
                          response: response.response,
                          data: data,
                          duration: duration)
    }

    func request(_ request: Alamofire.Request, didFailTask task: URLSessionTask, earlyWithError error: AFError) {
        guard let req = request.request else { return }
        logger.didFail(req, error: NonSendableErrorBox(error))
    }
}
