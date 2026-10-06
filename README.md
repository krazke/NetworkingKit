# NetworkingKit

A reusable Swift package for the networking layer of iOS apps. `NetworkingCore` holds transport-agnostic abstractions; `NetworkingAlamofire` and `NetworkingURLSession` are interchangeable transports; `NetworkingWebSocket` is a generic WebSocket client; `NetworkingTesting` provides test doubles.

> **Status: prototype.** The design is stable and the test suite passes, but several defects in auth refresh, pinning, downloads and WebSocket reconnect make it unsuitable for production as-is. See [Status & known issues](#status--known-issues).

```
┌─────────────────────────────────────────────────────────────┐
│ Application (e.g. HorseCare)                                │
│   Domain  ──▶  Services  ──▶  APIClientProtocol             │  ← depends on NetworkingCore only
└──────────────────────┬──────────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┬──────────────────┐
        ▼                             ▼                  ▼
 NetworkingAlamofire           NetworkingURLSession    NetworkingWebSocket
        │                             │
        └──────────────┬──────────────┘
                       ▼
                NetworkingCore
        (APIEndpoint, RequestBody, APIClientProtocol,
         interceptors, RetryConfiguration, PinningPolicy,
         TokenStore, NetworkLogger, NetworkConfiguration)
```

## Requirements

- `swift-tools-version: 6.0`
- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / visionOS 1
- Swift 6 language mode for every target except `NetworkingAlamofire`, which builds in Swift 5 mode and bridges Alamofire callbacks through `@unchecked Sendable` boxes.
- Alamofire `from: "5.11.0"` (resolved: 5.11.2).

## Products

| Library | Depends on | Purpose |
|---|---|---|
| `NetworkingCore` | — | Endpoint/body model, `APIClientProtocol`, configuration, default interceptors, errors |
| `NetworkingAlamofire` | Core, Alamofire | `AlamofireAPIClient` transport |
| `NetworkingURLSession` | Core | `URLSessionAPIClient` transport with no third-party dependencies |
| `NetworkingWebSocket` | Core | `WebSocketClient<Message>` with heartbeat and reconnect policy |
| `NetworkingTesting` | Core | `MockAPIClient`, `StubResponse`, `RecordingInterceptor`, `MockTokenStore` |

## Building and testing

```sh
swift build
swift test
```

The suite contains 34 XCTest cases (Core 20, URLSession 6, WebSocket 5, Alamofire 3). All 34 passed on 2026-10-06 with Xcode 27.0 / Swift 6.4.

## Adding the package

In the consumer's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/NetworkingKit.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "Domain",
        dependencies: [.product(name: "NetworkingCore", package: "NetworkingKit")]
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

The package is not published; the URL above is a placeholder. In Xcode, use **File → Add Package Dependencies…** and attach each library product to the target that needs it.

## Usage

The examples below use the real public API of this package. Types such as `Horse`, `Page`, `HorseCreateRequest`, `UploadResponse`, `KeychainTokenStore` and `loadPinnedKeyCertificates()` belong to the consuming app.

### Endpoints

Each request is a type conforming to `APIEndpoint`. Only `path` and `method` are required; `query`, `headers`, `body` and `timeout` have defaults.

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
        let payload: HorseCreateRequest   // must be Encodable & Sendable
        let idempotencyKey: String
        var path: String { "horses" }
        var method: HTTPMethod { .post }
        var headers: HTTPHeaders? { ["Idempotency-Key": idempotencyKey] }
        var body: RequestBody { .json(payload) }
    }

    struct UploadAvatar: APIEndpoint {
        let id: Int
        let imageData: Data
        var path: String { "horses/\(id)/avatar" }
        var method: HTTPMethod { .post }
        var body: RequestBody {
            .multipart([.data(imageData, name: "avatar",
                              filename: "avatar.jpg", mimeType: "image/jpeg")])
        }
    }
}
```

`path` is appended with `URL.appendingPathComponent`, so it must not contain a query string; use `query` instead.

`NetworkingCore.HTTPHeaders` has the same name as `Alamofire.HTTPHeaders`. In a file that imports both modules, qualify it as `NetworkingCore.HTTPHeaders`.

### Service

```swift
import NetworkingCore

final class HorsesService: Sendable {
    private let client: any APIClientProtocol
    init(client: any APIClientProtocol) { self.client = client }

    func list(page: Int, pageSize: Int) async throws -> Page<Horse> {
        try await client.send(HorsesEndpoints.List(page: page, pageSize: pageSize),
                              as: Page<Horse>.self)
    }

    func create(_ payload: HorseCreateRequest) async throws -> Horse {
        try await client.send(HorsesEndpoints.Create(payload: payload,
                                                     idempotencyKey: UUID().uuidString),
                              as: Horse.self)
    }

