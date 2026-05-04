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

    // MARK: - Attention (local app-switch)

    private static func mapAttention(
        id: Int64,
        timestamp: Date,
        bundleID: String?,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let kind = payload["event_kind"] ?? "app_active"
        // Phase 4.10.B will add window_title / browser_url to attention payloads;
        // the mapper falls back to bundle name when absent.
        let title = sanitize(payload["window_title"]).flatMap { $0.isEmpty ? nil : $0 }
        let url = sanitize(payload["browser_url"]).flatMap { $0.isEmpty ? nil : $0 }
        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .local,
            eventKind: kind,
            primaryText: title ?? bundleID,
            secondaryText: url,
            bundleID: bundleID
        )
    }

    // MARK: - AI collaboration

    private static func mapAI(
        id: Int64,
        timestamp: Date,
        bundleID: String?,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let kind = payload["event_kind"] ?? "ai_activity"
        let tool = sanitize(payload["tool"]) ?? sanitize(payload["agent"]) ?? "AI"
        let project = sanitize(payload["project"]) ?? sanitize(payload["cwd_basename"])
        return ActivityFeedEntry(
            id: id,
            timestamp: timestamp,
            provider: .ai,
            eventKind: kind,
            primaryText: tool,
            secondaryText: project,
            bundleID: bundleID
        )
    }

    // MARK: - Integrations (Linear / GitHub / Slack)

    private static func mapIntegration(
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
        default:
            return nil
        }
    }

    // MARK: - Linear

    private static func mapLinear(
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

    private static func mapGitHub(
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
        case "commit_pushed":
            guard let repo else { return nil }
            primary = branch.map { "\(repo): pushed to \($0)" } ?? "\(repo): pushed"
            secondary = sha
        case "pr_opened":
            primary = formatPR(repo: repo, number: number, suffix: "opened")
            secondary = nil
        case "pr_closed":
            primary = formatPR(repo: repo, number: number, suffix: "closed")
        case "pr_merged":
            primary = formatPR(repo: repo, number: number, suffix: "merged")
        case "pr_review_comment_authored":
            primary = formatPR(repo: repo, number: number, suffix: "review comment")
        case "pr_review_thread_resolved":
            primary = formatPR(repo: repo, number: number, suffix: "thread resolved")
        case "review_submitted":
            primary = formatPR(repo: repo, number: number, suffix: "review submitted")
        case "issue_opened":
            primary = formatIssue(repo: repo, number: number, suffix: "issue opened")
        case "issue_closed":
            primary = formatIssue(repo: repo, number: number, suffix: "issue closed")
        case "issue_updated":
            primary = formatIssue(repo: repo, number: number, suffix: "issue updated")
        case "issue_comment_authored":
            primary = formatIssue(repo: repo, number: number, suffix: "comment")
        case "branch_created":
            guard let repo else { return nil }
            primary = "\(repo): branch \(branch ?? "?") created"
        case "branch_deleted":
            guard let repo else { return nil }
            primary = "\(repo): branch \(branch ?? "?") deleted"
        case "tag_created":
            guard let repo else { return nil }
            let tag = sanitize(payload["tag"]) ?? "?"
            primary = "\(repo): tag \(tag)"
        case "release_published":
            guard let repo else { return nil }
            let tag = sanitize(payload["tag"]) ?? sanitize(payload["name"]) ?? "release"
            primary = "\(repo): release \(tag)"
        case "discussion_authored":
            primary = repo.map { "\($0): discussion" } ?? "Discussion"
        case "discussion_comment_authored":
            primary = repo.map { "\($0): discussion comment" } ?? "Discussion comment"
        case "actions_run_initiated":
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

    private static func formatPR(repo: String?, number: String?, suffix: String) -> String {
        switch (repo, number) {
        case let (r?, n?): return "\(r) #\(n): \(suffix)"
        case let (r?, nil): return "\(r): PR \(suffix)"
        case let (nil, n?): return "PR #\(n): \(suffix)"
        case (nil, nil):   return "PR: \(suffix)"
        }
    }

    private static func formatIssue(repo: String?, number: String?, suffix: String) -> String {
        switch (repo, number) {
        case let (r?, n?): return "\(r) #\(n): \(suffix)"
        case let (r?, nil): return "\(r): \(suffix)"
        case let (nil, n?): return "#\(n): \(suffix)"
        case (nil, nil):   return suffix
        }
    }

    // MARK: - Slack

    private static func mapSlack(
        id: Int64,
        timestamp: Date,
        kind: String,
        payload: [String: String]
    ) -> ActivityFeedEntry? {
        let channel = sanitize(payload["channel_name"]) ?? sanitize(payload["channel"])

        let primary: String
        var secondary: String? = nil

        switch kind {
        case "message_authored_aggregate":
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
        case "huddle_state_change":
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

    // MARK: - Helpers

    /// Recurring state-snapshot event_kinds that flood the feed without
    /// representing a discrete user action. They're surfaced via the Live
    /// Presence widget instead.
    static let skippedKinds: Set<String> = [
        "github_notifications_pulse",
        "pr_awaiting_review_count",
        "my_open_pr_count",
        "check_runs_status",
        "slack_presence_state",
        "slack_dnd_state",
        "linear_assigned_workload_pulse",
        "linear_cycle_progress"
    ]

    /// Trim + drop empties + length-cap. Defends against degenerate or
    /// oversized strings that could leak into `primaryText`.
    private static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 200 {
            return String(trimmed.prefix(200)) + "…"
        }
        return trimmed
    }

    private static func parsePayload(_ json: String) -> [String: String] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in obj {
            if let s = value as? String { result[key] = s }
            else if let n = value as? NSNumber { result[key] = n.stringValue }
            else if let b = value as? Bool { result[key] = b ? "true" : "false" }
        }
        return result
    }
}
