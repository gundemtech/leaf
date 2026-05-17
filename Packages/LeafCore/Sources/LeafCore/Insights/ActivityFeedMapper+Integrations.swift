//
//  ActivityFeedMapper+Integrations.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.4) — Linear / GitHub / Slack / Google
//  Calendar event_kind mapping + PR / issue ref formatters. Pure
//  relocation from ActivityFeedMapper.swift; ADR-010 redaction discipline
//  preserved (allowlisted payload fields only).
//

import Foundation

extension ActivityFeedMapper {
    // MARK: - Integrations (Linear / GitHub / Slack)

    static func mapIntegration(
        id: Int64,
        timestamp: Date,
        bundleID: String?,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let source = payload["source"] ?? ""
        let kind = payload["event_kind"] ?? ""
        if Self.skippedKinds.contains(kind) { return nil }

        switch source {
        case "linear":
            return mapLinear(id: id, timestamp: timestamp, kind: kind, payload: payload)
        case "github":
            return mapGitHub(id: id, timestamp: timestamp, kind: kind, payload: payload)
        case "slack":
            return mapSlack(id: id, timestamp: timestamp, kind: kind, payload: payload)
        case "google_calendar":
            return mapGoogleCalendar(id: id, timestamp: timestamp, kind: kind, payload: payload)
        default:
            return nil
        }
    }

    // MARK: - Linear

