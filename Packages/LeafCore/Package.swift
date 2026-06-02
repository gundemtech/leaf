// swift-tools-version: 6.0
// See whitepaper 03-architecture for the role of this package in the overall system.
import PackageDescription

let package = Package(
    name: "LeafCore",
    platforms: [.macOS(.v14)],
    products: [
        // Public API — always linked by all targets.
        .library(name: "LeafCore", targets: ["LeafCore"]),
        // Moat target — always linked, but the real files (Prod/**)
        // live only on the dev machine (see .gitignore). On a public clone
        // it contains only Placeholder.swift → builds without errors.
        .library(name: "LeafCorePrivate", targets: ["LeafCorePrivate"]),
        // Pure MCP protocol layer (JSON-RPC envelope + MCP types + handlers
        // without side effects). Linked into the LeafMCP binary target.
        .library(name: "LeafMCPProtocol", targets: ["LeafMCPProtocol"]),
        // Track-6 P1 Phase E — thin native binary invoked by Claude Code hooks.
        // Reads JSON payload from stdin, forwards envelope to Unix domain socket
        // where Agent listens. See Sources/LeafHookBridge/main.swift.
        .executable(name: "leaf-hook-bridge", targets: ["LeafHookBridge"])
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
        ),
        .executableTarget(
            name: "LeafHookBridge",
            dependencies: [],  // intentionally zero deps — keeps binary tiny + fast cold start
            path: "Sources/LeafHookBridge"
        ),
        .testTarget(
            name: "LeafHookBridgeTests",
            dependencies: ["LeafHookBridge"],
            path: "Tests/LeafHookBridgeTests"
        )
    ]
)
