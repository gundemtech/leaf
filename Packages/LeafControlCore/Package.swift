// swift-tools-version: 6.0
// See whitepaper 03-architecture for the role of this package in the overall system.
import PackageDescription

let package = Package(
    name: "LeafControlCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LeafControlCore", targets: ["LeafControlCore"])
    ],
    targets: [
        .target(
            name: "LeafControlCore",
            dependencies: ["LeafControlCorePrivate"],
            path: "Sources/LeafControlCore"
        ),
        .target(
            name: "LeafControlCorePrivate",
            path: "Sources/LeafControlCorePrivate"
        ),
        .testTarget(
            name: "LeafControlCoreTests",
            dependencies: ["LeafControlCore"],
            path: "Tests/LeafControlCoreTests"
        )
    ]
)
