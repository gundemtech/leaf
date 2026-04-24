import Foundation
import LeafCore
import LeafMCPProtocol

/// Периоды, принимаемые `get_timeline`. Nonisolated т.к. project default —
/// MainActor isolation; `interval(...)` вызывается из `actor StdioTransport`.
nonisolated enum TimelinePeriod: String, Codable {
    case today = "today"
    case yesterday = "yesterday"
    case last7Days = "last_7_days"

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)
        case .yesterday:
            let todayStart = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return DateInterval(start: start, end: todayStart)
        case .last7Days:
            let end = now
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
            return DateInterval(start: start, end: end)
        }
    }
}

struct GetTimelineTool: ToolExecutor {
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
            name: "get_timeline",
            description: "Return top applications by active time for the given period. Data comes from the local Leaf agent — raw metadata never leaves the device.",
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
        let entries = try insights.timeInApp(period: interval)

        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "entries": entries.map { entry -> [String: Any] in
                [
                    "bundleID": entry.bundleID,
                    "durationSec": Int(entry.duration),
                    "firstSeen": iso.string(from: entry.firstSeen),
                    "lastSeen": iso.string(from: entry.lastSeen)
                ]
            }
        ]
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
