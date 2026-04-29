import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.4 — MCP-tool: вернуть Slack activity за период (today /
/// yesterday / last_7_days). Reads same encrypted DB что MenuBar app —
/// single source of truth. 7-й tool из 8 запланированных в whitepaper.
///
/// Output payload (versioned `version: 1` через `ToolResponseBuilder`):
///   - `period`, `from`, `to` — окно
///   - `messagesCount` — сумма count'ов action events
///     `payload.source='slack' AND event_kind='message_authored_aggregate'`
///   - `huddleMinutes` — derived из context events `huddle_state_change`
///   - `byChannel[]` — `{channel, count}`, top-5 by count DESC.
///     DM channels уже слиты в "DM" bucket на parser-level (ADR-010).
///
/// Metadata only — message bodies / permalinks / status text никогда не
/// покидают устройство (ADR-010 won't-list, enforced на parser-level в
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
            description: "Return Slack activity (messages count, huddle minutes, breakdown by channel) for the given period. Metadata only — message bodies are never stored.",
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
        let payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "messagesCount": breakdown.messagesCount,
            "huddleMinutes": breakdown.huddleMinutes,
            "byChannel": breakdown.byChannel.map { entry -> [String: Any] in
                ["channel": entry.channelName, "count": entry.count]
            }
        ]
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