    func uploadAvatar(horseId: Int, imageData: Data,
                      progress: ProgressHandler?) async throws -> UploadResponse {
        try await client.upload(HorsesEndpoints.UploadAvatar(id: horseId, imageData: imageData),
                                as: UploadResponse.self,
                                progress: progress)
    }
}
```

### Composition root

```swift
import NetworkingCore
import NetworkingAlamofire

let tokenStore = KeychainTokenStore()   // app-defined, conforms to TokenStore

// A separate client without refreshAction, used only for the refresh call.
let authClient: any APIClientProtocol = AlamofireAPIClient(
    configuration: NetworkConfiguration(baseURL: URL(string: "https://api.horsecare.app/v1")!)
)

let configuration = NetworkConfiguration(
    baseURL: URL(string: "https://api.horsecare.app/v1")!,
    globalHeaders: [
        "X-App-Platform": "ios",
        "X-App-Build": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
    ],
    dynamicHeaders: {
        ["X-Locale": Locale.current.identifier,
         "X-Timezone": TimeZone.current.identifier]
    },
    pinning: ["api.horsecare.app": .publicKeys(loadPinnedKeyCertificates())],
    retry: RetryConfiguration(limit: 3, baseDelay: 0.5, maxDelay: 30),
    tokenStore: tokenStore,
    refreshAction: { current in
        try await authClient.send(RefreshEndpoint(refreshToken: current.refreshToken),
                                  as: AuthTokens.self)
    },
    logger: ConsoleNetworkLogger()
)

let client: any APIClientProtocol = AlamofireAPIClient(configuration: configuration)
// or: URLSessionAPIClient(configuration: configuration)
let horses = HorsesService(client: client)
```

Do not perform the refresh call through the same client that owns the `AuthInterceptor`. That interceptor would attach the expired bearer token to the refresh request, and a 401 on the refresh request would wait on its own in-flight refresh task.

`AuthTokens` is decoded with the configured decoder, which uses `.convertFromSnakeCase`, so a response with `access_token`, `refresh_token` and `expires_at` maps onto it directly.

## Headers

| Level | Where it is set | Typical use |
|---|---|---|
| Global | `NetworkConfiguration.globalHeaders` | Values fixed for the app session: `X-App-Platform`, `X-App-Build`, `User-Agent` |
| Dynamic | `NetworkConfiguration.dynamicHeaders`, or a custom `RequestInterceptor` in `additionalInterceptors` | Values read per request: `X-Locale`, `X-Timezone`, `X-Device-ID` |
| Endpoint | `var headers: HTTPHeaders?` on the endpoint | Request-specific values: `If-None-Match`, `Idempotency-Key` |

Precedence is endpoint > dynamic > global: `HeadersInterceptor` sets a global or dynamic header only when the request does not already have that field. `Authorization` is set by `AuthInterceptor`, which overwrites any existing value.

## Interceptors, auth and retry

Both transports build the same chain from `NetworkConfiguration`: `HeadersInterceptor`, then `AuthInterceptor` (only when `refreshAction` is set), then `additionalInterceptors`, then `RetryInterceptor`. The URLSession transport also inserts `LoggingInterceptor` when a logger is configured; the Alamofire transport logs through an internal `EventMonitor` instead. `CompositeInterceptor` runs `adapt` sequentially, and for `retry` the first decision other than `.doNotRetry` wins.

**Refresh on 401.** `AuthInterceptor` adds `Authorization: Bearer <accessToken>` from the `TokenStore`. On a 401 it calls `refreshAction` once, saves the new tokens and retries the request. It only does this on the first attempt of a request, and concurrent refreshes are not reliably deduplicated (see known issues).

**Retry with backoff.**

```swift
RetryConfiguration(
    limit: 3,                               // total attempts, including the first
    baseDelay: 0.5,
    maxDelay: 30,
    jitter: 0.8...1.2,
    retryableMethods: [.get, .head, .put, .delete],
    retryableStatusCodes: [408, 425, 429, 500, 502, 503, 504]
)
```

Requests with no response (transport errors) and responses with a retryable status are retried for idempotent methods. The delay is `min(maxDelay, baseDelay * 2^(attempt-1))` multiplied by the jitter factor, so it can exceed `maxDelay` by up to the upper jitter bound. The `Retry-After` header is not read.

## SSL pinning

```swift
NetworkConfiguration(
    baseURL: baseURL,
    pinning: [
        "api.horsecare.app": .publicKeys([leafCertDER, backupCertDER]),
        "cdn.horsecare.app": .certificates([cdnCertDER]),
    ]
)
```

`PinningPolicy` takes DER-encoded certificates for both modes; `.publicKeys` extracts the keys from them.

- `NetworkingAlamofire` maps the policies onto `ServerTrustManager` with `PinnedCertificatesTrustEvaluator` / `PublicKeysTrustEvaluator`. Alamofire's evaluators also perform default system validation.
- `NetworkingURLSession` uses an internal `URLSessionDelegate` that compares certificates or keys from the presented chain.

Pinning applies to the HTTP clients only. `WebSocketConfiguration` has no pinning option. Both implementations have behavioral gaps listed under known issues.

## Multipart upload

`RequestBody.multipart([MultipartPart])`. Build parts with `.data(_:name:filename:mimeType:)` or `.file(_:name:filename:mimeType:)`; the latter streams from disk.

```swift
struct UploadDataFile: APIEndpoint {
    let fileURL: URL
    let horseId: Int
    var path: String { "files" }
    var method: HTTPMethod { .post }
    var body: RequestBody {
        .multipart([
            .file(fileURL, name: "file"),
            .data(Data("\(horseId)".utf8), name: "horse_id"),
        ])
    }
}