    // Cyclomatic from per-event_kind enum-style mapping (Linear event
    // flavors: issue_updated / linear_status_transition / linear_priority /
    // labels / assignee / cycle / estimate / project_update / document /
    // initiative / comment). Switch остаётся canonical form.
    // swiftlint:disable:next cyclomatic_complexity
    static func mapLinear(
        id: Int64,
        timestamp: Date,
        kind: String,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let issueKey = sanitize(payload["issue_key"])
        let project = sanitize(payload["project"])
        let status = sanitize(payload["status"])
        let team = sanitize(payload["team_key"])

        let primary: String
        var secondary: String? = nil

        switch kind {
        case "issue_updated":
            guard let issueKey else { return nil }
            primary = status.map { "\(issueKey) · \($0)" } ?? issueKey
            secondary = project ?? team
        case "status_transition":
            guard let issueKey else { return nil }
            let to = sanitize(payload["to_state_name"]) ?? "?"
            primary = "\(issueKey) → \(to)"
            if let from = sanitize(payload["from_state_name"]) {
                secondary = "from \(from)"
            }
        case "linear_priority_changed":
            guard let issueKey else { return nil }
            let to = sanitize(payload["to_priority"]) ?? "?"
            primary = "\(issueKey): priority → \(to)"
            secondary = sanitize(payload["from_priority"]).map { "from \($0)" }
        case "linear_label_added":
            guard let issueKey, let label = sanitize(payload["label_name"]) else { return nil }
            primary = "\(issueKey) +\(label)"
        case "linear_label_removed":
            guard let issueKey, let label = sanitize(payload["label_name"]) else { return nil }
            primary = "\(issueKey) −\(label)"
        case "linear_assignee_changed":
            guard let issueKey else { return nil }
            let bucket = sanitize(payload["bucket"]) ?? "?"
            primary = "\(issueKey) → assigned to \(bucket)"
        case "linear_cycle_changed":
            guard let issueKey else { return nil }
            let to = sanitize(payload["to_cycle_name"]) ?? "—"
            primary = "\(issueKey): cycle → \(to)"
            secondary = sanitize(payload["from_cycle_name"]).map { "from \($0)" }
        case "linear_estimate_changed":
            guard let issueKey else { return nil }
            let to = sanitize(payload["to_estimate"]) ?? "—"
            primary = "\(issueKey): estimate → \(to)"
        case "linear_comment_authored":
            guard let issueKey else { return nil }
            let count = sanitize(payload["count_in_window"]) ?? "1"
            primary = "\(issueKey): \(count) comment\(count == "1" ? "" : "s")"
            secondary = team
        case "linear_document_edited":
            // ADR-010: document title is self-authored — surfacing allowed,
            // matches "issue title" allowance.
            primary = "Document edited"
            secondary = sanitize(payload["project_name"])
        case "linear_project_update_authored":
            primary = "Project update"
            if let project = sanitize(payload["project_name"]) {
                secondary = project
                if let health = sanitize(payload["health"]) {
                    secondary = "\(project) · \(health)"
                }
            }
        case "linear_initiative_observed":
            // Self-authored initiative name — allowed.
            primary = "Initiative observed"
            secondary = sanitize(payload["status"])
        default:
            return nil
        }

        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .linear,
            eventKind: kind.isEmpty ? "linear_event" : kind,
            primaryText: primary,
            secondaryText: secondary,
            bundleID: nil
        )
    }

    // MARK: - GitHub

    // Cyclomatic from per-event_kind enum-style mapping (~30 gh_* flavors:
    // commit_pushed / pr_opened/merged/closed / issue_* / review_* /
    // release / discussion / actions_run / notifications_pulse / etc).
    // swiftlint:disable:next cyclomatic_complexity
    static func mapGitHub(
        id: Int64,
        timestamp: Date,
        kind: String,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let repo = sanitize(payload["repo"])
        let number = sanitize(payload["number"])
        let branch = sanitize(payload["branch"])
        let sha = sanitize(payload["sha"]).map { String($0.prefix(7)) }

        let primary: String
        var secondary: String? = nil

        switch kind {
        case GitHubEventKindKey.commitPushed.rawValue:
            guard let repo else { return nil }
            primary = branch.map { "\(repo): pushed to \($0)" } ?? "\(repo): pushed"
            secondary = sha
        case GitHubEventKindKey.prOpened.rawValue:
            primary = formatPR(repo: repo, number: number, suffix: "opened")
            secondary = nil
        case GitHubEventKindKey.prClosed.rawValue:
            primary = formatPR(repo: repo, number: number, suffix: "closed")
        case GitHubEventKindKey.prMerged.rawValue:
            primary = formatPR(repo: repo, number: number, suffix: "merged")
        case GitHubEventKindKey.prReviewCommentAuthored.rawValue:
            primary = formatPR(repo: repo, number: number, suffix: "review comment")
        case GitHubEventKindKey.prReviewThreadResolved.rawValue:
            primary = formatPR(repo: repo, number: number, suffix: "thread resolved")
        case GitHubEventKindKey.prReviewSubmitted.rawValue:
            primary = formatPR(repo: repo, number: number, suffix: "review submitted")
        case GitHubEventKindKey.issueOpened.rawValue:
            primary = formatIssue(repo: repo, number: number, suffix: "issue opened")
        case GitHubEventKindKey.issueClosed.rawValue:
            primary = formatIssue(repo: repo, number: number, suffix: "issue closed")
        case "issue_updated":
            primary = formatIssue(repo: repo, number: number, suffix: "issue updated")
        case GitHubEventKindKey.issueCommentAuthored.rawValue:
            primary = formatIssue(repo: repo, number: number, suffix: "comment")
        case GitHubEventKindKey.branchCreated.rawValue:
            guard let repo else { return nil }
            primary = "\(repo): branch \(branch ?? "?") created"
        case GitHubEventKindKey.branchDeleted.rawValue:
            guard let repo else { return nil }
            primary = "\(repo): branch \(branch ?? "?") deleted"
        case GitHubEventKindKey.tagCreated.rawValue:
            guard let repo else { return nil }
            let tag = sanitize(payload["tag"]) ?? "?"
            primary = "\(repo): tag \(tag)"
        case GitHubEventKindKey.releasePublished.rawValue:
            guard let repo else { return nil }
            let tag = sanitize(payload["tag"]) ?? sanitize(payload["name"]) ?? "release"
            primary = "\(repo): release \(tag)"
        case GitHubEventKindKey.discussionAuthored.rawValue:
            primary = repo.map { "\($0): discussion" } ?? "Discussion"
        case GitHubEventKindKey.discussionCommentAuthored.rawValue:
            primary = repo.map { "\($0): discussion comment" } ?? "Discussion comment"
        case GitHubEventKindKey.actionsRunInitiated.rawValue:
            guard let repo else { return nil }
            let workflow = sanitize(payload["workflow_name"]) ?? "workflow"
            primary = "\(repo): \(workflow) run"
            secondary = sanitize(payload["status"])
        default:
            // Generic GitHub event we don't recognize specifically — show repo/number if present.
            guard let repo else { return nil }
            let suffix = kind.replacingOccurrences(of: "_", with: " ")
            primary = number.map { "\(repo) #\($0): \(suffix)" } ?? "\(repo): \(suffix)"
        }

        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .github,
            eventKind: kind.isEmpty ? "github_event" : kind,
            primaryText: primary,
            secondaryText: secondary,
            bundleID: nil
        )
    }

    static func formatPR(repo: String?, number: String?, suffix: String) -> String {
        switch (repo, number) {
        case (let r?, let n?): return "\(r) #\(n): \(suffix)"
        case (let r?, nil): return "\(r): PR \(suffix)"
        case (nil, let n?): return "PR #\(n): \(suffix)"
        case (nil, nil): return "PR: \(suffix)"
        }
    }

    static func formatIssue(repo: String?, number: String?, suffix: String) -> String {
        switch (repo, number) {
        case (let r?, let n?): return "\(r) #\(n): \(suffix)"
        case (let r?, nil): return "\(r): \(suffix)"
        case (nil, let n?): return "#\(n): \(suffix)"
        case (nil, nil): return suffix
        }
    }
    // MARK: - Slack

    // Cyclomatic from per-event_kind enum-style mapping (~27 slack_*
    // flavors: message / reaction / huddle / status / canvas / bookmark /
    // emoji / channel / thread / dnd / etc).
    // swiftlint:disable:next cyclomatic_complexity
    static func mapSlack(
        id: Int64,
        timestamp: Date,
        kind: String,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let channel = sanitize(payload["channel_name"]) ?? sanitize(payload["channel"])

        let primary: String
        var secondary: String? = nil

        switch kind {
        case "slack_message_authored_aggregate":
            guard let channel else { return nil }
            let count = sanitize(payload["count"]) ?? "1"
            primary = "\(channel): \(count) message\(count == "1" ? "" : "s")"
            if let reactions = sanitize(payload["reactions_count"]), reactions != "0" {
                secondary = "\(reactions) reactions"
            }
        case "slack_thread_reply_aggregate":
            guard let channel else { return nil }
            let count = sanitize(payload["count"]) ?? "1"
            primary = "\(channel): \(count) thread repl\(count == "1" ? "y" : "ies")"
        case "slack_mention_received_aggregate":
            guard let channel else { return nil }
            let count = sanitize(payload["count"]) ?? "1"
            primary = "\(channel): \(count) mention\(count == "1" ? "" : "s") received"
        case "slack_file_uploaded_aggregate":
            let count = sanitize(payload["count"]) ?? "1"
            primary = "\(count) file\(count == "1" ? "" : "s") uploaded"
            // Bucket breakdown without filename — ADR-010 compliant.
            let parts = ["image_count", "code_count", "doc_count", "other_count"]
                .compactMap { key -> String? in
                    guard let v = sanitize(payload[key]), v != "0" else { return nil }
                    let label = key.replacingOccurrences(of: "_count", with: "")
                    return "\(v) \(label)"
                }
            if !parts.isEmpty { secondary = parts.joined(separator: " · ") }
        case "slack_huddle_state_change":
            let state = sanitize(payload["state"]) ?? "?"
            primary = "Huddle: \(state)"
        case "slack_status_change":
            let emoji = sanitize(payload["status_emoji"]) ?? "—"
            primary = "Status: \(emoji)"
        default:
            return nil
        }

        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .slack,
            eventKind: kind.isEmpty ? "slack_event" : kind,
            primaryText: primary,
            secondaryText: secondary,
            bundleID: nil
        )
    }

    // MARK: - Google Calendar (Track-6 P4)

    // Per-event-kind copy mapping for Track-6 P4 Google Calendar events.
    // ADR-010 redaction discipline: reads ONLY allowlisted payload fields
    // (`summary` — Calendar event title is self-authored, mirrors Linear
    // issue title allowance; structural enum buckets like
    // `working_location_type` / `chat_status` / `conference_entry_point_type`;
    // scalar `attendees_count`). NEVER reads `description` / `location` /
    // attendee emails / `decline_message` / conference URI / building/floor/
    // desk/label — those fields are forbidden in the payload per spec §6.4
    // and never enter primaryText/secondaryText, even if a future collector
    // regression were to accidentally store them.
    //
    // Cyclomatic from per-event_kind enum-style mapping (omnibus + 5
    // transition flavors × per-eventType helpers).
    // swiftlint:disable:next cyclomatic_complexity
    static func mapGoogleCalendar(
        id: Int64,
        timestamp: Date,
        kind: String,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let primary: String
        var secondary: String? = nil

        switch kind {
        case GoogleCalendarEventKind.eventObserved.rawValue:
            // `summary` is L4-gated by ShareEventTypeKey.googleCalendarEventObserved
            // (default OFF) — if user opted in, the title is a self-authored
            // label, mirroring Linear issue title / GitHub commit message.
            primary = sanitize(payload["summary"]) ?? "Calendar event"
            // Tasteful secondary: attendee count (scalar) + video-call hint
            // (structural bucket). NEVER attendee names / emails / URIs.
            var parts: [String] = []
            if let countStr = sanitize(payload["attendees_count"]),
                let count = Int(countStr), count > 0
            {
                parts.append(count == 1 ? "1 attendee" : "\(count) attendees")
            }
            if sanitize(payload["conference_entry_point_type"]) == "video" {
                parts.append("video call")
            }
            if !parts.isEmpty { secondary = parts.joined(separator: " · ") }

        case GoogleCalendarEventKind.focusBlockStarted.rawValue:
            primary = "Focus block started"
            // `chat_status` is a structural enum (doNotDisturb / available).
            if sanitize(payload["chat_status"]) == "doNotDisturb" {
                secondary = "Do not disturb"
            }

        case GoogleCalendarEventKind.focusBlockEnded.rawValue:
            primary = "Focus block ended"

        case GoogleCalendarEventKind.oooStarted.rawValue:
            primary = "Out of office started"

        case GoogleCalendarEventKind.oooEnded.rawValue:
            primary = "Out of office ended"

        case GoogleCalendarEventKind.workingLocationChanged.rawValue:
            // `working_location_type` is a structural enum from Google Calendar
            // API. NEVER raw building/floor/desk/label fields.
            let raw = sanitize(payload["working_location_type"]) ?? "homeOffice"
            let pretty: String = {
                switch raw {
                case "homeOffice": return "home"
                case "officeLocation": return "office"
                case "customLocation": return "custom location"
                default: return raw
                }
            }()
            primary = "Working from \(pretty)"

        default:
            return nil
        }

        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .googleCalendar,
            eventKind: kind.isEmpty ? "google_calendar_event" : kind,
            primaryText: primary,
            secondaryText: secondary,
            bundleID: nil
        )
    }
}
