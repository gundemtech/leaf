import Foundation

/// Helper для сборки tool-response JSON с общим полем `"version"`.
///
/// Все MCP-tools Leaf возвращают payload в виде JSON-строки внутри
/// `ToolCallResult.content[0].text`. Чтобы клиенты (Claude Code и будущие)
/// могли distinguish schema versions между релизами Leaf, добавляем
/// top-level `"version": N` в каждый payload. Bumping `schemaVersion` —
/// breaking change для tool consumer'ов.
///
/// Это **tool-output schema version**, НЕ MCP-protocol version
/// (MCP protocol version negotiated в `InitializeHandler`).
public enum ToolResponseBuilder {
    /// Текущая версия schema tool outputs. Инкрементировать только при
    /// breaking изменениях (переименование поля, смена типа, удаление ключа).
    /// Добавление опциональных полей — compatible, не требует bump'а.
    public static let schemaVersion = 1

    /// Сериализует payload в JSON с добавленным `"version": schemaVersion`
    /// и возвращает готовый `ToolCallResult`.
    ///
    /// - `payload` не должен содержать ключ `"version"` — он перезапишется.
    /// - `JSONSerialization` options: `.sortedKeys` для deterministic output.
    public static func versionedJSONResult(_ payload: [String: Any]) throws -> ToolCallResult {
        var p = payload
        p["version"] = schemaVersion
        let data = try JSONSerialization.data(
            withJSONObject: p,
            options: [.sortedKeys]
        )
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        return ToolCallResult(
            content: [.text(TextContent(text: jsonString))],
            isError: false
        )
    }
}
