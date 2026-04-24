import Foundation

/// Единый entry point для получения `DerivedInsights` реализации.
/// Callsite'ы (MenuBarApp, MCPServer) не ссылаются на конкретные типы —
/// provider регистрируется consumer'ом при старте (dependency injection).
///
/// Почему не `#if LEAF_PROD` внутри factory: Xcode не прокидывает
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` внутрь SPM dependencies, поэтому
/// conditional import здесь не сработал бы. Флаг есть только в app/agent
/// target'ах — там и решается какую реализацию зарегистрировать.
///
/// Публичный build / CI без регистрации → `StubInsights` (throws на всех
/// методах). Dev/prod → app регистрирует `ProdInsights` в `App.init()`.
public enum DerivedInsightsFactory {
    // Registration — единожды на старте приложения. Last-writer wins,
    // концептуально read-many-write-once → `nonisolated(unsafe)` acceptable.
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
