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
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
