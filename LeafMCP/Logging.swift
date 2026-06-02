import Foundation

/// Direct stderr writes — `os.Logger` routes to the unified log, invisible in
/// Claude Code's MCP debug output. MCP spec (stdio transport): stdout — only
/// MCP messages, stderr — any logging.
enum MCPLogLevel: String {
    case debug, info, warn, error
}

/// Namespaced static methods. `nonisolated` explicitly, since the project default
/// is MainActor isolation (Swift 6.1 `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`),
/// but we log from `actor StdioTransport` — without nonisolated every call
/// would require `await`.
enum MCPLog {
    nonisolated static func log(_ level: MCPLogLevel, _ message: @autoclosure () -> String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(level.rawValue)] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    nonisolated static func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    nonisolated static func info(_ message: @autoclosure () -> String)  { log(.info,  message()) }
    nonisolated static func warn(_ message: @autoclosure () -> String)  { log(.warn,  message()) }
    nonisolated static func error(_ message: @autoclosure () -> String) { log(.error, message()) }
}
