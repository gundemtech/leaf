import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.4 — MCP-tool: return Slack activity for a period (today /
/// yesterday / last_7_days). Reads same encrypted DB as MenuBar app —
/// single source of truth. 7th tool out of 8 planned in the whitepaper.
///
/// Output payload (versioned `version: 1` via `ToolResponseBuilder`):
///   - `period`, `from`, `to` — window
///   - `messagesCount` — sum of action event counts
///     `payload.source='slack' AND event_kind='slack_message_authored_aggregate'`
///   - `huddleMinutes` — derived from context events `slack_huddle_state_change`
///   - `byChannel[]` — `{channel, count}`, top-5 by count DESC.
///     DM channels are already collapsed into the "DM" bucket at parser-level (ADR-010).
///
/// Metadata only — message bodies / permalinks / status text never
/// leave the device (ADR-010 won't-list, enforced at parser-level in
/// ProdSlackAPIProvider).
struct GetSlackActivityTool: ToolExecutor {
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
            name: "get_slack_activity",
            description: "Return Slack activity (messages count, huddle minutes, breakdown by channel, reactions aggregate, huddle session distribution) for the given period. Metadata only — message bodies, reaction emoji names, and reactor identities are never stored.",
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
        let breakdown = try insights.slackActivity(period: interval)

        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "messagesCount": breakdown.messagesCount,
            "huddleMinutes": breakdown.huddleMinutes,
            "byChannel": breakdown.byChannel.map { entry -> [String: Any] in
                ["channel": entry.channelName, "count": entry.count]
            }
        ]
        // Phase 4.6.A.3 — additive optional fields (version=1 preserved;
        // older MCP clients ignore unknown keys).
        if let r = breakdown.reactionsReceived {
            payload["reactionsReceived"] = r
        }
        if let h = breakdown.huddleSessionStats {
            payload["huddleSessionStats"] = [
                "medianSeconds": h.medianSeconds,
                "avgSeconds": h.avgSeconds,
                "maxSeconds": h.maxSeconds,
                "sampleCount": h.sampleCount
            ]
        }
        // Phase 4.6.C.1 — global week-over-week activity delta (additive optional).
        if let wow = try? insights.weekOverWeekDelta() {
            payload["wowDelta"] = wow
        }
        // Phase 4.6.C.3 — huddle participation streak (consecutive days with ≥1
        // huddle joined; independent of period — global current streak).
        if let streak = breakdown.huddleParticipationStreak, streak > 0 {
            payload["huddleParticipationStreak"] = streak
        }
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
