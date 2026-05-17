//
//  ActivityFeedMapper+AI.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.4) — AI collaboration event_kind mapping
//  (Claude Code retroactive + 16 visible kinds). Pure relocation from
//  ActivityFeedMapper.swift; ADR-010 redaction discipline preserved
//  (allowlisted payload fields only).
//

import Foundation

extension ActivityFeedMapper {
    // MARK: - AI collaboration

    // Cyclomatic from per-event_kind enum-style mapping (16 Claude Code
    // kinds + cross-tool variants). Switch остаётся canonical form —
    // table-driven dispatch перепишет vendor-specific payload extractors на
    // closures без выигрыша в читаемости (каждый case несёт уникальную
    // payload-shape логику).
    // swiftlint:disable:next cyclomatic_complexity
    static func mapAI(
        id: Int64,
        timestamp: Date,
        bundleID: String?,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let kind = payload["event_kind"] ?? "ai_activity"
        let primary: String
        var secondary: String? = nil

        // ADR-010 redaction discipline. Only the allowlisted payload fields
        // below may flow into primaryText / secondaryText. Forbidden fields
        // — `command`, `tool_input.*`, `tool_response.*`, `content`,
        // `thinking`, `signature`, `prompt`, `url`, `arguments`,
        // `old_string`, `new_string` — must never be read here. Parsers
        // (Tasks 8-11) enforce the same walkback before writing rows.
        switch kind {
        // Retroactive (pre-P1 kinds — survive for back-compat with rows
        // already in the local SQLCipher store before Track-6 P1 lands).
        case "tool_use":
            primary = sanitize(payload["tool_name"]).map { "Claude: \($0)" } ?? "Claude: tool"
            if let path = sanitize(payload["file_path"]) {
                secondary = basename(of: path)
            } else if let cwd = sanitize(payload["cwd"]) {
                secondary = basename(of: cwd)
            }

        case "user_prompt":
            primary = "Claude: prompt"
            if let cwd = sanitize(payload["cwd"]) {
                secondary = basename(of: cwd)
            }

        // Session lifecycle (4 of 5 — `claude_turn_ended` is in skippedKinds)
        case "claude_session_started":
            let source = sanitize(payload["source_enum"]) ?? sanitize(payload["source"]) ?? "started"
            primary = "Claude session: \(source)"
            secondary = sanitize(payload["model"]).map { "model: \($0)" }

        case "claude_session_ended":
            let reason = sanitize(payload["reason"]) ?? "ended"
            primary = "Claude session ended: \(reason)"
            secondary = sanitize(payload["duration_seconds"]).map { "\($0)s" }

        case "claude_session_compacted":
            let trigger = sanitize(payload["trigger"]) ?? "compact"
            primary = "Claude session compacted (\(trigger))"

        case "claude_prompt_submitted":
            primary = "Claude: prompt submitted"
            secondary = sanitize(payload["prompt_length_chars"]).map { "\($0) chars" }

        // Per-tool (8)
        case "claude_bash_executed":
            primary = "Claude: Bash"
            let chars = sanitize(payload["command_length_chars"]).map { "\($0) chars" }
            let dur = sanitize(payload["duration_ms"]).map { "\($0)ms" }
            let joined = [chars, dur].compactMap { $0 }.joined(separator: " · ")
            secondary = joined.isEmpty ? nil : joined

        case "claude_file_edited":
            let file = sanitize(payload["file_path"]).map(basename(of:)) ?? "file"
            primary = "Claude: edited \(file)"
            let added = sanitize(payload["bytes_added"]) ?? "0"
            let removed = sanitize(payload["bytes_removed"]) ?? "0"
            secondary = "+\(added) / -\(removed) bytes"

        case "claude_file_written":
            let file = sanitize(payload["file_path"]).map(basename(of:)) ?? "file"
            primary = "Claude: wrote \(file)"
            secondary = sanitize(payload["byte_count"]).map { "\($0) bytes" }

        case "claude_file_read":
            let file = sanitize(payload["file_path"]).map(basename(of:)) ?? "file"
            primary = "Claude: read \(file)"
            secondary = sanitize(payload["line_range_count"]).map { "\($0) lines" }

        case "claude_web_fetched":
            let tool = sanitize(payload["tool_name"]) ?? "WebFetch"
            primary = "Claude: \(tool)"
            secondary = sanitize(payload["domain"])

        case "claude_subagent_dispatched":
            let agentType = sanitize(payload["subagent_type"]) ?? "subagent"
            primary = "Claude: dispatched \(agentType)"
            secondary = sanitize(payload["description"])

        case "claude_mcp_tool_invoked":
            let server = sanitize(payload["mcp_server"]) ?? "mcp"
            let tool = sanitize(payload["mcp_tool"]) ?? "tool"
            primary = "Claude MCP: \(server) · \(tool)"

        case "claude_slash_command_invoked":
            let cmd = sanitize(payload["command_name"]) ?? "/?"
            primary = "Claude: \(cmd)"

        default:
            // Forward-compat: unknown AI kind (future Cursor / Windsurf /
            // Continue.dev) renders generically. DispatchCoverageTests fence
            // (`testEveryClaudeCodeEventKindKeyMappedOrSkipped`) ensures we
            // never silently land a Claude kind here.
            primary = sanitize(payload["tool_name"]) ?? sanitize(payload["agent"]) ?? "AI activity"
            secondary =
                sanitize(payload["file_path"]).map(basename(of:))
                ?? sanitize(payload["cwd"]).map(basename(of:))
        }

        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .ai,
            eventKind: kind,
            primaryText: primary,
            secondaryText: secondary,
            bundleID: bundleID
        )
    }
}
