# NetworkingKit

Переиспользуемый Swift Package для сетевого слоя iOS-приложений.
Транспорт-агностичные абстракции в `NetworkingCore` + сменные реализации (`Alamofire` / `URLSession`) + WebSocket-клиент + утилиты для тестов.

```
┌─────────────────────────────────────────────────────────────┐
│ Application (HorseCare, etc.)                               │
│   Domain  ──▶  Services  ──▶  APIClientProtocol             │  ← зависит ТОЛЬКО от NetworkingCore
└──────────────────────┬──────────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┬──────────────────┐
        ▼                             ▼                  ▼
 NetworkingAlamofire           NetworkingURLSession    NetworkingWebSocket
        │                             │
        └──────────────┬──────────────┘
                       ▼
                NetworkingCore
        (Endpoint, RequestBody, APIClientProtocol,
         Interceptors, RetryConfig, PinningPolicy,
         TokenStore, NetworkLogger, NetworkConfiguration)
```

---

## Статус

- ✅ **Фаза 1** — Core skeleton (типы, протоколы, дефолтные интерсепторы)
- ✅ **Фаза 2** — `NetworkingURLSession` (полная реализация без сторонних зависимостей)
- ✅ **Фаза 3** — `NetworkingAlamofire` (адаптер поверх Alamofire 5.11+)
- ✅ **Фаза 4** — `NetworkingWebSocket` (generic WS-клиент с heartbeat и reconnect-with-jitter)
- ✅ **Фаза 5** — `NetworkingTesting` (`MockAPIClient`, `StubResponse`, `RecordingInterceptor`, `MockTokenStore`)
- ✅ **Фаза 6** — Тесты (34/34 green)
- ✅ **Фаза 7** — Документация и пример HorseCare-style

## Параметры

- `swift-tools-version: 6.0`
- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1
- Strict Concurrency `.v6` для всех таргетов кроме `NetworkingAlamofire` (`.v5` — ждём завершения Sendable-миграции AF)

## Таргеты

| Library | Зависимости | Назначение |
|---|---|---|
| `NetworkingCore` | — | Абстракции, конфиг, дефолтные интерсепторы |
| `NetworkingAlamofire` | `Core`, `Alamofire 5.11+` | Production-транспорт |
| `NetworkingURLSession` | `Core` | Альтернативный транспорт без сторонних зависимостей |
| `NetworkingWebSocket` | `Core` | Generic WS-клиент с heartbeat и reconnect |
| `NetworkingTesting` | `Core` | `MockAPIClient`, `StubResponse`, `RecordingInterceptor`, `MockTokenStore` |

---

## Подключение через SPM

В `Package.swift` потребителя:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/NetworkingKit.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "Domain",
        dependencies: [
            .product(name: "NetworkingCore", package: "NetworkingKit"),
        ]
    ),
    .target(
        name: "App",
        dependencies: [
            "Domain",
            .product(name: "NetworkingAlamofire", package: "NetworkingKit"),
            .product(name: "NetworkingWebSocket", package: "NetworkingKit"),
        ]
    ),
    .testTarget(
        name: "DomainTests",
        dependencies: [
            "Domain",
            .product(name: "NetworkingTesting", package: "NetworkingKit"),
        ]
    ),
]
```

В Xcode SPM-проекте — `File → Add Package Dependencies…`, выбрать нужные library-продукты в нужные таргеты.

---

## Минимальный пример

### 1. Эндпоинты

```swift
import NetworkingCore

enum HorsesEndpoints {

    struct List: APIEndpoint {
        let page: Int
        let pageSize: Int
        var path: String { "horses" }
        var method: HTTPMethod { .get }
        var query: [URLQueryItem]? {
            [.init(name: "page", value: "\(page)"),
             .init(name: "page_size", value: "\(pageSize)")]
        }
    }

    struct Get: APIEndpoint {
        let id: Int
        var path: String { "horses/\(id)" }
        var method: HTTPMethod { .get }
    }

    struct Create: APIEndpoint {
        let body: HorseCreateRequest
        let idempotencyKey: String
        var path: String { "horses" }
        var method: HTTPMethod { .post }
        var headers: HTTPHeaders? { ["Idempotency-Key": idempotencyKey] }
        var bodyContent: RequestBody { .json(body) }
        var body: RequestBody { bodyContent }
    }

