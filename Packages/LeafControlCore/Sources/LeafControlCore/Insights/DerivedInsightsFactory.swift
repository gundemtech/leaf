import Foundation
#if LEAFCONTROL_PROD
import LeafControlCorePrivate
#endif

/// Единый entry point для получения `DerivedInsights` реализации.
/// Callsite'ы (MenuBarApp, MCPServer) не должны ссылаться на конкретные
/// типы `StubInsights` / `ProdInsights` — провайдер выбирается compile-time
/// на основе флага `LEAFCONTROL_PROD`.
///
/// Без флага (публичный build / CI) → `StubInsights`, который throws на всех
/// методах. С флагом (dev/prod) → `ProdInsights` из gitignored moat-модуля.
public enum DerivedInsightsFactory {
    public static func make(database: Database) -> any DerivedInsights {
        #if LEAFCONTROL_PROD
        return ProdInsights(database: database)
        #else
        return StubInsights(database: database)
        #endif
    }
}
