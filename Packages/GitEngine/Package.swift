// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
        .library(name: "GitTestSupport", targets: ["GitTestSupport"]),
    ],
    targets: [
        .target(name: "GitEngine"),
        .target(name: "GitTestSupport", dependencies: ["GitEngine"]),
        .testTarget(name: "GitEngineTests", dependencies: ["GitEngine", "GitTestSupport"]),
    ]
)
