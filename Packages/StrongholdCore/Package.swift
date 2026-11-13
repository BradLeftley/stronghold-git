// swift-tools-version: 6.0
import PackageDescription

/// App-level state and logic that sits between the SwiftUI views and the Git engine.
/// Kept out of the app target so it can be unit tested with `swift test` and `xcodebuild test`.
let package = Package(
    name: "StrongholdCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StrongholdCore", targets: ["StrongholdCore"]),
    ],
    dependencies: [
        .package(path: "../GitEngine"),
    ],
    targets: [
        .target(name: "StrongholdCore", dependencies: [.product(name: "GitEngine", package: "GitEngine")]),
        .testTarget(name: "StrongholdCoreTests", dependencies: [
            "StrongholdCore",
            .product(name: "GitTestSupport", package: "GitEngine"),
        ]),
    ]
)
