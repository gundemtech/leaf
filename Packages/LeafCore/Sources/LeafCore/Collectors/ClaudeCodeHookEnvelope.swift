import Foundation

/// Track-6 P1 — envelope written to `~/Library/Application Support/Leaf/hooks.sock`
/// by `leaf-hook-bridge`. Read line-delimited by `ClaudeCodeHookSocketListener`
/// (LeafCorePrivate). The struct itself is public so test fixtures and
/// listener-handler signatures live in LeafCore; payload parsing semantics
/// live in LeafCorePrivate.
public struct HookEnvelope: Sendable, Equatable {
    /// Hook event name (PreToolUse / PostToolUse / UserPromptSubmit / SessionEnd / PreCompact / ...).
    public let eventName: String
    /// Raw JSON string from Claude Code stdin — parsed by ClaudeCodeHookParser.
    public let payloadJSON: String
    /// Wall-clock ms-since-epoch the bridge timestamped the envelope.
    public let tsMs: Int64

    public init(eventName: String, payloadJSON: String, tsMs: Int64) {
        self.eventName = eventName
        self.payloadJSON = payloadJSON
        self.tsMs = tsMs
    }
}
