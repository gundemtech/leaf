import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.2 — MCP-tool: вернуть Linear issue activity за период (today /
/// yesterday / last_7_days). Reads same encrypted DB что MenuBar app —
/// single source of truth. 5-й tool из 8 запланированных в whitepaper.
///
/// Output payload (versioned `version: 1` через `ToolResponseBuilder`):
///   - `period`, `from`, `to` — окно
///   - `issuesTouched` — distinct issue_key count
///   - `byProject[]` — `{project, count}`, top-5 by distinct issues
///   - `byStatus[]` — `{status, count}`, top-5 by distinct issues
///   - `completionDurationStats` (Phase 4.6.A.2, additive optional) —
///     `{medianSeconds, avgSeconds, maxSeconds, sampleCount}` для issues, completed
///     в окне; отсутствует если sampleCount=0
///   - `wowDelta` (Phase 4.6.C.1, additive optional) — global week-over-week
///     activity delta scalar
///   - `issueCloseStreak` (Phase 4.6.C.3, additive optional) — consecutive days
///     с ≥1 closed issue (independent of period)
///   - `transitions` (Phase 4.6.B, additive optional) — `{started, completed,
///     canceled, reopened, total}` my status transitions counts; отсутствует
///     если total=0
///   - `completionRate` (Phase 4.6.B, additive optional) — soft follow-through
///     ratio `completed / (completed + started + reopened)`, surface'ится только
///     при completed > 0
///
/// Metadata only — issue bodies / comment text никогда не покидают устройство
/// (ADR-010 won't-list, enforced на parser-level в LinearGraphQLProvider).
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
        // absent если baseline < 7 days OR prev week zero). Same scalar across
        // 3 integration tools — это global attention-time trend.
        if let wow = try? insights.weekOverWeekDelta() {
            payload["wowDelta"] = wow
        }
        // Phase 4.6.C.3 — issue close streak (consecutive days с ≥1 closed issue;
        // independent of period — global current streak ending today/yesterday).
        if let streak = breakdown.issueCloseStreak, streak > 0 {
            payload["issueCloseStreak"] = streak
        }
        // Phase 4.6.B — my status transitions (started/completed/canceled/reopened).
        // Full breakdown shape (включая нули) для machine consumers; UI слой
        // фильтрует non-zero buckets отдельно. Absent если breakdown.transitions
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
        // Phase 4.6.B — soft follow-through ratio. Absent если completed=0
        // (avoids misleading "0% follow-through" для типичного in-progress дня).
        if let rate = breakdown.completionRate {
            payload["completionRate"] = rate
        }
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
