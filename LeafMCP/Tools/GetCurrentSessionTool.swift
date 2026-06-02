import Foundation
import LeafCore
import LeafMCPProtocol

/// MCP tool: return the user's current (live) session if they have been active
/// within `focusSessionGapSec`, plus the last completed session as context.
/// Unified shape — the consumer (Claude) does not branch on `active`, it always
/// reads the same keys.
struct GetCurrentSessionTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?
    /// "Live" threshold — when the gap to the last attention event is below this value
    /// → the session is open. Injected from MCPServer.swift (single source of truth
    /// — moat config or weakDefaults depending on LEAF_PROD).
    let focusSessionGapSec: TimeInterval

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [:],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "get_current_session",
            description: "Return user's currently-active session (if any) plus the most recent completed session for context. Both nullable — single unified response shape.",
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments _: AnyCodable?) async throws -> ToolCallResult {
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

        // Period: the last 24h. Enough to capture today's and yesterday's
        // activity; no point going wider — `currentSession` is determined by
        // recency, `lastSession` is the most recent one in the window.
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

        // currentSession: the most recent one if live; otherwise null.
        // lastSession: the most recent session in the window (even if the live one
        // is the same — we expose it both as currentSession and as lastSession; for
        // "what came before this" we need the second from the end, so we take the
        // second-to-last).
        let mostRecent = sessions.last
        let secondMostRecent = sessions.count >= 2 ? sessions[sessions.count - 2] : nil

        var payload: [String: Any] = [
            "active": isActive,
            "currentSession": NSNull(),
            "lastSession": NSNull()
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
            "appCount": s.appCount
        ]
        if includeEnd {
            p["end"] = iso.string(from: s.end)
        }
        return p
    }
}
