import Foundation

/// Phase Track-5 S5 — builds ADR-010-filtered `TeamEventPayload.fields` from
/// raw `events.payload_json` map. Per-source allowlist + per-key truncation
/// caps enforced here.
///
/// **Banned keys are absent from every allowlist by construction** (regression
/// fence in `RelayBodyLeakageTests`). The keys ban list:
///   body, file_contents, note_body, email_subject, preview, prompt, response,
///   slack_message_text, linear_comment_body, github_comment_body,
///   slack_canvas_content
///
/// If you need to surface text from one of those sources for auto-share, add
/// an *excerpt* field at the collector layer with truncation already applied —
/// don't try to truncate `body` here.
public enum TeamEventPayloadBuilder {

    /// Builds a payload bag for the given event_kind / source. Returns only
    /// allow-listed keys; truncates per-key per `truncateCap`. Missing keys
    /// are simply absent — caller (broadcast service) does not validate
    /// completeness.
    public static func build(
        source: ShareSource,
        payload: [String: String]
    ) -> TeamEventPayload {
        var out: [String: String] = [:]
        let allowed = allowedKeys(for: source)
        for key in allowed {
            guard let raw = payload[key] else { continue }
            if let cap = truncateCap(for: key) {
                out[key] = String(raw.prefix(cap))
            } else {
                out[key] = raw
            }
        }
        return TeamEventPayload(fields: out)
    }

    /// Returns the allow-list of keys per source. Single source of truth —
    /// every key here is whitelisted; everything else is banned by absence.
    public static func allowedKeys(for source: ShareSource) -> Set<String> {
        switch source {
        case .gitCommits:
            return [
                "commit_sha",
                "repo_full_name",
                "branch",
                "commit_message_subject",
                "files_changed_count"
            ]
        case .linearIssues:
            return [
                "issue_id",
                "issue_identifier",
                "issue_title_excerpt",
                "issue_state_type",
                "team_key",
                "priority",
                "label_id",
                "label_name",
                "assignee_bucket",
                "cycle_id",
                "estimate_points"
            ]
        case .slackMentions:
            return [
                "channel_id_bucket",
                "has_mention_self",
                "reactions_count",
                "thread_root_ts"
            ]
        case .githubPRs:
            return [
                "pr_number",
                "repo_full_name",
                "pr_state",
                "pr_title_excerpt",
                "additions_bucket",
                "deletions_bucket",
                "files_count"
            ]
        case .detectedDecisions:
            return [
                "topic_keywords_json",
                "reasoning_excerpt",
                "confidence_bucket"
            ]
        case .detectedBlockers:
            return [
                "target_kind",
                "target_ref",
                "blocker_kind",
                "blocker_excerpt"
            ]
        case .detectedOpenQuestions:
            return [
                "question_excerpt",
                "alternatives_count",
                "context_kind"
            ]
        case .detectedWhereStopped:
            return [
                "excerpt",
                "wip_signal_count"
            ]
        case .rawGitHubActivity:
            return [
                "action",
                "ref_type",
                "ref_name",
                "repo_full_name"
            ]
        }
    }

    /// Returns truncation cap for a key, or nil to copy verbatim. Caps
    /// match contract §6 wire-shape budget guidance.
    public static func truncateCap(for key: String) -> Int? {
        switch key {
        case "commit_message_subject": return 140
        case "issue_title_excerpt":    return 140
        case "pr_title_excerpt":       return 140
        case "reasoning_excerpt":      return 200
        case "blocker_excerpt":        return 140
        case "question_excerpt":       return 140
        case "excerpt":                return 140
        default:                       return nil
        }
    }

    /// Test-visibility — sentinel list of payload keys that MUST NEVER appear
    /// in any allowlist (consumed by `RelayBodyLeakageTests`).
    public static let bannedKeys: Set<String> = [
        "body",
        "file_contents",
        "note_body",
        "email_subject",
        "preview",
        "prompt",
        "response",
        "slack_message_text",
        "linear_comment_body",
        "github_comment_body",
        "slack_canvas_content"
    ]
}
