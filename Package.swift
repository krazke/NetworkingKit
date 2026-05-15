// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkingKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "NetworkingCore",       targets: ["NetworkingCore"]),
        .library(name: "NetworkingAlamofire",  targets: ["NetworkingAlamofire"]),
        .library(name: "NetworkingURLSession", targets: ["NetworkingURLSession"]),
        .library(name: "NetworkingWebSocket",  targets: ["NetworkingWebSocket"]),
        .library(name: "NetworkingTesting",    targets: ["NetworkingTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.11.0"),
    ],
    targets: [
        .target(
            name: "NetworkingCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NetworkingAlamofire",
            dependencies: ["NetworkingCore", "Alamofire"],
            swiftSettings: [.swiftLanguageMode(.v5)] // AF 5.11 ещё в Sendable-миграции
        ),
        .target(
            name: "NetworkingURLSession",
            dependencies: ["NetworkingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NetworkingWebSocket",
            dependencies: ["NetworkingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NetworkingTesting",
            dependencies: ["NetworkingCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(name: "NetworkingCoreTests",
                    dependencies: ["NetworkingCore", "NetworkingTesting"]),
        .testTarget(name: "NetworkingAlamofireTests",
                    dependencies: ["NetworkingAlamofire", "NetworkingTesting"]),
        .testTarget(name: "NetworkingURLSessionTests",
                    dependencies: ["NetworkingURLSession", "NetworkingTesting"]),
        .testTarget(name: "NetworkingWebSocketTests",
                    dependencies: ["NetworkingWebSocket", "NetworkingTesting"]),
    ]
)
