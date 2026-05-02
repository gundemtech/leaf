import Foundation
import GRDB

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
/// Phase 4.7.B-16 расширил helper методом `workloadPulse(database:period:)` —
/// aggregated cross-provider snapshot ("сколько на тарелке прямо сейчас")
/// для `get_workload_pulse` MCP tool. Mix `presence_state` (live state) +
/// `events` (recent activity counts) — period параметр влияет только на
/// `events`-aggregates, presence_state row-ы всегда live (single-row-per-provider
/// materialized view, без period concept).
///
/// ADR-010: helper не делает доп. фильтрации — ответственность по очистке
/// от bodies/titles/PII лежит на каждом collector'е до записи в
/// `presence_state` (см. PresenceStateWriter doc-comment).
public enum PresenceInsights {
    /// Period для `workloadPulse(database:period:)`. Plan-required values
    /// расходятся с `TimelinePeriod` (today/yesterday/last_7_days), поэтому
    /// отдельный enum: today (calendar day, like TimelinePeriod), this_week
    /// (rolling 7 days), last_24h (rolling 24 hours).
    public enum WorkloadPulsePeriod: String, Sendable {
        case today
        case thisWeek = "this_week"
        case last24h = "last_24h"

        /// Returns start timestamp (epoch ms) для events-aggregate `ts >= start`.
        /// `now` параметр — для testability (calendar boundaries детерминированы).
        public func startMs(now: Date = Date(), calendar: Calendar = .current) -> Int64 {
            switch self {
            case .today:
                let start = calendar.startOfDay(for: now)
                return Int64(start.timeIntervalSince1970 * 1000)
            case .thisWeek:
                let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
                return Int64(start.timeIntervalSince1970 * 1000)
            case .last24h:
                let start = calendar.date(byAdding: .hour, value: -24, to: now) ?? now
                return Int64(start.timeIntervalSince1970 * 1000)
            }
        }
    }

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

