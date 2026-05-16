import Foundation

/// Pure mapping from `event_kind` → SF Symbol name. UI-target consumers
/// (`ActivityRow`) read from here so the logic stays unit-testable from
/// LeafCore. Phase Track-4 S4 — added per-event-kind dispatch for the 33
/// visible LocalOS kinds landed by S1+S2+S3. Pairs (entered/exited,
/// connected/disconnected, locked/unlocked) intentionally share a symbol;
/// copy strings in `ActivityFeedMapper.mapLocalOS` disambiguate.
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

        // Track-4 S3 — audio / display / network / files
        case "audio_route_changed":                       return "speaker.wave.2"
        case "mic_in_use_entered", "mic_in_use_exited":   return "mic.fill"
        case "display_connected", "display_disconnected": return "display"
        case "vpn_state_changed":                         return "shield.lefthalf.filled"
        case "wifi_state_changed":                        return "wifi"
        case "screenshot_taken":                          return "camera.viewfinder"
        case "download_added":                            return "arrow.down.circle"
        case "trash_changed":                             return "trash"

        default: return nil
        }
    }
}
