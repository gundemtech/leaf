import Foundation

/// Pure stateless mapper from raw `events` rows to `ActivityFeedEntry` UI rows.
///
/// **ADR-010 redaction discipline.** This mapper is the *only* code path that
/// turns stored payload fields into user-visible strings in the feed. It
/// reads ONLY the explicit allowlist below — issue keys, status names, repo
/// names, channel names, counts, and self-authored titles already permitted
/// by `architecture.md` ("Action | self-authored labels | commit message,
/// issue title, branch name"). It must never read fields described as
/// "bodies" (comment text, message text, file previews, descriptions).
///
/// Rows whose `event_kind` represents a recurring state pulse (presence /
/// workload / queue counters that fire every tick) are returned as `nil` —
/// they belong on the Live Presence widget, not the chronological feed.
///
/// Phase 2.3.C.4 split — `mapAttention` lives in
/// `ActivityFeedMapper+Attention.swift`, `mapAI` in
/// `ActivityFeedMapper+AI.swift`, and `mapIntegration` + `mapLinear` +
/// `mapGitHub` + `mapSlack` + `mapGoogleCalendar` + the PR/issue formatters
/// in `ActivityFeedMapper+Integrations.swift`. `mapLocalOS` stays here as
/// the single audit point for `RelayBodyLeakageTests` privacy-walkback
/// grep.
public enum ActivityFeedMapper {
    /// Map a raw event row to a feed entry, or nil if the event is not
    /// worth surfacing (state pulse / unknown / malformed payload).
    public static func map(
        id: Int64,
        timestampMs: Int64,
        signalType: String,
        bundleID: String?,
        payloadJSON: String
    ) -> ActivityFeedEntry? {
        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        let payload = parsePayload(payloadJSON)
        let eventKind = payload["event_kind"] ?? ""

        // Track-4 S4 early dispatch — skip-list + LocalOS whitelist run before
        // signalType routing. Layer A events (S1+S2+S3) land под various signal
        // types без `payload["source"]` key, so signalType-based routing alone
        // would drop them or render without semantic copy.
        if Self.skippedKinds.contains(eventKind) { return nil }
        if Self.trackFourLocalOSKinds.contains(eventKind) {
            return mapLocalOS(id: id, timestamp: timestamp, bundleID: bundleID, kind: eventKind, payload: payload)
        }

        switch signalType {
        case "attention":
            return mapAttention(id: id, timestamp: timestamp, bundleID: bundleID, payload: payload)
        case "aiCollaboration":
            return mapAI(id: id, timestamp: timestamp, bundleID: bundleID, payload: payload)
        case "action", "context":
            return mapIntegration(id: id, timestamp: timestamp, bundleID: bundleID, payload: payload)
        default:
            return nil
        }
    }

