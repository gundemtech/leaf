import Foundation

/// Direct stderr writes — `os.Logger` роутит в unified log, невидим в
/// Claude Code's MCP debug output. MCP spec (stdio transport): stdout —
/// только MCP messages, stderr — любое логирование.
enum MCPLogLevel: String {
    case debug, info, warn, error
}

/// Namespace'd static методы. `nonisolated` явно, т.к. project default —
/// MainActor isolation (Swift 6.1 `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`),
/// а мы логируем из `actor StdioTransport` — без nonisolated каждый вызов
/// требовал бы `await`.
enum MCPLog {
    nonisolated static func log(_ level: MCPLogLevel, _ message: @autoclosure () -> String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(level.rawValue)] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    nonisolated static func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    nonisolated static func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    nonisolated static func warn(_ message: @autoclosure () -> String) { log(.warn, message()) }
    nonisolated static func error(_ message: @autoclosure () -> String) { log(.error, message()) }
}