    struct UploadAvatar: APIEndpoint {
        let id: Int
        let imageData: Data
        var path: String { "horses/\(id)/avatar" }
        var method: HTTPMethod { .post }
        var bodyContent: RequestBody {
            .multipart([.data(imageData,
                              name: "avatar",
                              filename: "avatar.jpg",
                              mimeType: "image/jpeg")])
        }
        var body: RequestBody { bodyContent }
    }
}
```

### 2. Сервис

```swift
import NetworkingCore

protocol HorsesServiceProtocol: Sendable {
    func list(page: Int, pageSize: Int) async throws -> Page<Horse>
    func get(id: Int) async throws -> Horse
    func create(_ body: HorseCreateRequest) async throws -> Horse
    func uploadAvatar(horseId: Int,
                      imageData: Data,
                      progress: ProgressHandler?) async throws -> URL
}

final class HorsesService: HorsesServiceProtocol {
    private let client: any APIClientProtocol
    init(client: any APIClientProtocol) { self.client = client }

    func list(page: Int, pageSize: Int) async throws -> Page<Horse> {
        try await client.send(HorsesEndpoints.List(page: page, pageSize: pageSize),
                              as: Page<Horse>.self)
    }

    func get(id: Int) async throws -> Horse {
        try await client.send(HorsesEndpoints.Get(id: id), as: Horse.self)
    }

    func create(_ body: HorseCreateRequest) async throws -> Horse {
        try await client.send(
            HorsesEndpoints.Create(body: body, idempotencyKey: UUID().uuidString),
            as: Horse.self
        )
    }

    func uploadAvatar(horseId: Int,
                      imageData: Data,
                      progress: ProgressHandler?) async throws -> URL {
        let response = try await client.upload(
            HorsesEndpoints.UploadAvatar(id: horseId, imageData: imageData),
            as: UploadResponse.self,
            progress: progress
        )
        return response.url
    }
}
```

### 3. Composition root

```swift
import NetworkingCore
import NetworkingAlamofire

let configuration = NetworkConfiguration(
    baseURL: URL(string: "https://api.horsecare.app/v1")!,
    globalHeaders: [
        "X-App-Platform": "ios",
        "X-App-Build": Bundle.main.shortVersion
    ],
    dynamicHeaders: {
        ["X-Locale": Locale.current.identifier,
         "X-Timezone": TimeZone.current.identifier]
    },
    pinning: [
        "api.horsecare.app": .publicKeys(loadPinnedKeys())
    ],
    retry: RetryConfiguration(limit: 3, baseDelay: 0.5, maxDelay: 30),
    tokenStore: KeychainTokenStore(),
    refreshAction: { current in
        try await refreshOAuth(refreshToken: current.refreshToken)
    },
    logger: ConsoleNetworkLogger()
)

