# NetworkingKit

A reusable Swift package for the networking layer of iOS apps. `NetworkingCore` holds transport-agnostic abstractions; `NetworkingAlamofire` and `NetworkingURLSession` are interchangeable transports; `NetworkingWebSocket` is a generic WebSocket client; `NetworkingTesting` provides test doubles.

> **Status: prototype.** The design is stable and the test suite passes, but several defects in pinning, downloads and WebSocket reconnect make it unsuitable for production as-is. See [Status & known issues](#status--known-issues).

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

The suite contains 99 XCTest cases (Core 32, URLSession 33, WebSocket 5, Alamofire 29). All 99 passed on 2026-10-06 with Xcode 27.0 / Swift 6.4. Six assertions in the Alamofire tests are wrapped in `XCTExpectFailure` because they reproduce [known issues](#status--known-issues); they are reported as expected failures.

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

Every request kind goes through this chain in both transports: `send`, `sendVoid`, `upload` (multipart or not) and `download`. Each attempt runs `adapt` again, and after a non-2xx response or a transport error `retry` decides whether to send another attempt. Retries reuse the request body: the URLSession transport writes a multipart body to disk once and uploads that file on every attempt. A failed attempt's downloaded file is never placed at the destination (see [Download](#download)).

Cancelling the calling task ends the request with `APIError.cancelled`, also while it waits for a retry delay. The Alamofire transport does not do this yet; see known issues.

**Refresh on 401.** `AuthInterceptor` adds `Authorization: Bearer <accessToken>` from the `TokenStore`. On a 401 it calls `refreshAction`, saves the new tokens and retries the request with them, whatever the HTTP method, so a POST `upload` is refreshed too. Both transports behave the same way:

- Concurrent 401s share one in-flight refresh, so a rotating (single-use) refresh token is spent exactly once.
- A 401 for a request sent with an older access token than the stored one is retried with the current token without another refresh.
- Refresh does not depend on the attempt number: a request that got a 503, was retried and then got a 401 still refreshes.
- Refreshes are limited by `NetworkConfiguration.refreshWindow` (default: at most 5 within 30 seconds). Beyond that limit, or when `refreshAction` throws, the request fails with `APIError.unauthorized` instead of looping.

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

Requests with no response (transport errors) and responses with a retryable status are retried only for `retryableMethods`, by default GET, HEAD, PUT and DELETE; a multipart `upload` with POST therefore gets no status or transport retries unless POST is added. The delay is `min(maxDelay, baseDelay * 2^(attempt-1))` multiplied by the jitter factor, so it can exceed `maxDelay` by up to the upper jitter bound. The `Retry-After` header is not read.

**Progress across retries.** A `ProgressHandler` reports the fraction of the current attempt's request body sent (`upload`) or response body received (`download`). When a request is retried, the values start over near 0, so they can decrease, and a failed attempt may already have reported 1.0. Both transports behave this way. The Alamofire transport calls the handler on the main queue, the URLSession transport on its session's delegate queue.

## Errors

Both transports throw `APIError`. A non-2xx response becomes `.unauthorized` (401), `.forbidden` (403), `.notFound` (404), or `.server(statusCode:data:message:)` for any other status. For `send`, `sendVoid` and `upload`, `.server` carries the raw response body in `data`, so the app can decode its API's error format from it; `message` is a human-readable status description whose wording differs between transports.

401, 403 and 404 carry no body, because their cases have no associated values. `download` failures carry no body either.

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

The URLSession transport writes the body to a temporary file once, uploads that file with `URLSession.upload(for:fromFile:delegate:)` on every attempt, and removes it after the last attempt, also when writing it fails. The Alamofire transport uses `MultipartFormData`. Both transports escape field names and filenames in `Content-Disposition` as the WHATWG HTML Standard does for multipart/form-data: `"` becomes `%22`, CR `%0D` and LF `%0A`, and a lone CR or LF in a field name is first normalized to CRLF. No other characters are escaped.

`RequestBody.urlEncoded` is serialized by the WHATWG `application/x-www-form-urlencoded` rules in both transports: every byte except ASCII letters, digits and `*-._` is percent-encoded, and a space becomes `+`. Fields are sorted by name.

## Download

```swift
let savedURL = try await client.download(
    DownloadFile(fileId: file.id),
    to: .fileURL(downloadsDirectory.appendingPathComponent("\(file.id).bin")),
    progress: { fraction in print("download \(Int(fraction * 100))%") }
)
```

`DownloadDestination` has three cases: `.fileURL(URL, removeIfExists: Bool = true)`, `.documents(subpath:)` and `.temporary(filename:)`. Both transports place the file the same way:

| Situation | Result |
|---|---|
| No file at the destination | The file is written; missing intermediate directories are created. |
| A file exists; `.fileURL(url)`, `.documents` or `.temporary` | The existing file is replaced. |
| A file exists; `.fileURL(url, removeIfExists: false)` | The download fails and the existing file is kept. |
| A directory exists at the destination | The download fails; the directory is never replaced. |
| The request fails, including a non-2xx status | The destination is left untouched. |

The file is moved into place only after a 2xx response has been downloaded completely. When the request is retried, the URLSession transport deletes each failed attempt's download; the Alamofire transport currently leaves them in the temporary directory (see known issues). When it cannot be placed, `download` throws `APIError.transport` wrapping a `CocoaError`; an existing file or directory gives `.fileWriteFileExists`. `DownloadDestination.resolve()` keeps its 1.0 behavior and removes an existing file for `.fileURL(_, removeIfExists: true)` immediately; the transports do not call it.

`download(_:to:)` without `progress` is a convenience overload. Conformers of `APIClientProtocol` must implement `download(_:to:progress:)`.

Do not build a destination path from a server-provided filename without sanitizing it.

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

The package is a prototype. The issues below were confirmed by reading the code. Those marked *(reproduced)* are also covered by tests that wrap the failing assertion in `XCTExpectFailure(KnownIssue.…)` (`Tests/NetworkingAlamofireTests/KnownIssues.swift`); fixing one makes that test fail until the wrapper is removed.

**URLSession transport**
- After a transport error, `retry` receives the previous attempt's response instead of `nil`. When the previous attempt was the 401 that triggered a refresh, `AuthInterceptor` refreshes again, and `RetryInterceptor` decides by the old status code. The Alamofire transport passes the current attempt's response, which is `nil` after a transport error.
- A non-multipart `upload` never calls its `ProgressHandler`: the request is sent with `URLSession.data(for:)` without a task delegate. The Alamofire transport registers the handler with `uploadProgress` in this case.
- `PinningDelegate` never calls `SecTrustEvaluateWithError`. When a certificate or key matches, expiry, hostname and chain validation are skipped.
- A pin mismatch cancels the challenge, which surfaces as `URLError.cancelled` and is mapped to `APIError.cancelled` instead of a distinct pinning error.
- When the multipart body cannot be written (for example, a `.file` part points to a missing file), `upload` throws the underlying Foundation error instead of an `APIError`.

**Alamofire transport**
- `ServerTrustManager(evaluators:)` is created with Alamofire's default `allHostsMustBeEvaluated: true`, so once any host is pinned, requests to every unlisted host fail (including CDN and redirect targets).
- *(reproduced)* When a `download` is retried, each failed attempt's file stays in the temporary directory as `Alamofire_CFNetworkDownload_*.tmp`. Alamofire's `DownloadRequest` forgets the previous attempt's `fileURL` on retry without deleting the file, and the transport removes only the last attempt's file.
- *(reproduced)* Cancelling the calling task while a request waits for a retry delay does not end with `APIError.cancelled`. A cancelled `download` never finishes: Alamofire finishes the cancelled request, its response serializer asks the retrier again, `RetryInterceptor` asks for another retry, and `Session` skips retries of cancelled requests, so the response is never delivered. A cancelled multipart `upload` throws the last attempt's error, such as `.server(503)`. `send` and `sendVoid` use the same `DataRequest` path as `upload` but are not tested.
- `validate()` also checks a non-empty response's `Content-Type` against the request's `Accept`, which `EndpointAdapter` sets to `application/json` unless the endpoint provides one. A `download` of, say, `application/zip`, or a `sendVoid` answered with `text/plain`, fails with `AFError.responseValidationFailed(.unacceptableContentType)`, mapped to `APIError.transport`. The URLSession transport does not check `Content-Type`.

**Both transports**
- `.unauthorized`, `.forbidden` and `.notFound` drop the response body, so error envelopes sent with 401, 403 or 404 are lost. Fixing this changes `APIError`'s public cases and is planned for 2.0.0.

**NetworkingTesting**
- `MockAPIClient.download` writes through `DownloadDestination.resolve()` and `Data.write(to:)`, so it overwrites an existing file even for `.fileURL(_, removeIfExists: false)` and does not follow the transports' overwrite rules.

**WebSocket**
- `connect()` yields `.connected` and resets the attempt counter right after `resume()`, before the handshake completes, so `.connected` can be reported for a socket that never opens.
- When `handleFailure` runs on the receive-loop task, it cancels that task first, so the following `Task.sleep` returns immediately. Combined with the counter reset, a client facing a down server reconnects in a tight loop and never reaches `.givenUp`.
- A normal server close is treated as a failure and triggers reconnect; `.closedByPeer` is never emitted.
- Calling `events()` a second time replaces the continuation without closing the first connection.
- There is no pinning and no test for `WebSocketClient` itself; only `ReconnectPolicy` is tested.

**Missing**
- Tests for pinning, for cancellation outside a retry delay, and for the Alamofire mapping of decoding and transport errors.
- `Retry-After` support and proactive refresh (`AuthTokens.isExpired` is unused).
- Background sessions, reachability (`NWPathMonitor`) and GraphQL are out of scope.
- No `LICENSE` file and no DocC catalog.
