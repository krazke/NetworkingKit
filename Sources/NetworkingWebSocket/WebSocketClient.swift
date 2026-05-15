import Foundation
import NetworkingCore

/// Generic WebSocket-клиент поверх URLSessionWebSocketTask.
///
/// Возможности:
/// - Авторизация через TokenStore (Bearer header) + статические/динамические headers
/// - Heartbeat (ping) для удержания соединения через прокси/балансеры
/// - Авто-reconnect через ReconnectPolicy с jitter
/// - Стрим событий через AsyncStream<WebSocketEvent<Message>>
/// - Типизированный JSON-декодинг входящих сообщений; raw Data наружу как fallback
/// - Корректная отмена через Task cancellation и onTermination
public actor WebSocketClient<Message: Decodable & Sendable> {

    public enum State: Sendable {
        case idle, connecting, connected, disconnected
    }

    private let configuration: WebSocketConfiguration
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<WebSocketEvent<Message>>.Continuation?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var attempt = 0
    public private(set) var state: State = .idle

    public init(configuration: WebSocketConfiguration) {
        self.configuration = configuration
        self.session = URLSession(configuration: configuration.sessionConfiguration)
    }

    // MARK: - Public API

    /// Открывает соединение и возвращает поток событий.
    /// На каждый вызов создаётся новый стрим — обычно вызывается один раз.
    public func events() -> AsyncStream<WebSocketEvent<Message>> {
        AsyncStream<WebSocketEvent<Message>> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect(initiatedByClient: true) }
            }
            Task { await self.connect() }
        }
    }

    /// Отправка типизированного сообщения (Encodable & Sendable).
    public func send<T: Encodable & Sendable>(_ message: T) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let encoder = configuration.encoderFactory()
        let data = try encoder.encode(message)
        guard let str = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        try await task.send(.string(str))
    }

    /// Отправка сырых данных.
    public func sendRaw(_ data: Data) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.data(data))
    }

    /// Отправка сырой строки.
    public func sendString(_ string: String) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.string(string))
    }

    /// Закрытие соединения. После вызова стрим завершается.
    public func disconnect() async {
        await disconnect(initiatedByClient: true)
    }

    // MARK: - Lifecycle

    private func connect() async {
        state = .connecting

        var request = URLRequest(url: configuration.url)
        if let store = configuration.tokenStore, let tokens = await store.current() {
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let combinedHeaders = configuration.headers.merging(configuration.dynamicHeaders()) { _, new in new }
        for (name, value) in combinedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        state = .connected
        attempt = 0
        continuation?.yield(.connected)

        startReceiveLoop()
        startHeartbeat()
    }

    private func disconnect(initiatedByClient: Bool) async {
        receiveLoop?.cancel(); receiveLoop = nil
        heartbeat?.cancel(); heartbeat = nil

        if let task {
            task.cancel(with: initiatedByClient ? .normalClosure : .abnormalClosure, reason: nil)
        }
        self.task = nil

        state = .disconnected
        if initiatedByClient {
            continuation?.yield(.disconnected(reason: .clientInitiated))
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - Receive

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            while let self, await self.shouldKeepReceiving() {
                await self.receiveOne()
            }
        }
    }

    private func shouldKeepReceiving() async -> Bool {
        !Task.isCancelled && task != nil
    }

    private func receiveOne() async {
        guard let task else { return }
        do {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                handleText(text)
            case .data(let data):
                handleData(data)
            @unknown default:
                continuation?.yield(.raw(Data()))
            }
        } catch {
            await handleFailure(error)
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            continuation?.yield(.raw(Data(text.utf8))); return
        }
        handleData(data)
    }

    private func handleData(_ data: Data) {
        let decoder = configuration.decoderFactory()
        if let message = try? decoder.decode(Message.self, from: data) {
            continuation?.yield(.message(message))
        } else {
            continuation?.yield(.raw(data))
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let interval = configuration.pingInterval
        guard interval > 0 else { return }
        heartbeat = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self.ping()
            }
        }
    }

    private func ping() async {
        guard let task else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.sendPing { [weak self] error in
                if let error {
                    Task { await self?.handleFailure(error) }
                }
                cont.resume()
            }
        }
    }

    // MARK: - Failure / Reconnect

    private func handleFailure(_ error: any Error) async {
        guard state == .connected || state == .connecting else { return }
        state = .disconnected
        let sendable: any Error & Sendable = SendableErrorBox(error)

        receiveLoop?.cancel(); receiveLoop = nil
        heartbeat?.cancel(); heartbeat = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil

        attempt += 1
        if let delay = configuration.reconnect.delay(for: attempt) {
            continuation?.yield(.disconnected(reason: .reconnecting(attempt: attempt, delay: delay)))
            try? await Task.sleep(for: .seconds(delay))
            guard continuation != nil else { return }
            await connect()
        } else {
            continuation?.yield(.disconnected(reason: .error(sendable)))
            continuation?.yield(.disconnected(reason: .givenUp))
            continuation?.finish()
            continuation = nil
        }
    }
}

private struct SendableErrorBox: Error, @unchecked Sendable {
    let underlying: any Error
    init(_ underlying: any Error) { self.underlying = underlying }
    var localizedDescription: String { underlying.localizedDescription }
}