let client: any APIClientProtocol = AlamofireAPIClient(configuration: configuration)
let horses = HorsesService(client: client)
```

---

## Три уровня заголовков

| Уровень | Где задаётся | Когда применять |
|---|---|---|
| **1. Session (глобальные)** | `NetworkConfiguration.globalHeaders` | Не меняется в рантайме: `X-App-Platform`, `X-App-Build`, `User-Agent` |
| **2. Interceptor (динамические)** | `NetworkConfiguration.dynamicHeaders` или кастомный `RequestInterceptor` | Меняется без рестарта: `X-Locale`, `X-Timezone`, `X-Device-ID`, `Authorization` |
| **3. Endpoint (per-request)** | `var headers: HTTPHeaders?` в эндпоинте | Конкретный запрос: `If-None-Match`, `Idempotency-Key`, локальный `Accept-Language` override |

**Приоритет:** Endpoint > Dynamic > Global. `HeadersInterceptor` ставит global+dynamic только если поле не задано на уровне эндпоинта.

---

## Auth + Retry + Pinning

### OAuth refresh-on-401

`AuthInterceptor` встроен в Core; включается, если в конфиге передан `refreshAction`. Дедупликация параллельных 401-refresh-вызовов решена через actor-state.

```swift
NetworkConfiguration(
    ...
    tokenStore: KeychainTokenStore(),
    refreshAction: { current in
        let response = try await session.send(
            RefreshEndpoint(refreshToken: current.refreshToken),
            as: AuthTokens.self
        )
        return response
    }
)
```

### Retry с exponential backoff + jitter

```swift
RetryConfiguration(
    limit: 3,
    baseDelay: 0.5,
    maxDelay: 30,
    jitter: 0.8...1.2,                     // защита от thundering herd
    retryableMethods: [.get, .head, .put, .delete],
    retryableStatusCodes: [408, 425, 429, 500, 502, 503, 504]
)
```

### SSL Pinning

```swift
NetworkConfiguration(
    ...
    pinning: [
        "api.horsecare.app": .publicKeys([cert1DER, cert2DER]),
        "stream.horsecare.app": .certificates([streamCertDER])
    ]
)
```

`NetworkingAlamofire` использует `ServerTrustManager` + `PinnedCertificatesTrustEvaluator/PublicKeysTrustEvaluator`.
`NetworkingURLSession` — `URLSessionDelegate.didReceive(challenge:)` с `SecCertificateCopyKey`.

---

## Multipart upload

`RequestBody.multipart([MultipartPart])` — каждый `MultipartPart` имеет `.data(Data)` или `.fileURL(URL)` (стрим с диска для больших файлов).

```swift
struct UploadDataFile: APIEndpoint {
    let fileURL: URL
    let horseId: Int
    var path: String { "files" }
    var method: HTTPMethod { .post }
    var bodyContent: RequestBody {
        .multipart([
            .file(fileURL, name: "file"),
            .data(Data("\(horseId)".utf8), name: "horse_id")
        ])
    }
    var body: RequestBody { bodyContent }
}

let result = try await client.upload(
    UploadDataFile(fileURL: localFile, horseId: 42),
    as: UploadResponse.self,
    progress: { fraction in print("⬆︎ \(Int(fraction * 100))%") }
)
```

В `NetworkingURLSession` body пишется во временный файл и грузится через `session.upload(for:fromFile:)` — нет out-of-memory на больших файлах. В `NetworkingAlamofire` — `MultipartFormData.append(URL,...)`.

---

## Streamed download

```swift
let savedURL = try await client.download(
    DownloadFile(fileId: file.id),
    to: .documents(subpath: "downloads/\(file.filename)"),
    progress: { fraction in print("⬇︎ \(Int(fraction * 100))%") }
)
```

`DownloadDestination` имеет три варианта: `.fileURL(URL, removeIfExists)`, `.documents(subpath:)`, `.temporary(filename:)`.

---

## WebSocket — real-time с auto-reconnect

```swift
import NetworkingWebSocket

struct SensorReading: Codable, Sendable {
    let sensorId: String
    let heartRate: Int
    let temperature: Double
    let timestamp: Date
}

let ws = WebSocketClient<SensorReading>(
    configuration: WebSocketConfiguration(
        url: URL(string: "wss://stream.horsecare.app/v1/sensors")!,
        pingInterval: 30,
        reconnect: .exponential(baseDelay: 1, maxDelay: 30, maxAttempts: .max),
        tokenStore: appKeychain
    )
)

Task {
    for await event in await ws.events() {
        switch event {
        case .connected:
            try? await ws.send(SubscribeCmd(action: "subscribe", horseId: 42))
        case .message(let reading):
            print("❤︎ \(reading.heartRate) bpm  🌡 \(reading.temperature)°C")
        case .raw(let data):
            print("• \(data.count) bytes")
        case .disconnected(reason: .reconnecting(let attempt, let delay)):
            print("🔌 reconnect attempt \(attempt) in \(delay)s")
        case .disconnected(reason: .givenUp):
            print("✗ given up")
        case .disconnected(reason: .clientInitiated):
            print("🔌 closed")
        case .disconnected(reason: .closedByPeer(let code, _)):
            print("🔌 peer closed: \(code)")
        case .disconnected(reason: .error(let err)):
            print("✗ \(err)")
        }
    }
}
```

---

## Тестирование

В тестовом таргете подключи `NetworkingTesting` и используй `MockAPIClient`:

```swift
import XCTest
import NetworkingCore
import NetworkingTesting
@testable import Domain

