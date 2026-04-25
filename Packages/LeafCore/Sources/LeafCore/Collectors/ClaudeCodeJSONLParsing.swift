import Foundation

/// Phase 2.3 — protocol для парсера одной line из Claude Code session jsonl.
/// Реальный парсер (schema mapping + tool allowlist + ADR-010 фильтрация
/// prompt content) живёт в `LeafCorePrivate/Prod/Collectors/ClaudeCodeJSONLParser.swift`
/// — это moat. Public Core ships только protocol + Stub.
///
/// Контекст вокруг line (cwd / git_branch / sessionId / source path) обычно
/// дублируется на верхнем уровне самой jsonl-line, но передаётся явно для двух
/// причин: (a) парсер не должен обязан заглядывать в top-level filesystem context
/// при `.malformed` строках, (b) source override полезен для тестов.
public protocol ClaudeCodeJSONLParsing: Sendable {
    /// Парсит ОДНУ line. Возвращает `[RawEvent]` потому что один `assistant`
    /// message может содержать несколько `tool_use` элементов в `message.content`.
    /// `source` — abs path к файлу для логов; `now` — фоллбек timestamp если
    /// в самой line нет parseable `timestamp`.
    func parse(line: String, source: String, now: Date) -> ClaudeCodeParseResult
}

/// Result для одной line. `.events` — что-то полезное распарсилось (≥0 events;
/// пустой массив тоже OK — например `assistant` с одним `text` элементом без tool_use).
/// `.irrelevant` — line известного типа, но мы её не ингестим (system / attachment / ...).
/// `.malformed` — JSON parse error или нарушение known schema → collector log warning + skip.
public enum ClaudeCodeParseResult: Sendable, Equatable {
    case events([RawEvent])
    case irrelevant
    case malformed(reason: String)
}

/// Public stub — dev/CI builds без moat. Возвращает `.irrelevant` для всего:
/// невыровненный билд не пишет AI events (у нас нет права угадывать schema
/// без moat-knowledge). Production использует `ClaudeCodeJSONLParser` из
/// LeafCorePrivate.
public struct StubClaudeCodeJSONLParser: ClaudeCodeJSONLParsing {
    public init() {}

    public func parse(line: String, source: String, now: Date) -> ClaudeCodeParseResult {
        .irrelevant
    }
}
