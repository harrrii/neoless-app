// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "neoless",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "neoless", targets: ["neoless"]),
        // The hub on the Neo (docs/hub.md): HTTP service, stores, pairing and login commands.
        .executable(name: "neoless-hub", targets: ["neoless-hub"]),
        // For a future iPhone app (docs/hub.md, “iPhone”) and the hub, which use the package's libraries.
        .library(name: "NeolessCore", targets: ["NeolessCore"]),
        .library(name: "NeolessCloud", targets: ["NeolessCloud"]),
    ],
    dependencies: [
        // Only the hub uses it (NeolessHubKit, neoless-hub, NeolessHubTests); the app and the libraries stay free of it.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // Already in Hummingbird's graph; named here so the hub can import HTTPTypes and Logging directly.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Pure logic: no AppKit, no audio, no network. Everything here is unit-tested. macOS and iOS.
        .target(name: "NeolessCore"),
        // Shared by the Mac app, the hub on the Neo and a future iPhone app: the ChatGPT login and polish, the hub's
        // wire protocol and client, audio upload encoding. Foundation and AVFoundation only (macOS and iOS).
        .target(name: "NeolessCloud", dependencies: ["NeolessCore"]),
        .executableTarget(name: "neoless", dependencies: ["NeolessCore", "NeolessCloud"]),
        // The hub's routes, pipeline, stores and commands, as a library so tests can drive them. macOS only.
        .target(name: "NeolessHubKit", dependencies: [
            "NeolessCore", "NeolessCloud",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        // `neoless-hub serve | pair | devices | revoke | login | status`: a thin main over NeolessHubKit.
        .executableTarget(name: "neoless-hub", dependencies: ["NeolessHubKit"]),
        .testTarget(name: "NeolessCoreTests", dependencies: ["NeolessCore"]),
        .testTarget(name: "NeolessCloudTests", dependencies: ["NeolessCloud", "NeolessCore"]),
        .testTarget(name: "NeolessHubTests", dependencies: [
            "NeolessHubKit", "NeolessCloud", "NeolessCore",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ]),
    ]
)
