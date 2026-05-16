import Foundation

/// Track-6 P1 — Claude Code Deep event_kind discriminators.
/// rawValue must match `events.payload_json.event_kind` and the corresponding
/// `ShareEventTypeKey` rawValue 1-1 — single string identity across registry,
/// runtime emission, downstream SQL.
public enum ClaudeCodeEventKindKey: String, CaseIterable, Sendable, Hashable {
    // MARK: - Retroactive
    // Retroactive (existed pre-P1; share-key not previously enforced).
    // rawValues lack `claude_` prefix the rest of the block carries — the
    // matching ShareEventTypeKey Swift identifier uses `claudeCode*` form
    // to guard against future cross-provider collisions.
    case toolUse = "tool_use"
    case userPrompt = "user_prompt"

    // MARK: - Session lifecycle
    case sessionStarted = "claude_session_started"
    case sessionEnded = "claude_session_ended"
    case sessionCompacted = "claude_session_compacted"
    case promptSubmitted = "claude_prompt_submitted"
    case turnEnded = "claude_turn_ended"

    // MARK: - Token attribution
    case tokensUsed = "claude_tokens_used"

    // MARK: - Per-tool
    case bashExecuted = "claude_bash_executed"
    case fileEdited = "claude_file_edited"
    case fileWritten = "claude_file_written"
    case fileRead = "claude_file_read"
    case webFetched = "claude_web_fetched"
    case subagentDispatched = "claude_subagent_dispatched"
    case mcpToolInvoked = "claude_mcp_tool_invoked"
    case slashCommandInvoked = "claude_slash_command_invoked"
}