let result = try await client.upload(
    UploadDataFile(fileURL: localFile, horseId: 42),
    as: UploadResponse.self,
    progress: { fraction in print("upload \(Int(fraction * 100))%") }
)
```

The URLSession transport writes the body to a temporary file and uploads it with `URLSession.upload(for:fromFile:delegate:)`. The Alamofire transport uses `MultipartFormData`.

## Download

```swift
let savedURL = try await client.download(
    DownloadFile(fileId: file.id),
    to: .fileURL(downloadsDirectory.appendingPathComponent("\(file.id).bin")),
    progress: { fraction in print("download \(Int(fraction * 100))%") }
)
```

`DownloadDestination` has three cases: `.fileURL(URL, removeIfExists: Bool = true)`, `.documents(subpath:)` and `.temporary(filename:)`. Only `.fileURL` removes an existing file before writing. Do not build a destination path from a server-provided filename without sanitizing it.

## WebSocket

```swift
import NetworkingWebSocket

struct SensorReading: Decodable, Sendable {
    let sensorId: String
    let heartRate: Int
    let temperature: Double
    let timestamp: Date
}

struct SubscribeCommand: Encodable, Sendable {
    let action: String
    let horseId: Int
}

let ws = WebSocketClient<SensorReading>(
    configuration: WebSocketConfiguration(
        url: URL(string: "wss://stream.horsecare.app/v1/sensors")!,
        pingInterval: 30,
        reconnect: .exponential(baseDelay: 1, maxDelay: 30, maxAttempts: 10),
        tokenStore: tokenStore
    )
)

Task {
    for await event in await ws.events() {
        switch event {
        case .connected:
            try? await ws.send(SubscribeCommand(action: "subscribe", horseId: 42))
        case .message(let reading):
            print("\(reading.heartRate) bpm, \(reading.temperature) °C")
        case .raw(let data):
            print("undecodable frame, \(data.count) bytes")
        case .disconnected(reason: .reconnecting(let attempt, let delay)):
            print("reconnect attempt \(attempt) in \(delay)s")
        case .disconnected(reason: .givenUp):
            print("gave up")
        case .disconnected(reason: .clientInitiated):
            print("closed")
        case .disconnected(reason: .closedByPeer):
            break   // declared but never emitted by the current implementation
        case .disconnected(reason: .error(let error)):
            print("error: \(error)")
        }
    }
}
```

Frames that decode as `Message` arrive as `.message`; everything else arrives as `.raw(Data)`. Call `events()` once per client. Ending the stream (cancelling the consuming task) disconnects the client, and so does `await ws.disconnect()`.

## Testing with `NetworkingTesting`

```swift
import XCTest
import NetworkingCore
import NetworkingTesting
@testable import Domain

final class HorsesServiceTests: XCTestCase {
    func test_list_returnsHorses() async throws {
        let client = MockAPIClient()
        await client.stub(path: "horses",
                          with: .success(Page<Horse>(items: [.mock(id: 1)],
                                                     total: 1, page: 1, pageSize: 20)))

        let page = try await HorsesService(client: client).list(page: 1, pageSize: 20)

        XCTAssertEqual(page.items.map(\.id), [1])
        let calls = await client.calls(for: "horses")
        XCTAssertEqual(calls.map(\.method), [.get])
    }

