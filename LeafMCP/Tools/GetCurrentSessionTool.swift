import Foundation
import LeafCore
import LeafMCPProtocol

/// MCP-tool: вернуть текущую (live) сессию пользователя если он активен
/// в пределах `focusSessionGapSec`, плюс последнюю завершённую как контекст.
/// Unified shape — consumer (Claude) не ветвится на `active`, всегда читает
/// одни и те же ключи.
struct GetCurrentSessionTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?
    /// Threshold "live" — gap к последнему attention event ниже этого значения
    /// → сессия открыта. Инжектируется из MCPServer.swift (single source of truth
    /// — moat config или weakDefaults в зависимости от LEAF_PROD).
    let focusSessionGapSec: TimeInterval

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ]
        return ToolDefinition(
            name: "get_current_session",
            description:
                "Return user's currently-active session (if any) plus the most recent completed session for context. Both nullable — single unified response shape.",
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments _: AnyCodable?) async throws -> ToolCallResult {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return ToolCallResult(
                content: [
                    .text(
                        TextContent(
                            text:
                                "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first."
                        ))
                ],
                isError: true
            )
        }

        let database = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        let insights = DerivedInsightsFactory.make(database: database)

        // Period: последние 24h. Хватает чтобы захватить сегодняшнюю и вчерашнюю
        // активность; не имеет смысла шире — `currentSession` определяется
        // recency, `lastSession` — самая последняя в окне.
        let now = Date()
        let period = DateInterval(start: now.addingTimeInterval(-86_400), end: now)

        let sessions = try insights.focusSessions(period: period)
        let lastActivity = try insights.lastActivity(bundleID: nil)

        let iso = ISO8601DateFormatter()
        let isActive: Bool
        if let la = lastActivity {
            isActive = now.timeIntervalSince(la.timestamp) < focusSessionGapSec
        } else {
            isActive = false
        }

        // currentSession: самая последняя если live; иначе null.
        // lastSession: самая последняя session в окне (даже если live она же —
        // даём её и как currentSession и как lastSession для "что было перед этим"
        // нужен второй с конца — берём предпоследнюю).
        let mostRecent = sessions.last
        let secondMostRecent = sessions.count >= 2 ? sessions[sessions.count - 2] : nil

        var payload: [String: Any] = [
            "active": isActive,
            "currentSession": NSNull(),
            "lastSession": NSNull(),
        ]

        if isActive, let s = mostRecent {
            payload["currentSession"] = sessionPayload(s, iso: iso, includeEnd: false)
            if let prev = secondMostRecent {
                payload["lastSession"] = sessionPayload(prev, iso: iso, includeEnd: true)
            }
        } else if let s = mostRecent {
            payload["lastSession"] = sessionPayload(s, iso: iso, includeEnd: true)
        }

        return try ToolResponseBuilder.versionedJSONResult(payload)
    }

    private func sessionPayload(_ s: FocusSession, iso: ISO8601DateFormatter, includeEnd: Bool) -> [String: Any] {
        var p: [String: Any] = [
            "bundleID": s.bundleID,
            "displayName": AppNameResolver.shared.displayName(for: s.bundleID),
            "start": iso.string(from: s.start),
            "durationSec": Int(s.duration),
            "appCount": s.appCount,
        ]
        if includeEnd {
            p["end"] = iso.string(from: s.end)
        }
        return p
    }
}
