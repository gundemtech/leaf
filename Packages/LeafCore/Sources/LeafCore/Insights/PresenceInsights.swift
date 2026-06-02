import Foundation
import GRDB

/// Phase 4.7.B-15 — read-side helper for a merged presence snapshot across
/// providers. A thin wrapper over `PresenceStateWriter.readAll` that formats
/// the result into a JSON-friendly `[String: Any]` payload ready for
/// `ToolResponseBuilder.versionedJSONResult` in the MCP tool.
///
/// Lives in LeafCore (rather than LeafMCP/Tools/) so it is testable from SPM —
/// `LeafMCP` is an Xcode target and is not built under `swift test`. The tool
/// struct in `LeafMCP/Tools/GetCurrentPresenceTool.swift` is a five-line wrapper
/// over this helper.
///
/// Phase 4.7.B-16 extended the helper with `workloadPulse(database:period:)` —
/// an aggregated cross-provider snapshot ("what's on your plate right now")
/// for the `get_workload_pulse` MCP tool. It mixes `presence_state` (live state) +
/// `events` (recent activity counts) — the period parameter affects only the
/// `events` aggregates, presence_state rows are always live (single-row-per-provider
/// materialized view, no period concept).
///
/// ADR-010: the helper does no extra filtering — responsibility for stripping
/// bodies/titles/PII lies with each collector before writing into
/// `presence_state` (see PresenceStateWriter doc-comment).
public enum PresenceInsights {
    /// Period for `workloadPulse(database:period:)`. The plan-required values
    /// diverge from `TimelinePeriod` (today/yesterday/last_7_days), hence a
    /// separate enum: today (calendar day, like TimelinePeriod), this_week
    /// (rolling 7 days), last_24h (rolling 24 hours).
    public enum WorkloadPulsePeriod: String, Sendable {
        case today
        case thisWeek = "this_week"
        case last24h = "last_24h"

        /// Returns the start timestamp (epoch ms) for the events-aggregate `ts >= start`.
        /// The `now` parameter is for testability (calendar boundaries are deterministic).
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
    /// Returns a payload ready for serialization:
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
    /// Empty DB → `providers == [:]` (an empty dictionary — distinct from
    /// "keys absent"; clients like Claude Code must handle this).
    /// `derived_mode` is always `nil` in Phase 4.7 — populated in Phase 4.9.
    public static func currentSnapshot(database: Database) throws -> [String: Any] {
        var providers: [String: Any] = [:]
        try database.readSQL { rawDB in
            let all = try PresenceStateWriter.readAll(in: rawDB)
            for (provider, entry) in all {
                providers[provider.rawValue] = [
                    "state": entry.state,
                    // Explicit NSNull for `derived_mode == nil` — otherwise
                    // JSONSerialization drops the key from the dictionary and clients
                    // won't see the shape "derived_mode: null". Phase 4.9 will start
                    // populating it with string values.
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
    /// Combines live `presence_state` rows (current queue size / cycle progress /
    /// DND / native presence) with `events` aggregates over the selected period
    /// (mention counts, file upload counts, in-progress CI runs).
    ///
    /// Returns a payload ready for serialization:
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
    ///     "current_cycle": [String: Any] | {}    // empty dict if no in-cycle teams
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
    /// Empty DB → all subkeys with default values (0 / "none" / false /
    /// "unknown" / `{}`). The "*_today" naming in the slack/output payload is kept
    /// per plan literal regardless of the selected period — the semantic intent
    /// "how much over the window" is the same; `period` is echoed in the payload so the
    /// reader doesn't have to guess what the window is.
    ///
    /// ADR-010: the helper does not parse bodies/titles — all aggregates are computed over
    /// numeric `count` payload fields, redaction is already done by the collectors.
    public static func workloadPulse(
        database: Database,
        period: WorkloadPulsePeriod = .today,
        now: Date = Date()
    ) throws -> [String: Any] {
        let periodStartMs = period.startMs(now: now)
        // `actions_runs_in_progress` — a separate current-state aggregate. The plan
        // window "active runs" is the last 24h, independent of period (CI runs
        // usually finish in minutes; older runs are almost always finished).
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
            // `count` payload field stored as String ("3") on top of the RawEvent
            // [String:String] payload type → CAST(... AS INTEGER) in SQL.
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

            // 6. events count — gh_actions_run_initiated with status='in_progress'
            // over the last 24h (independent of period; CI runs short-lived).
            github["actions_runs_in_progress"] = try Self.countEvents(
                eventKind: GitHubEventKindKey.actionsRunInitiated.rawValue,
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

    /// SUM(CAST(json_extract(payload_json, fieldPath) AS INTEGER)) for events
    /// matching `event_kind = ?` AND `ts >= ?`. NULL safety: if there are no
    /// events — `total` returns NULL → coalesce to 0.
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

    /// COUNT(*) for events matching `event_kind = ?` AND `status = ?` AND `ts >= ?`.
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
