import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.2 — MCP-tool: return Linear issue activity for a period (today /
/// yesterday / last_7_days). Reads same encrypted DB as MenuBar app —
/// single source of truth. 5th tool out of 8 planned in the whitepaper.
///
/// Output payload (versioned `version: 1` via `ToolResponseBuilder`):
///   - `period`, `from`, `to` — window
///   - `issuesTouched` — distinct issue_key count
///   - `byProject[]` — `{project, count}`, top-5 by distinct issues
///   - `byStatus[]` — `{status, count}`, top-5 by distinct issues
///   - `completionDurationStats` (Phase 4.6.A.2, additive optional) —
///     `{medianSeconds, avgSeconds, maxSeconds, sampleCount}` for issues completed
///     in the window; absent if sampleCount=0
///   - `wowDelta` (Phase 4.6.C.1, additive optional) — global week-over-week
///     activity delta scalar
///   - `issueCloseStreak` (Phase 4.6.C.3, additive optional) — consecutive days
///     with ≥1 closed issue (independent of period)
///   - `transitions` (Phase 4.6.B, additive optional) — `{started, completed,
///     canceled, reopened, total}` my status transitions counts; absent
///     if total=0
///   - `completionRate` (Phase 4.6.B, additive optional) — soft follow-through
///     ratio `completed / (completed + started + reopened)`, surfaced only
///     when completed > 0
///
/// Metadata only — issue bodies / comment text never leave the device
/// (ADR-010 won't-list, enforced at parser-level in LinearGraphQLProvider).
struct GetLinearActivityTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "period": [
                    "type": "string",
                    "enum": ["today", "yesterday", "last_7_days"],
                    "description": "Time window (default: today)"
                ]
            ],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "get_linear_activity",
            description: "Return Linear issue activity (distinct issues touched, breakdown by project and status, plus completion duration stats for issues closed in the period) for the given period. Metadata only — issue bodies and comments never leave the device.",
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        let period: TimelinePeriod
        if let dict = arguments?.value as? [String: Any],
           let raw = dict["period"] as? String {
            guard let p = TimelinePeriod(rawValue: raw) else {
                throw MCPProtocolError.invalidParams(
                    "period must be one of: today, yesterday, last_7_days"
                )
            }
            period = p
        } else {
            period = .today
        }

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return ToolCallResult(
                content: [.text(TextContent(
                    text: "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first."
                ))],
                isError: true
            )
        }

        let database = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        let insights = DerivedInsightsFactory.make(database: database)
        let interval = period.interval()
        let breakdown = try insights.linearActivity(period: interval)

        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "issuesTouched": breakdown.issuesTouched,
            "byProject": breakdown.byProject.map { entry -> [String: Any] in
                ["project": entry.project, "count": entry.count]
            },
            "byStatus": breakdown.byStatus.map { entry -> [String: Any] in
                ["status": entry.status, "count": entry.count]
            }
        ]
        if let dur = breakdown.completionDurationStats {
            payload["completionDurationStats"] = [
                "medianSeconds": dur.medianSeconds,
                "avgSeconds": dur.avgSeconds,
                "maxSeconds": dur.maxSeconds,
                "sampleCount": dur.sampleCount
            ]
        }
        // Phase 4.6.C.1 — global week-over-week activity delta (additive optional;
        // absent if baseline < 7 days OR prev week zero). Same scalar across
        // 3 integration tools — it's a global attention-time trend.
        if let wow = try? insights.weekOverWeekDelta() {
            payload["wowDelta"] = wow
        }
        // Phase 4.6.C.3 — issue close streak (consecutive days with ≥1 closed issue;
        // independent of period — global current streak ending today/yesterday).
        if let streak = breakdown.issueCloseStreak, streak > 0 {
            payload["issueCloseStreak"] = streak
        }
        // Phase 4.6.B — my status transitions (started/completed/canceled/reopened).
        // Full breakdown shape (including zeros) for machine consumers; UI layer
        // filters non-zero buckets separately. Absent if breakdown.transitions
        // == nil (total=0).
        if let tx = breakdown.transitions {
            payload["transitions"] = [
                "started": tx.started,
                "completed": tx.completed,
                "canceled": tx.canceled,
                "reopened": tx.reopened,
                "total": tx.total
            ]
        }
        // Phase 4.6.B — soft follow-through ratio. Absent if completed=0
        // (avoids misleading "0% follow-through" for a typical in-progress day).
        if let rate = breakdown.completionRate {
            payload["completionRate"] = rate
        }
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