final class HorsesServiceTests: XCTestCase {
    func test_list_returnsHorses() async throws {
        let client = MockAPIClient()
        await client.stub(
            path: "horses",
            with: .success(Page<Horse>(items: [.mock(id: 1)],
                                       total: 1, page: 1, pageSize: 20))
        )

        let service = HorsesService(client: client)
        let page = try await service.list(page: 1, pageSize: 20)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.id, 1)

        let calls = await client.calls(for: "horses")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.method, .get)
    }

    func test_create_throwsServerError() async {
        let client = MockAPIClient()
        await client.stub(path: "horses", with: .failure(.notFound))
        let service = HorsesService(client: client)
        do {
            _ = try await service.create(.mock)
            XCTFail("Expected error")
        } catch APIError.notFound {
            // ok
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }
}
```

Дополнительные утилиты Testing:
- `MockTokenStore` с counter'ами `saveCount`/`clearCount`
- `RecordingInterceptor` — фиксирует все adapt/retry-вызовы в actor-state

---

## Миграция с Moya

| HorseCare (Moya) | NetworkingKit |
|---|---|
| `TargetType` enum case | отдельный struct, реализующий `APIEndpoint` |
| `MoyaProvider<API>` | `AlamofireAPIClient(configuration:)` или `URLSessionAPIClient(configuration:)` |
| `TokenPlugin` | `AuthInterceptor` (встроен, конфиг через `refreshAction`) |
| `NetworkLoggerPlugin` | `NetworkLogger` protocol + `ConsoleNetworkLogger` (или `EventLoggerAdapter` для Pulse) |
| `MultipartRequest` proto | `RequestBody.multipart([MultipartPart])` |
| `BackgroundPlugin` | `NetworkConfiguration.sessionConfiguration = .background(...)` |
| `ServiceErrorHandler` | единый `APIError` enum с типизированными вариантами |
| `provider.request(.case)` | `client.send(MyEndpoint(), as: T.self)` |
| `provider.stubbingEndpointsClosure` | `MockAPIClient.stub(path:with:)` |

**Пошаговая стратегия миграции (для проекта уровня HorseCare с 13 модулями таргетов и 26 файлами Moya):**

1. **Шаг 0** — добавь NetworkingKit в `Package.swift` приложения, не убирая Moya. Они уживаются параллельно.
2. **Шаг 1** — оставь `NetworkingService` фасад в HorseCare как есть (UI/ViewModels через него работают). Внутри начни поэтапно подменять `MoyaProvider` на `AlamofireAPIClient` для одного таргета (например, `Common`). Остальные таргеты — продолжают через Moya.
3. **Шаг 2** — переведи `TokenPlugin` на `AuthInterceptor` через `NetworkConfiguration.refreshAction` — самый чистый выигрыш.
4. **Шаг 3** — `NetworkLoggerPlugin` → `EventLoggerAdapter(logger: PulseLogger())` для Pulse, или `ConsoleNetworkLogger()` для разработки.
5. **Шаги 4..N** — мигрируй таргеты по одному. UI/ViewModels не трогаем — фасад защищает.
6. **Финал** — удали Moya из зависимостей.

---

## Известные ограничения

- `NetworkingAlamofire` под `.v5` language mode (Sendable-миграция AF 5.11 не закончена) — нужно `@unchecked Sendable` локально в bridge'ах. На public-API не утекает.
- `JSONDecoder`/`JSONEncoder` сами по себе non-Sendable — в `NetworkConfiguration` хранятся как `@Sendable () -> JSONDecoder` фабрики.
- Background sessions поддерживаются через `sessionConfiguration: .background(withIdentifier:)`, но требуют app-delegate hook'а (`handleEventsForBackgroundURLSession`) на стороне приложения.
- Reachability мониторинг (`NWPathMonitor`) — за рамками пакета (две строки в композиции потребителя).
- GraphQL — за рамками пакета (используй Apollo iOS 2.x напрямую).
- DocC catalog отложен до v1.1.

## Лицензия

MIT (предполагаемая — добавить `LICENSE` файл).
