import Foundation
import LeafCore
import LeafMCPProtocol

/// MCP tool: return the last attention event, optionally filtered
/// by `bundle_id`. Helps AI clients answer questions like
/// "when did I last work with Xcode?".
struct FindLastActivityTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "bundle_id": [
                    "type": "string",
                    "description": "Optional macOS bundle identifier (e.g. com.apple.Xcode). If omitted — return globally last attention event."
                ]
            ],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "find_last_activity",
            description: "Return timestamp of last attention event for an app (or globally if bundle_id omitted). Local-only data — never leaves the device.",
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        let bundleFilter: String?
        if let dict = arguments?.value as? [String: Any] {
            if let raw = dict["bundle_id"] {
                guard let str = raw as? String, !str.isEmpty else {
                    throw MCPProtocolError.invalidParams("bundle_id must be a non-empty string")
                }
                bundleFilter = str
            } else {
                bundleFilter = nil
            }
        } else {
            bundleFilter = nil
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
        let snapshot = try insights.lastActivity(bundleID: bundleFilter)

        let iso = ISO8601DateFormatter()
        let now = Date()
        var payload: [String: Any] = [
            "found": snapshot != nil
        ]
        if let bf = bundleFilter {
            payload["filter"] = bf
        }
        if let s = snapshot {
            payload["bundleID"] = s.bundleID
            payload["displayName"] = AppNameResolver.shared.displayName(for: s.bundleID)
            payload["lastSeenISO"] = iso.string(from: s.timestamp)
            payload["secondsAgo"] = Int(now.timeIntervalSince(s.timestamp))
        }
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
