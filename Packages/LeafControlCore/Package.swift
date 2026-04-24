// swift-tools-version: 6.0
// See whitepaper 03-architecture for the role of this package in the overall system.
import PackageDescription

let package = Package(
    name: "LeafControlCore",
    platforms: [.macOS(.v14)],
    products: [
        // Public API — линкуется всегда всеми таргетами.
        .library(name: "LeafControlCore", targets: ["LeafControlCore"]),
        // Moat-target — линкуется всегда, но реальные файлы (Prod/**)
        // живут только на dev-машине (см. .gitignore). На публичном клоне
        // содержит только Placeholder.swift → собирается без ошибок.
        .library(name: "LeafControlCorePrivate", targets: ["LeafControlCorePrivate"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.10.0")
    ],
    targets: [
        .target(
            name: "LeafControlCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/LeafControlCore"
        ),
        .target(
            name: "LeafControlCorePrivate",
            dependencies: [
                "LeafControlCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/LeafControlCorePrivate"
        ),
        .testTarget(
            name: "LeafControlCoreTests",
            dependencies: ["LeafControlCore"],
            path: "Tests/LeafControlCoreTests"
        ),
        .testTarget(
            name: "LeafControlCorePrivateTests",
            dependencies: ["LeafControlCore", "LeafControlCorePrivate"],
            path: "Tests/LeafControlCorePrivateTests"
        )
    ]
)
