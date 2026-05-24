import Foundation

/// Pure mapping from `event_kind` → SF Symbol name. UI-target consumers
/// (`ActivityRow`) read from here so the logic stays unit-testable from
/// LeafCore. Phase Track-4 S4 — added per-event-kind dispatch for the 33
/// visible LocalOS kinds landed by S1+S2+S3. Pairs (entered/exited,
/// connected/disconnected, locked/unlocked) intentionally share a symbol;
/// copy strings in `ActivityFeedMapper.mapLocalOS` disambiguate.
/// Track-6 P1 — added 14 visible Claude Code kinds (2 retroactive +
/// 12 new `claude_*`). The retroactive pair (`tool_use`, `user_prompt`)
/// shares "sparkles"; each of the 12 new `claude_*` cases gets a distinct
/// semantic symbol. Copy strings in `ActivityFeedMapper.mapAI` disambiguate
/// the shared `sparkles` pair.
public enum EventKindIcon {
    /// Returns SF Symbol name for the given event_kind. `nil` means the
    /// caller should fall through to its provider-level default.
    public static func symbol(for eventKind: String) -> String? {
        switch eventKind {
        // Track-4 S1 — system state
        case "meeting_state_entered", "meeting_state_exited": return "person.wave.2"
        case "focus_mode_enabled", "focus_mode_disabled":     return "moon.fill"
        case "system_locked", "system_unlocked":              return "lock.fill"
        case "system_slept", "system_woke":                   return "powersleep"
        case "space_switched":                                return "square.grid.2x2"

        // Track-4 S2 — IDE / media / productivity / Zoom / browsers
        case "xcode_active_doc_changed":      return "hammer.fill"
        case "xcode_build_state_changed":     return "hammer"

        // Track-6 P2 — Xcode Deep
        case "xcode_build_started":           return "hammer.circle"
        case "xcode_build_finished":          return "hammer.circle.fill"
        case "xcode_test_run_started":        return "checkmark.diamond"
        case "xcode_test_run_finished":       return "checkmark.diamond.fill"
        case "xcode_scheme_changed":          return "square.stack.3d.up"
        case "xcode_run_destination_changed": return "display"

        case "jetbrains_active_doc_changed":  return "chevron.left.forwardslash.chevron.right"
        case "music_track_changed":           return "music.note"
        case "spotify_track_changed":         return "music.note.list"
        case "notes_active_title_changed":    return "doc.richtext"
        case "reminder_completed":            return "checkmark.circle"
        case "calendar_app_view_changed":     return "calendar"
        case "mail_active_mailbox_changed":   return "envelope"
        case "zoom_meeting_state_changed",
             "zoom_meeting_name_observed":    return "video.circle"
        // Track-6 P5 — Zoom Deep (duration + calendar cross-link).
        case "zoom_meeting_started":          return "video.fill"
        case "zoom_meeting_ended":            return "video.slash"
        case "zoom_meeting_calendar_linked":  return "link.circle"
        case "safari_tabs_changed":           return "safari"
        case "chrome_tabs_changed":           return "globe"
        case "arc_tabs_changed":              return "globe.americas"

        // Track-6 P3 — browser deep (navigated + activated + bookmarks)
        case "safari_tab_navigated",
             "safari_tab_activated":          return "safari"
        case "chrome_tab_navigated",
             "chrome_tab_activated":          return "globe"
        case "arc_tab_navigated",
             "arc_tab_activated":             return "globe.americas"
        case "chrome_bookmark_changed":       return "bookmark"
        case "safari_bookmark_changed":       return "bookmark.fill"

        // Track-4 S3 — audio / display / network / files
        case "audio_route_changed":                       return "speaker.wave.2"
        case "mic_in_use_entered", "mic_in_use_exited":   return "mic.fill"
        case "display_connected", "display_disconnected": return "display"
        case "vpn_state_changed":                         return "shield.lefthalf.filled"
        case "wifi_state_changed":                        return "wifi"
        case "screenshot_taken":                          return "camera.viewfinder"
        case "download_added":                            return "arrow.down.circle"
        case "trash_changed":                             return "trash"

        // Track-6 P1 — Claude Code (14 visible kinds; claude_tokens_used + claude_turn_ended skipped per skippedKinds)
        case "tool_use", "user_prompt":       return "sparkles"
        case "claude_session_started":        return "play.circle"
        case "claude_session_ended":          return "stop.circle"
        case "claude_session_compacted":      return "rectangle.compress.vertical"
        case "claude_prompt_submitted":       return "text.bubble"
        case "claude_bash_executed":          return "terminal"
        case "claude_file_edited":            return "pencil.line"
        case "claude_file_written":           return "doc.badge.plus"
        case "claude_file_read":              return "doc.text.magnifyingglass"
        case "claude_web_fetched":            return "globe"
        case "claude_subagent_dispatched":    return "person.2.circle"
        case "claude_mcp_tool_invoked":       return "plug.circle"
        case "claude_slash_command_invoked":  return "slash.circle"

        default: return nil
        }
    }
}
