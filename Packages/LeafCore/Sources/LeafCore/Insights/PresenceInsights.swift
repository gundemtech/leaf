import Foundation

/// Phase 4.7.B-15 — read-side helper для merged presence snapshot across
/// providers. Тонкий wrapper поверх `PresenceStateWriter.readAll`, который
/// форматирует результат в JSON-friendly `[String: Any]` payload готовый
/// под `ToolResponseBuilder.versionedJSONResult` в MCP tool'е.
///
/// Живёт в LeafCore (а не в LeafMCP/Tools/), чтобы быть testable из SPM —
/// `LeafMCP` это Xcode target и под `swift test` не собирается. Tool struct
/// в `LeafMCP/Tools/GetCurrentPresenceTool.swift` — пятистрочная обёртка
/// над этим helper'ом.
///
/// ADR-010: helper не делает доп. фильтрации — ответственность по очистке
/// от bodies/titles/PII лежит на каждом collector'е до записи в
/// `presence_state` (см. PresenceStateWriter doc-comment).
public enum PresenceInsights {
    /// Merged snapshot across all `presence_state` rows.
    ///
    /// Returns payload готовый к сериализации:
    /// ```
    /// {
    ///   "providers": {
    ///     "github": { "state": {...}, "derived_mode": null|String, "updated_at_ms": Int64 },
    ///     "linear": { ... },
    ///     "slack":  { ... }
    ///   },
    ///   "observed_at_ms": Int64
    /// }
    /// ```
    /// Empty DB → `providers == [:]` (пустой словарь — отличается от
    /// "ключи отсутствуют"; clients типа Claude Code должны это handle'ить).
    /// `derived_mode` всегда `nil` в Phase 4.7 — populated в Phase 4.9.
    public static func currentSnapshot(database: Database) throws -> [String: Any] {
        var providers: [String: Any] = [:]
        try database.readSQL { rawDB in
            let all = try PresenceStateWriter.readAll(in: rawDB)
            for (provider, entry) in all {
                providers[provider.rawValue] = [
                    "state": entry.state,
                    // Explicit NSNull для `derived_mode == nil` — иначе
                    // JSONSerialization выбросит ключ из словаря и клиенты
                    // не увидят shape "derived_mode: null". Phase 4.9 начнёт
                    // populate'ить string-значениями.
                    "derived_mode": entry.derivedMode as Any? ?? NSNull(),
                    "updated_at_ms": entry.updatedAtMs
                ]
            }
        }
        return [
            "providers": providers,
            "observed_at_ms": Int64(Date().timeIntervalSince1970 * 1000)
        ]
    }
}
