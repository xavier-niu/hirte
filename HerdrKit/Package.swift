// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HerdrKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
        .library(name: "SSHTransport", targets: ["SSHTransport"]),
        .library(name: "KeyStore", targets: ["KeyStore"]),
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.12.1"),
    ],
    targets: [
        .target(name: "KeyStore"),
        .target(name: "SSHTransport", dependencies: ["KeyStore", .product(name: "Citadel", package: "Citadel")]),
        // Built by `just ghostty` from vendor/ghostty (not checked in).
        .binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework"),
        .target(name: "TerminalCore", dependencies: ["GhosttyVt"]),
        .target(name: "HerdrKit", dependencies: ["SSHTransport", "TerminalCore"]),
        .testTarget(name: "KeyStoreTests", dependencies: ["KeyStore"]),
        .testTarget(name: "SSHTransportTests", dependencies: ["SSHTransport", .product(name: "Citadel", package: "Citadel")]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit", "TerminalCore"]),
    ]
)