    func test_create_propagatesNotFound() async {
        let client = MockAPIClient()
        await client.stub(path: "horses", with: .failure(.notFound))
        do {
            _ = try await HorsesService(client: client).create(.mock)
            XCTFail("Expected an error")
        } catch APIError.notFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
```

Stubs are keyed by the exact `endpoint.path` string ("horses", not "/horses"). Unstubbed paths fail with `.notFound` unless `setDefaultStub(_:)` is called. `StubResponse` also offers `.successData(Data)`, `.void` and `.delayed(seconds, inner)`. `MockTokenStore` counts `save` and `clear` calls, and `RecordingInterceptor` records `adapt` and `retry` calls.

## Migrating from Moya

| Moya | NetworkingKit |
|---|---|
| `TargetType` enum case | A struct conforming to `APIEndpoint` |
| `MoyaProvider<API>` | `AlamofireAPIClient(configuration:)` or `URLSessionAPIClient(configuration:)` |
| Token plugin | `AuthInterceptor`, enabled by `NetworkConfiguration.refreshAction` |
| `NetworkLoggerPlugin` | An app-defined `NetworkLogger` passed as `NetworkConfiguration.logger` (`ConsoleNetworkLogger` for development) |
| Multipart target | `RequestBody.multipart([MultipartPart])` |
| Background-transfer plugin | Not supported: Alamofire rejects background session configurations, and `URLSessionAPIClient` uses async APIs that background sessions do not support |
| Error handler | The `APIError` enum |
| `provider.request(.case)` | `client.send(Endpoint(), as: T.self)` |
| Stubbing closures | `MockAPIClient.stub(path:with:)` |

To plug in a logging tool that ships its own Alamofire `EventMonitor`, use `AlamofireAPIClient(configuration:additionalMonitors:)` or `AlamofireAPIClient(session:configuration:)`. The internal bridge from `NetworkLogger` to `EventMonitor` is not public.

An incremental migration keeps Moya and NetworkingKit side by side behind the app's existing networking facade, moves one module at a time to `APIClientProtocol`, replaces the token and logger plugins with `refreshAction` and `logger`, and removes Moya when no module uses it.

## Status & known issues

The package is a prototype. The issues below were confirmed by reading the code; none is covered by a test yet.

**Auth**
- `AuthInterceptor.refreshIfNeeded()` checks `inflight`, then awaits `tokenStore.current()` before assigning `inflight`. Actor reentrancy at that `await` lets two concurrent 401s start two refreshes; with rotating refresh tokens the second one fails.
- Refresh runs only when `attempt == 1`, and the attempt counter is shared with `RetryInterceptor`. A request that gets 503 and then 401 never refreshes.

**URLSession transport**
- Multipart `upload` and `download` run `adapt` once and never consult `retry`, so 401 refresh and retry do not apply to them.
- `download` moves the temporary file with `try? moveItem`. If the target exists (always possible for `.documents` and `.temporary`), the move fails silently and the old file is returned.
- `PinningDelegate` never calls `SecTrustEvaluateWithError`. When a certificate or key matches, expiry, hostname and chain validation are skipped.
- A pin mismatch cancels the challenge, which surfaces as `URLError.cancelled` and is mapped to `APIError.cancelled` instead of a distinct pinning error.

**Alamofire transport**
- `ServerTrustManager(evaluators:)` is created with Alamofire's default `allHostsMustBeEvaluated: true`, so once any host is pinned, requests to every unlisted host fail (including CDN and redirect targets).
- `mapError` always sets `data: nil` in `.server(statusCode:data:message:)`, so the error body is lost. The URLSession transport keeps it.

**Both transports**
- `.urlEncoded` bodies are built with `URLComponents.percentEncodedQuery`, which leaves `+` unescaped; a value `a+b` reaches the server as `a b`.
- The `APIClientProtocol` extension declares `download(_:to:progress:)` with the same signature as the requirement and calls itself. A conformer that omits `download` compiles and then recurses forever.

**WebSocket**
- `connect()` yields `.connected` and resets the attempt counter right after `resume()`, before the handshake completes, so `.connected` can be reported for a socket that never opens.
- When `handleFailure` runs on the receive-loop task, it cancels that task first, so the following `Task.sleep` returns immediately. Combined with the counter reset, a client facing a down server reconnects in a tight loop and never reaches `.givenUp`.
- A normal server close is treated as a failure and triggers reconnect; `.closedByPeer` is never emitted.
- Calling `events()` a second time replaces the continuation without closing the first connection.
- There is no pinning and no test for `WebSocketClient` itself; only `ReconnectPolicy` is tested.

**Missing**
- Tests for 401 → refresh through a real transport, concurrent refresh, multipart, download, pinning, cancellation and Alamofire error mapping.
- `Retry-After` support and proactive refresh (`AuthTokens.isExpired` is unused).
- Background sessions, reachability (`NWPathMonitor`) and GraphQL are out of scope.
- No `LICENSE` file and no DocC catalog.