    /// Phase 4.7.B-16 — aggregated workload pulse across GitHub / Linear / Slack.
    /// Объединяет live `presence_state` rows (current queue size / cycle progress /
    /// DND / native presence) с `events` aggregates за выбранный period
    /// (mention counts, file upload counts, in-progress CI runs).
    ///
    /// Returns payload готовый к сериализации:
    /// ```
    /// {
    ///   "github": {
    ///     "prs_awaiting_my_review": Int,
    ///     "my_open_prs": Int,
    ///     "notifications_unread": Int,
    ///     "actions_runs_in_progress": Int
    ///   },
    ///   "linear": {
    ///     "started_count": Int,
    ///     "top_priority": String,                // "urgent"/"high"/.../"none"
    ///     "current_cycle": [String: Any] | {}    // empty dict если no in-cycle teams
    ///   },
    ///   "slack": {
    ///     "mentions_received_today": Int,        // SUM aggregated counts since period.start
    ///     "files_uploaded_today": Int,
    ///     "dnd_active": Bool,
    ///     "native_presence": String              // "active"/"away"/"unknown"
    ///   },
    ///   "period": String,                        // echo of period arg ("today"/"this_week"/"last_24h")
    ///   "observed_at_ms": Int64
    /// }
    /// ```
    /// Empty DB → все subkey'и со значениями-по-умолчанию (0 / "none" / false /
    /// "unknown" / `{}`). Naming "*_today" в slack/output payload оставлен
    /// per plan literal независимо от выбранного period — semantic intent
    /// "сколько за окно" одинаков; `period` echo'нут в payload чтобы reader
    /// не угадывал что окно есть.
    ///
    /// ADR-010: helper не парсит bodies/titles — все aggregates считаются по
    /// numeric `count` payload field'ам, redaction уже сделана collector'ами.
    public static func workloadPulse(
        database: Database,
        period: WorkloadPulsePeriod = .today,
        now: Date = Date()
    ) throws -> [String: Any] {
        let periodStartMs = period.startMs(now: now)
        // `actions_runs_in_progress` — отдельный сurrent-state aggregate. Plan
        // окно "active runs" — последние 24h independent от period (CI runs
        // обычно завершаются за минуты; older runs почти всегда finished).
        let actionsLookbackMs = Int64(now.timeIntervalSince1970 * 1000) - 24 * 60 * 60 * 1000

        var github: [String: Any] = [
            "prs_awaiting_my_review": 0,
            "my_open_prs": 0,
            "notifications_unread": 0,
            "actions_runs_in_progress": 0
        ]
        var linear: [String: Any] = [
            "started_count": 0,
            "top_priority": "none",
            "current_cycle": [:] as [String: Any]
        ]
        var slack: [String: Any] = [
            "mentions_received_today": 0,
            "files_uploaded_today": 0,
            "dnd_active": false,
            "native_presence": "unknown"
        ]

        try database.readSQL { rawDB in
            // 1. presence_state.github → 3 of 4 github subkeys.
            if let entry = try PresenceStateWriter.read(provider: .github, in: rawDB) {
                if let v = entry.state["prs_awaiting_my_review"] as? Int {
                    github["prs_awaiting_my_review"] = v
                }
                if let v = entry.state["my_open_prs"] as? Int {
                    github["my_open_prs"] = v
                }
                if let v = entry.state["notifications_unread"] as? Int {
                    github["notifications_unread"] = v
                }
            }

            // 2. presence_state.linear → 3 linear subkeys.
            if let entry = try PresenceStateWriter.read(provider: .linear, in: rawDB) {
                if let v = entry.state["started_issues_count"] as? Int {
                    linear["started_count"] = v
                }
                if let v = entry.state["top_priority"] as? String {
                    linear["top_priority"] = v
                }
                if let v = entry.state["current_cycle"] as? [String: Any] {
                    linear["current_cycle"] = v
                }
            }

            // 3. presence_state.slack → dnd_active + native_presence.
            if let entry = try PresenceStateWriter.read(provider: .slack, in: rawDB) {
                if let dnd = entry.state["dnd"] as? [String: Any],
                   let isActive = dnd["is_active"] as? Bool {
                    slack["dnd_active"] = isActive
                }
                if let v = entry.state["native_presence"] as? String {
                    slack["native_presence"] = v
                }
            }

            // 4. events aggregate — slack mentions received since period.start.
            // `count` payload field stored as String ("3") поверх RawEvent
            // [String:String] payload типа → CAST(... AS INTEGER) в SQL.
            // Plan-required SQL shape (see B-16 spec).
            slack["mentions_received_today"] = try Self.sumIntPayloadField(
                eventKind: "slack_mention_received_aggregate",
                fieldPath: "$.count",
                sinceMs: periodStartMs,
                in: rawDB
            )

            // 5. events aggregate — slack files uploaded since period.start.
            slack["files_uploaded_today"] = try Self.sumIntPayloadField(
                eventKind: "slack_file_uploaded_aggregate",
                fieldPath: "$.count",
                sinceMs: periodStartMs,
                in: rawDB
            )

            // 6. events count — actions_run_initiated с status='in_progress'
            // за последние 24h (independent от period; CI runs short-lived).
            github["actions_runs_in_progress"] = try Self.countEvents(
                eventKind: "actions_run_initiated",
                statusFilter: "in_progress",
                sinceMs: actionsLookbackMs,
                in: rawDB
            )
        }

        return [
            "github": github,
            "linear": linear,
            "slack": slack,
            "period": period.rawValue,
            "observed_at_ms": Int64(now.timeIntervalSince1970 * 1000)
        ]
    }

    // MARK: - Private SQL helpers (Phase 4.7.B-16)

    /// SUM(CAST(json_extract(payload_json, fieldPath) AS INTEGER)) для events
    /// matching `event_kind = ?` AND `ts >= ?`. NULL safety: если ни одного
    /// event'а — `total` returns NULL → coalesce в 0.
    private static func sumIntPayloadField(
        eventKind: String,
        fieldPath: String,
        sinceMs: Int64,
        in db: GRDB.Database
    ) throws -> Int {
        let sql = """
            SELECT COALESCE(SUM(CAST(json_extract(\(Schema.Events.payloadJSON), ?) AS INTEGER)), 0) AS total
            FROM \(Schema.Events.tableName)
            WHERE json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = ?
              AND \(Schema.Events.ts) >= ?
            """
        let row = try GRDB.Row.fetchOne(
            db,
            sql: sql,
            arguments: [fieldPath, eventKind, sinceMs]
        )
        return (row?["total"] as Int64?).map { Int($0) } ?? 0
    }

    /// COUNT(*) для events matching `event_kind = ?` AND `status = ?` AND `ts >= ?`.
    private static func countEvents(
        eventKind: String,
        statusFilter: String,
        sinceMs: Int64,
        in db: GRDB.Database
    ) throws -> Int {
        let sql = """
            SELECT COUNT(*) AS c
            FROM \(Schema.Events.tableName)
            WHERE json_extract(\(Schema.Events.payloadJSON), '$.event_kind') = ?
              AND json_extract(\(Schema.Events.payloadJSON), '$.status') = ?
              AND \(Schema.Events.ts) >= ?
            """
        let row = try GRDB.Row.fetchOne(
            db,
            sql: sql,
            arguments: [eventKind, statusFilter, sinceMs]
        )
        return (row?["c"] as Int64?).map { Int($0) } ?? 0
    }
}
