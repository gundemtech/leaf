import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.3 — MCP-tool: return GitHub events activity for a period (today /
/// yesterday / last_7_days). Reads same encrypted DB as MenuBar app —
/// single source of truth. 6th tool out of 8 planned in the whitepaper.
///
/// Output payload (versioned `version: 1` via `ToolResponseBuilder`):
///   - `period`, `from`, `to` — window
///   - `eventsCount` — total events with `signal_type='action'` AND `payload.source='github'`
///   - `byRepo[]` — `{repo, count}`, top-5 by count DESC
///   - `byEventKind[]` — `{eventKind, count}`, top-5 by count DESC
///   - `prCycleStats` (Phase 4.6.A.1, additive optional) — `{medianSeconds, avgSeconds,
///     maxSeconds, sampleCount}` for `gh_pr_merged` events; absent if sampleCount=0
///   - `reviewDelayStats` (Phase 4.6.A.1, additive optional) — same for `gh_pr_review_submitted`
///
/// Metadata only — PR/issue bodies, comments, file diffs never leave
/// the device (ADR-010 won't-list, enforced at parser-level in ProdGitHubAPIProvider).
struct GetGitHubActivityTool: ToolExecutor {
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
            name: "get_github_activity",
            description: "Return GitHub events activity (total events, breakdown by repo and event kind) for the given period. Metadata only — PR/issue bodies, comments, and file diffs never leave the device.",
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
        let breakdown = try insights.githubActivity(period: interval)

        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "eventsCount": breakdown.eventsCount,
            "byRepo": breakdown.byRepo.map { entry -> [String: Any] in
                ["repo": entry.repo, "count": entry.count]
            },
            "byEventKind": breakdown.byEventKind.map { entry -> [String: Any] in
                ["eventKind": entry.eventKind, "count": entry.count]
            }
        ]
        if let cycle = breakdown.prCycleStats {
            payload["prCycleStats"] = [
                "medianSeconds": cycle.medianSeconds,
                "avgSeconds": cycle.avgSeconds,
                "maxSeconds": cycle.maxSeconds,
                "sampleCount": cycle.sampleCount
            ]
        }
        if let delay = breakdown.reviewDelayStats {
            payload["reviewDelayStats"] = [
                "medianSeconds": delay.medianSeconds,
                "avgSeconds": delay.avgSeconds,
                "maxSeconds": delay.maxSeconds,
                "sampleCount": delay.sampleCount
            ]
        }
        // Phase 4.6.C.1 — global week-over-week activity delta (additive optional).
        if let wow = try? insights.weekOverWeekDelta() {
            payload["wowDelta"] = wow
        }
        // Phase 4.6.C.3 — commit streak (consecutive days with ≥1 commit pushed;
        // independent of period — global current streak ending today/yesterday).
        if let streak = breakdown.commitStreak, streak > 0 {
            payload["commitStreak"] = streak
        }
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
