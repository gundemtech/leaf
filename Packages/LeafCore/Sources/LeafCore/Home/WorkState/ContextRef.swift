import Foundation

/// Cross-source link attached to an `OpenQuestion`. Decoded from the three
/// columns `slack_thread_ts` / `linear_issue_ref` / `github_pr_ref` in M014
/// `open_questions`; if more than one is non-null, the prod decoder picks
/// first-non-nil in priority order Slack → Linear → GitHub.
///
/// Rendered as inline plain text `"→ {ref}"` plus `.help(...)` tooltip; in
/// v1.0 the affordance is NOT a tap target (master spec §6.3).
public enum ContextRef: Equatable, Hashable, Sendable {
    case slackThread(ts: String)
    case linearIssue(ref: String)
    case githubPR(ref: String)
}
