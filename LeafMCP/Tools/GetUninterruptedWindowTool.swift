import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.6.C.2 — MCP tool: longest gap (uninterrupted window) между Layer B
/// integration events (Linear/GitHub/Slack) внутри period'а. Proxy для "deep
/// async work session" — время непрерывной работы без notification-interruption
/// из tracked интеграций. Отличается от `get_current_session` (тот про
/// macOS-level focus session) — здесь только integration silence.
///
/// Output payload (versioned `version: 1` через `ToolResponseBuilder`):
///   - `period`, `from`, `to` — окно
///   - `start`, `end` — ISO timestamps окна (period bounds допустимы как anchors:
///     start может быть = period.start если первый event сильно позже,
///     end может быть = period.end если последний event сильно раньше)
///   - `durationSeconds` — длительность gap'а
///   - `sourcesActive[]` — sources с ≥1 event в period (honest signal:
///     ["slack"] значит окно считалось только между Slack events; Linear/
///     GitHub либо disconnected, либо silent весь период; [] = вообще никого)
///
/// Metadata only — никакого user content (только timestamps + source bucket).
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
