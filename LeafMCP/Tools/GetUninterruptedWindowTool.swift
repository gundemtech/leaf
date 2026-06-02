import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.6.C.2 — MCP tool: longest gap (uninterrupted window) between Layer B
/// integration events (Linear/GitHub/Slack) within a period. Proxy for "deep
/// async work session" — time of continuous work without notification-interruption
/// from tracked integrations. Differs from `get_current_session` (that one is about
/// macOS-level focus session) — here only integration silence.
///
/// Output payload (versioned `version: 1` via `ToolResponseBuilder`):
///   - `period`, `from`, `to` — window
///   - `start`, `end` — ISO timestamps of the window (period bounds are allowed as anchors:
///     start may be = period.start if the first event is much later,
///     end may be = period.end if the last event is much earlier)
///   - `durationSeconds` — gap duration
///   - `sourcesActive[]` — sources with ≥1 event in the period (honest signal:
///     ["slack"] means the window was computed only between Slack events; Linear/
///     GitHub either disconnected or silent for the whole period; [] = nobody at all)
///
/// Metadata only — no user content (only timestamps + source bucket).
struct GetUninterruptedWindowTool: ToolExecutor {
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
            name: "get_uninterrupted_window",
            description: "Return the longest uninterrupted window (gap with no Linear/GitHub/Slack activity) within the given period — proxy for deep async work session free of integration interruptions. Metadata only.",
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
        let window = try insights.longestUninterruptedWindow(period: interval)

        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end)
        ]
        if let win = window {
            payload["start"] = iso.string(from: win.start)
            payload["end"] = iso.string(from: win.end)
            payload["durationSeconds"] = win.durationSeconds
            payload["sourcesActive"] = win.sourcesActiveInPeriod
        }
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
