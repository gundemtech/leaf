import Foundation
import GRDB

/// Phase 4.7.B-18 — read-side helper for `get_cross_provider_thread` MCP tool.
///
/// Builds a single-issue cross-provider timeline by UNION'ing events whose
/// payload either has `source = 'linear'` AND `issue_key = ?`, OR has
/// `linked_linear_id = ?` (set by Phase 4.7.A `LinearIDExtractor` on GitHub
/// gh_commit_pushed / gh_pr_*  events). Result — chronologically sorted timeline
/// across providers + first/last touch / total duration.
///
/// Slack events deferred to Phase 4.8 (per design — aggregate event semantics
/// conflict with per-event timeline shape; mention scanning will require
/// channel-text scan that ADR-010 forbids without per-event redaction layer).
///
/// Лежит в LeafCore (а не в LeafMCP/Tools/), чтобы быть testable из SPM —
/// `LeafMCP` это Xcode target и под `swift test` не собирается. Tool struct
/// `GetCrossProviderThreadTool` в `LeafMCP/Tools/` — тонкая обёртка над этим
/// helper'ом.
///
/// ADR-010: helper не парсит bodies / commit messages / PR titles — поверх
/// `payload_json` уже sanitized fields'ов. Output projection — только
/// metadata (event_kind, repo, pr_number, sha, branch, issue_key, status,
/// linked_linear_id) — никаких title-полей не возвращаем.
public enum CrossProviderInsights {
    /// Maximum events возвращаемых одним вызовом. Bounded чтобы AI-клиент
    /// не получил многомегабайтный ответ для long-running issue.
    public static let maxEvents: Int = 200

    /// Cross-provider timeline для конкретного Linear issue ID
    /// (e.g., "LEAF-456"). Chronologically sorted по `ts ASC`.
    ///
    /// Returns payload готовый к сериализации:
    /// ```
    /// {
    ///   "linear_issue_id": String,                // echo of arg
    ///   "events": [
    ///     {
    ///       "ts_ms": Int64,
    ///       "source": String,                     // "linear" | "github"
    ///       "event_kind": String,                 // "issue_updated" | "gh_commit_pushed" | "gh_pr_opened" | ...
    ///       "payload": [String: Any]              // metadata-only projection
    ///     },
    ///     ...
    ///   ],
    ///   "first_touch_ms": Int64,                  // 0 если events empty
    ///   "last_touch_ms": Int64,                   // 0 если events empty
    ///   "duration_seconds": Int                   // 0 если events empty
    /// }
    /// ```
    /// Empty results → `events: []`, `first_touch_ms: 0`, `last_touch_ms: 0`,
    /// `duration_seconds: 0`. Top-level shape preserved для consistency.
    public static func crossProviderThread(
        database: Database,
        linearIssueID: String
    ) throws -> [String: Any] {
        var events: [[String: Any]] = []
        var firstTouchMs: Int64 = 0
        var lastTouchMs: Int64 = 0

        try database.readSQL { rawDB in
            // Plan-required SQL: UNION across sources via OR condition. `?` bind
            // используется дважды (linear issue_key + github linked_linear_id) —
            // GRDB.StatementArguments позиционно matched.
            let sql = """
                SELECT \(Schema.Events.ts) AS ts, \(Schema.Events.payloadJSON) AS payload_json
                FROM \(Schema.Events.tableName)
                WHERE
                   (json_extract(\(Schema.Events.payloadJSON), '$.source') = 'linear'
                    AND json_extract(\(Schema.Events.payloadJSON), '$.issue_key') = ?)
                OR (json_extract(\(Schema.Events.payloadJSON), '$.linked_linear_id') = ?)
                ORDER BY \(Schema.Events.ts) ASC
                LIMIT \(maxEvents)
                """
            let rows = try GRDB.Row.fetchAll(rawDB, sql: sql, arguments: [linearIssueID, linearIssueID])
            for row in rows {
                guard let tsMs = row["ts"] as? Int64,
                      let payloadStr = row["payload_json"] as? String,
                      let payloadData = payloadStr.data(using: .utf8),
                      let dict = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
                else { continue }
                let source = dict["source"] as? String ?? ""
                let eventKind = dict["event_kind"] as? String ?? ""
                let projected = projectPayload(dict)
                events.append([
                    "ts_ms": tsMs,
                    "source": source,
                    "event_kind": eventKind,
                    "payload": projected
                ])
                if firstTouchMs == 0 || tsMs < firstTouchMs {
                    firstTouchMs = tsMs
                }
                if tsMs > lastTouchMs {
                    lastTouchMs = tsMs
                }
            }
        }

        let durationSeconds: Int
        if events.isEmpty {
            durationSeconds = 0
        } else {
            // duration = (last - first) / 1000 (ceil не нужен — integer math
            // достаточно для cross-provider thread, sub-second precision не value-add).
            durationSeconds = Int((lastTouchMs - firstTouchMs) / 1000)
        }

        return [
            "linear_issue_id": linearIssueID,
            "events": events,
            "first_touch_ms": firstTouchMs,
            "last_touch_ms": lastTouchMs,
            "duration_seconds": durationSeconds
        ]
    }

    /// ADR-010 metadata-only projection. Whitelist of safe payload keys —
    /// everything else (title / commit message body / etc) dropped перед
    /// surfacing на MCP wire.
    ///
    /// Whitelist умышленно небольшой и conservative — лучше пропустить
    /// потенциально полезное поле, чем accidentally shipping body content.
    private static let payloadWhitelist: Set<String> = [
        "source",
        "event_kind",
        "issue_key",
        "status",
        "project",
        "team_key",
        "repo",
        "number",
        "sha",
        "branch",
        "linked_linear_id",
        "completion_seconds",
        "cycle_seconds",
        "review_delay_seconds",
        "action"
    ]

    private static func projectPayload(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in raw where payloadWhitelist.contains(key) {
            out[key] = value
        }
        return out
    }
}
