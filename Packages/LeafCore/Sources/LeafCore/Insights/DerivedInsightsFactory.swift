import Foundation

/// Single entry point for obtaining a `DerivedInsights` implementation.
/// Callsites (MenuBarApp, MCPServer) don't reference concrete types —
/// the provider is registered by the consumer at startup (dependency injection).
///
/// Why not `#if LEAF_PROD` inside the factory: Xcode doesn't propagate
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` into SPM dependencies, so a
/// conditional import wouldn't work here. The flag exists only in the app/agent
/// targets — that's where the choice of which implementation to register is made.
///
/// Public build / CI without registration → `StubInsights` (throws on all
/// methods). Dev/prod → the app registers `ProdInsights` in `App.init()`.
public enum DerivedInsightsFactory {
    // Registration — once at app startup. Last-writer wins,
    // conceptually read-many-write-once → `nonisolated(unsafe)` acceptable.
    nonisolated(unsafe) private static var provider: (@Sendable (Database) -> any DerivedInsights)?

    public static func register(
        _ provider: @escaping @Sendable (Database) -> any DerivedInsights
    ) {
        Self.provider = provider
    }

    public static func make(database: Database) -> any DerivedInsights {
        provider?(database) ?? StubInsights(database: database)
    }
}