    static func basename(of path: String) -> String {
        // Last path component without trailing slash.
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    // MARK: - Helpers

    /// Recurring state-snapshot event_kinds that flood the feed without
    /// representing a discrete user action. They're surfaced via the Live
    /// Presence widget instead.
    static let skippedKinds: Set<String> = [
        GitHubEventKindKey.notificationsPulse.rawValue,
        GitHubEventKindKey.prAwaitingReviewCount.rawValue,
        GitHubEventKindKey.myOpenPRCount.rawValue,
        GitHubEventKindKey.checkRunsStatus.rawValue,
        "slack_presence_state",
        "slack_dnd_state",
        "linear_assigned_workload_pulse",
        "linear_cycle_progress",
        // Track-4 S4 — high-cadence substrate metrics, not chronological events.
        // intensity_snapshot (per-minute aggregate когда intensity ON → 60/hour),
        // intensity_bucket_dropped (AFK debug marker), clipboard_event_count
        // (per-tick counter). Surfaced via Derived Insights Engine (Phase 4.9).
        "intensity_snapshot",
        "intensity_bucket_dropped",
        "clipboard_event_count",
        // Track-6 P1 — high-cadence AI kinds (per-turn flood when active session).
        // Both populate `events` rows for Phase 4.9 Derived Insights (token rollup,
        // turn-duration histogram); chronological feed suppresses them.
        "claude_tokens_used",
        "claude_turn_ended",
        // Track-6 P6 — debug-only signal. Surfaces only when user customizes
        // `window.title` in a vscode-family IDE such that the parser falls
        // through to fallback. Never renders in chronological feed.
        "ide_window_title_observed",
    ]

    /// Track-4 S1+S2+S3 Layer A event_kinds with explicit feed rendering.
    /// Membership = explicit whitelist; adding new kinds requires updating
    /// `mapLocalOS` switch. Must match `EventKindIcon.symbol` coverage
    /// (Track-4 S4 T3) — see `EventKindIconTests.testAllTrack4VisibleKindsMapped`.
    static let trackFourLocalOSKinds: Set<String> = [
        // S1 (9)
        "meeting_state_entered", "meeting_state_exited",
        "focus_mode_enabled", "focus_mode_disabled",
        "system_locked", "system_unlocked",
        "system_slept", "system_woke",
        "space_switched",
        // S2 (14)
        "xcode_active_doc_changed", "xcode_build_state_changed",
        // P2 — Xcode Deep
        "xcode_build_started", "xcode_build_finished",
        "xcode_test_run_started", "xcode_test_run_finished",
        "xcode_scheme_changed", "xcode_run_destination_changed",
        "jetbrains_active_doc_changed",
        "music_track_changed", "spotify_track_changed",
        "notes_active_title_changed", "reminder_completed",
        "calendar_app_view_changed", "mail_active_mailbox_changed",
        "zoom_meeting_state_changed", "zoom_meeting_name_observed",
        // Track-6 P5 — Zoom Deep (duration + calendar cross-link)
        "zoom_meeting_started", "zoom_meeting_ended", "zoom_meeting_calendar_linked",
        "safari_tabs_changed", "chrome_tabs_changed", "arc_tabs_changed",
        // P3 browser deep (8)
        "safari_tab_navigated", "chrome_tab_navigated", "arc_tab_navigated",
        "safari_tab_activated", "chrome_tab_activated", "arc_tab_activated",
        "chrome_bookmark_changed", "safari_bookmark_changed",
        // S3 (10 visible — 3 high-cadence kinds live in `skippedKinds`)
        "audio_route_changed",
        "mic_in_use_entered", "mic_in_use_exited",
        "display_connected", "display_disconnected",
        "vpn_state_changed", "wifi_state_changed",
        "screenshot_taken", "download_added",
        "trash_changed",
        // Track-6 P6 — IDE surface cap (3 visible; ide_window_title_observed
        // intentionally not in this whitelist — debug-only, never renders).
        "vscode_active_doc_changed",
        "vscode_workspace_opened",
        "jetbrains_recent_project_observed",
    ]

    /// Track-6 P1 — Claude Code AI event_kinds with explicit feed rendering.
    /// Membership = explicit whitelist; adding new kinds requires updating
    /// `mapAI` switch + `EventKindIcon.symbol`. DispatchCoverageTests fence
    /// (`testEveryClaudeCodeEventKindKeyMappedOrSkipped`) enforces parity:
    /// every `ClaudeCodeEventKindKey` case ∈ this set ∪ `skippedKinds`.
    /// Two cases (`claude_tokens_used`, `claude_turn_ended`) live in
    /// `skippedKinds` — per-turn flood; consumed by Live Presence + Phase 4.9.
    static let claudeCodeAIKinds: Set<String> = [
        // Retroactive (2)
        "tool_use", "user_prompt",
        // Session lifecycle (4 of 5 visible — turn_ended skipped)
        "claude_session_started", "claude_session_ended",
        "claude_session_compacted", "claude_prompt_submitted",
        // Per-tool (8)
        "claude_bash_executed", "claude_file_edited",
        "claude_file_written", "claude_file_read",
        "claude_web_fetched", "claude_subagent_dispatched",
        "claude_mcp_tool_invoked", "claude_slash_command_invoked",
    ]

    // MARK: - Track-4 Local OS (S1 + S2 + S3)

    // Per-event-kind copy mapping for Track-4 Layer A events. ADR-010 redaction
    // discipline: reads ONLY payload fields in the explicit allowlist below.
    // Bodies / message texts / file previews / note bodies never enter
    // primaryText/secondaryText, even if a future collector accidentally
    // stores them in the same payload row.
    //
    // Длинное тело + cyclomatic — 33+ Track-4 S1/S2/S3/S4 LocalOS event_kinds
    // + Track-6 P1-P6 additions (Claude / Xcode / IDEs / browsers / Zoom /
    // Google Calendar). Switch остаётся canonical form — ADR-010 allowlist
    // discipline видна inline per case (нельзя выносить в helpers, иначе
    // audit сложнее: privacy walkback tests grep'ают именно этот файл).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func mapLocalOS(
        id: Int64,
        timestamp: Date,
        bundleID: String?,
        kind: String,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let primary: String
        var secondary: String? = nil

        // Payload key names below are the canonical keys that landed collectors
        // (S1/S2/S3 state-machines + LocalFilesWatcher) actually emit. Cross-
        // referenced against `*StateMachine.swift` files + LocalFilesWatcher
        // + `Schema.EventPayloadKeys`. Do NOT rename — any change here must
        // be paired with collector + boundary-grep test updates.
        switch kind {
        // S1 — system state
        case "meeting_state_entered": primary = "Meeting started"
        case "meeting_state_exited": primary = "Meeting ended"
        case "focus_mode_enabled": primary = "Focus on"  // collector emits only "state"=focused
        case "focus_mode_disabled": primary = "Focus off"
        case "system_locked": primary = "Screen locked"
        case "system_unlocked": primary = "Screen unlocked"
        case "system_slept": primary = "System sleep"
        case "system_woke": primary = "System wake"
        case "space_switched": primary = "Space switched"

        // S2 — IDEs (XcodeStateMachine / JetBrainsStateMachine emit "doc_path")
        case "xcode_active_doc_changed":
            let base = sanitize(payload["doc_path"]).map(basename(of:)) ?? "—"
            primary = "Xcode: \(base)"
        case "xcode_build_state_changed":
            let state = sanitize(payload["build_state"]) ?? "?"
            primary = "Xcode: build \(state)"

        // Phase Track-6 P2 — Xcode Deep. ADR-010: ONLY allowlisted payload
        // fields (scheme / status / counts / bucket) — never raw device name,
        // error message, test method name, build log content.
        case "xcode_build_started":
            primary = "Xcode: build started"
            let scheme = sanitize(payload["scheme"])
            let bucket = sanitize(payload["run_destination_bucket"])
            let parts = [scheme, bucket].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { secondary = parts.joined(separator: " · ") }
        case "xcode_build_finished":
            let status = sanitize(payload["status"]) ?? "?"
            primary = "Xcode: build \(status)"
            let scheme = sanitize(payload["scheme"])
            let errors = sanitize(payload["error_count"]).flatMap(Int.init)
            let errStr: String? = if let errors, errors > 0 { "\(errors) errors" } else { nil }
            let parts = [scheme, errStr].compactMap { $0 }
            if !parts.isEmpty { secondary = parts.joined(separator: " · ") }
        case "xcode_test_run_started":
            primary = "Xcode: tests started"
            secondary = sanitize(payload["scheme"])
        case "xcode_test_run_finished":
            let status = sanitize(payload["status"]) ?? "?"
            primary = "Xcode: tests \(status)"
            let p = sanitize(payload["passed_count"]) ?? "0"
            let f = sanitize(payload["failed_count"]) ?? "0"
            secondary = "\(p) passed, \(f) failed"
        case "xcode_scheme_changed":
            let sch = sanitize(payload["scheme"]) ?? "?"
            primary = "Xcode: scheme \(sch)"
            secondary = sanitize(payload["project"])
        case "xcode_run_destination_changed":
            let b = sanitize(payload["run_destination_bucket"]) ?? "?"
            primary = "Xcode: target \(b)"

        case "jetbrains_active_doc_changed":
            let base = sanitize(payload["doc_path"]).map(basename(of:)) ?? "—"
            primary = "JetBrains: \(base)"

        // S2 — media (Music/SpotifyStateMachine emit "track" + "artist")
        case "music_track_changed":
            primary = "Music: \(sanitize(payload["track"]) ?? "—")"
            secondary = sanitize(payload["artist"])
        case "spotify_track_changed":
            primary = "Spotify: \(sanitize(payload["track"]) ?? "—")"
            secondary = sanitize(payload["artist"])

        // S2 — productivity
        case "notes_active_title_changed":
            primary = "Notes: \(sanitize(payload["note_title"]) ?? "—")"
        case "reminder_completed":
            // RemindersStateMachine emits "completed_count_delta" (positive int as String).
            let count = sanitize(payload["completed_count_delta"]) ?? "1"
            primary = "Reminders completed: \(count)"
        case "calendar_app_view_changed":
            // CalendarAppStateMachine emits "view_mode".
            primary = "Calendar: \(sanitize(payload["view_mode"]) ?? "—") view"
        case "mail_active_mailbox_changed":
            // MailStateMachine emits "mailbox_name" (Schema.EventPayloadKeys.mailboxName).
            primary = "Mail: \(sanitize(payload["mailbox_name"]) ?? "—")"

        // S2 — Zoom
        case "zoom_meeting_state_changed":
            let state = sanitize(payload["meeting_state"]) ?? "?"
            primary = "Zoom: \(state.replacingOccurrences(of: "_", with: " "))"
        case "zoom_meeting_name_observed":
            primary = "Zoom: \(sanitize(payload["meeting_topic"]) ?? "—")"

        // Track-6 P5 — Zoom Deep (duration + calendar cross-link).
        // ADR-010 redaction: NO meeting_topic / participant_count / share_content /
        // chat / recording / raw_url read here — only opaque counter + cold-start flag.
        case "zoom_meeting_started":
            let coldStart = (payload["cold_start"] ?? "false") == "true"
            primary = coldStart ? "Zoom meeting (already in progress)" : "Zoom meeting started"
        case "zoom_meeting_ended":
            let duration = Int(payload["duration_seconds"] ?? "0") ?? 0
            primary = "Zoom meeting ended"
            secondary = "Duration: \(Self.formatDurationCompact(duration))"
        case "zoom_meeting_calendar_linked":
            primary = "Zoom meeting linked to calendar"

        // S2 — browser tabs (Safari/Chrome/ArcStateMachine emit JSON array under "tabs";
        // count derived structurally — no URL / title strings enter primaryText).
        case "safari_tabs_changed":
            primary = "Safari: \(tabsCount(payload["tabs"]) ?? "?") tabs"
        case "chrome_tabs_changed":
            primary = "Chrome: \(tabsCount(payload["tabs"]) ?? "?") tabs"
        case "arc_tabs_changed":
            primary = "Arc: \(tabsCount(payload["tabs"]) ?? "?") tabs"

        // P3 — browser deep (navigated + activated + bookmarks)
        // BrowserStateMachine emits "current_url" (sanitized — protocol+host+path only,
        // no query/fragment — per Track-6 P3 collector contract).
        case "safari_tab_navigated":
            primary = "Safari: \(sanitize(payload["current_url"]) ?? "?")"
            secondary = "navigated"
        case "chrome_tab_navigated":
            primary = "Chrome: \(sanitize(payload["current_url"]) ?? "?")"
            secondary = "navigated"
        case "arc_tab_navigated":
            primary = "Arc: \(sanitize(payload["current_url"]) ?? "?")"
            secondary = "navigated"
        case "safari_tab_activated":
            primary = "Safari: \(sanitize(payload["current_url"]) ?? "?")"
            secondary = "tab activated"
        case "chrome_tab_activated":
            primary = "Chrome: \(sanitize(payload["current_url"]) ?? "?")"
            secondary = "tab activated"
        case "arc_tab_activated":
            primary = "Arc: \(sanitize(payload["current_url"]) ?? "?")"
            secondary = "tab activated"
        // Bookmark collectors emit "delta" (signed int) + "total_count" (int).
        // URL / title strings are never emitted — structural count only (ADR-010).
        case "chrome_bookmark_changed":
            let delta = Int(payload["delta"] ?? "0") ?? 0
            let total = sanitize(payload["total_count"]) ?? "?"
            primary = "Chrome bookmarks: \(Self.deltaText(delta)) (\(total) total)"
        case "safari_bookmark_changed":
            let delta = Int(payload["delta"] ?? "0") ?? 0
            let total = sanitize(payload["total_count"]) ?? "?"
            primary = "Safari bookmarks: \(Self.deltaText(delta)) (\(total) total)"

        // S3 — audio / mic (AudioRouteCollector emits "audio_route" enum value)
        case "audio_route_changed":
            primary = "Audio route: \(sanitize(payload["audio_route"]) ?? "—")"
        case "mic_in_use_entered": primary = "Mic on"
        case "mic_in_use_exited": primary = "Mic off"

        // S3 — display (DisplayCollector emits only "state" — no count field).
        case "display_connected": primary = "Display connected"
        case "display_disconnected": primary = "Display disconnected"

        // S3 — network (VPN/WiFi collectors emit "state"=connected|disconnected)
        case "vpn_state_changed":
            primary = "VPN: \(sanitize(payload["state"]) ?? "—")"
        case "wifi_state_changed":
            primary = "Wi-Fi: \(sanitize(payload["state"]) ?? "—")"

        // S3 — files
        case "screenshot_taken":
            primary = "Screenshot: \(sanitize(payload["filename"]) ?? "—")"
        case "download_added":
            primary = "Download: \(sanitize(payload["filename"]) ?? "—")"
        case "trash_changed":
            let action = sanitize(payload["action"]) ?? "?"
            switch action {
            case "emptied": primary = "Trash emptied"
            case "added": primary = "Trash items added"
            default: primary = "Trash: \(action)"
            }

        // Track-6 P6 — IDE surface cap
        // VSCodeFamilyDispatcher emits `workspace_name` + `file_basename` +
        // `ide_bundle_id`. App name is derived per fork via vscodeAppName(forBundleID:).
        // ADR-010: only workspace_name and file_basename are allowed — no file path,
        // no editor content, no full workspace path.
        case "vscode_active_doc_changed":
            let appName = vscodeAppName(forBundleID: payload["ide_bundle_id"] ?? bundleID)
            let workspace = sanitize(payload["workspace_name"])
            let file = sanitize(payload["file_basename"])
            switch (workspace, file) {
            case (let w?, let f?): primary = "\(appName): \(w) — \(f)"
            case (nil, let f?): primary = "\(appName): \(f)"
            case (let w?, nil): primary = "\(appName): \(w)"
            case (nil, nil): primary = "\(appName): —"
            }
        case "vscode_workspace_opened":
            primary = "Opened workspace: \(sanitize(payload["workspace_name"]) ?? "—")"
        case "jetbrains_recent_project_observed":
            // JetBrainsRecentProjectsWatcher emits `project_name` + `ide_version_dir`.
            primary = "JetBrains: \(sanitize(payload["project_name"]) ?? "—")"
            secondary = sanitize(payload["ide_version_dir"])

        default:
            return nil
        }

        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .local,
            eventKind: kind,
            primaryText: primary,
            secondaryText: secondary,
            bundleID: bundleID
        )
    }


    static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 200 {
            return String(trimmed.prefix(200)) + "…"
        }
        return trimmed
    }

    /// Track-6 P5 — compact duration formatter for `zoom_meeting_ended` rows.
    /// Pure structural derivation from a non-negative integer second count;
    /// reads no payload strings (ADR-010-safe by construction).
    ///   < 60s    → "<N>s"
    ///   < 60min  → "<N>m"
    ///   ≥ 60min  → "<H>h <M>m"  (M omitted when 0; e.g. "2h" not "2h 0m")
    static func formatDurationCompact(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMin = minutes % 60
        return remMin == 0 ? "\(hours)h" : "\(hours)h \(remMin)m"
    }

    /// Derives the tab count from a `"tabs"` JSON array payload field.
    /// Returns `nil` on missing / unparseable payload — caller renders "?".
    /// Counts array length only; never reads individual `url` / `title`
    /// strings, so ADR-010 redaction is preserved (structural cardinality).
    private static func tabsCount(_ raw: String?) -> String? {
        guard let raw,
            let data = raw.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return String(array.count)
    }

    /// Formats a signed integer bookmark delta as "+N", "−N", or "updated" (zero).
    private static func deltaText(_ delta: Int) -> String {
        if delta > 0 { return "+\(delta)" }
        if delta < 0 { return "\(delta)" }
        return "updated"
    }

    /// Track-6 P6 — bundle-ID → user-facing app name for Activity rows.
    /// Falls back to "VSCode" for any unrecognized vscode-family bundle.
    private static func vscodeAppName(forBundleID bundleID: String?) -> String {
        switch bundleID {
        case "com.microsoft.VSCode": return "VSCode"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.microsoft.VSCodeInsiders": return "VSCode Insiders"
        case "com.visualstudio.code.oss": return "VSCodium"
        default: return "VSCode"
        }
    }

    private static func parsePayload(_ json: String) -> [String: String] {
        guard !json.isEmpty,
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in obj {
            if let s = value as? String {
                result[key] = s
            } else if let n = value as? NSNumber {
                result[key] = n.stringValue
            } else if let b = value as? Bool {
                result[key] = b ? "true" : "false"
            }
        }
        return result
    }
}
