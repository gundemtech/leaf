// swift-tools-version: 6.0
// See whitepaper 03-architecture for the role of this package in the overall system.
import PackageDescription

let package = Package(
    name: "LeafCore",
    platforms: [.macOS(.v14)],
    products: [
        // Public API — линкуется всегда всеми таргетами.
        .library(name: "LeafCore", targets: ["LeafCore"]),
        // Moat-target — линкуется всегда, но реальные файлы (Prod/**)
        // живут только на dev-машине (см. .gitignore). На публичном клоне
        // содержит только Placeholder.swift → собирается без ошибок.
        .library(name: "LeafCorePrivate", targets: ["LeafCorePrivate"]),
        // Pure MCP protocol layer (JSON-RPC envelope + MCP types + handlers
        // без side effects). Линкуется в LeafMCP binary target.
        .library(name: "LeafMCPProtocol", targets: ["LeafMCPProtocol"])
    ],
    dependencies: [
        // GRDB fork with SQLCipher enabled. Tracks groue/GRDB.swift v7.10.0
        // with "GRDB+SQLCipher" inline instructions applied + SQLCipher.swift 4.14.0.
        .package(url: "https://github.com/gundemtech/GRDB.swift-sqlcipher", exact: "7.10.0-sqlcipher2")
    ],
    targets: [
        .target(
            name: "LeafCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift-sqlcipher")
            ],
            path: "Sources/LeafCore"
        ),
        .target(
            name: "LeafCorePrivate",
            dependencies: [
                "LeafCore",
                .product(name: "GRDB", package: "GRDB.swift-sqlcipher")
            ],
            path: "Sources/LeafCorePrivate"
        ),
        .testTarget(
            name: "LeafCoreTests",
            dependencies: ["LeafCore"],
            path: "Tests/LeafCoreTests"
        ),
        .testTarget(
            name: "LeafCorePrivateTests",
            dependencies: ["LeafCore", "LeafCorePrivate"],
            path: "Tests/LeafCorePrivateTests"
        ),
        .target(
            name: "LeafMCPProtocol",
            path: "Sources/LeafMCPProtocol"
        ),
        .testTarget(
            name: "LeafMCPProtocolTests",
            dependencies: ["LeafMCPProtocol"],
            path: "Tests/LeafMCPProtocolTests"
        )
    ]
)
