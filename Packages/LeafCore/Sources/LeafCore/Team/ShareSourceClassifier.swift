import Foundation

/// Phase Track-5 S5 — maps `event_kind` strings (the 152-entry
/// `ShareEventTypeKey` registry) onto coarse-grain `ShareSource` groups
/// (9 per Track 5 contract §11.1). Pure function — no IO, no state.
///
/// Events without a mapping are **not auto-shareable** in S5 (returns nil →
/// `TeamEventBroadcastService` skips). Granularity-31 detection-output kinds
/// route to detection sources; raw GitHub activity (stars, branches, releases,
/// discussions) routes to `rawGitHubActivity`.
///
/// Maintaining the table: when a new event_kind lands in Layer A/B/D3, add
/// here only if it should be auto-shareable. Detection facts are routed
/// per kind, not aggregated.
public struct ShareSourceClassifier: Sendable {

    private static let kindToSource: [String: ShareSource] = [
        // gitCommits
        "gh_commit_pushed":                  .gitCommits,

        // linearIssues
        "issue_updated":                     .linearIssues,
        "linear_status_transition":          .linearIssues,
        "linear_priority_changed":           .linearIssues,
        "linear_label_added":                .linearIssues,
        "linear_label_removed":              .linearIssues,
        "linear_assignee_changed":           .linearIssues,
        "linear_cycle_changed":              .linearIssues,
        "linear_estimate_changed":           .linearIssues,
        "linear_comment_authored":           .linearIssues,
        "linear_project_update_authored":    .linearIssues,

        // slackMentions
        "slack_message_authored_aggregate":  .slackMentions,
        "slack_thread_reply_aggregate":      .slackMentions,
        "slack_mention_received":            .slackMentions,

        // githubPRs
        "gh_pr_opened":                      .githubPRs,
        "gh_pr_merged":                      .githubPRs,
        "gh_pr_closed":                      .githubPRs,
        "gh_pr_review_submitted":            .githubPRs,
        "gh_pr_review_comment_authored":     .githubPRs,
        "gh_pr_review_thread_resolved":      .githubPRs,

        // detectedDecisions
        "decision_detected":                 .detectedDecisions,

        // detectedBlockers
        "blocker_started":                   .detectedBlockers,
        "blocker_resolved":                  .detectedBlockers,

        // detectedOpenQuestions
        "open_question_opened":              .detectedOpenQuestions,
        "open_question_resolved":            .detectedOpenQuestions,

        // detectedWhereStopped
        "where_stopped_snapshot":            .detectedWhereStopped,

        // rawGitHubActivity
        "gh_branch_created":                 .rawGitHubActivity,
        "gh_branch_deleted":                 .rawGitHubActivity,
        "gh_tag_created":                    .rawGitHubActivity,
        "gh_release_published":              .rawGitHubActivity,
        "gh_discussion_authored":            .rawGitHubActivity,
        "gh_discussion_comment_authored":    .rawGitHubActivity,
        "gh_issue_comment_authored":         .rawGitHubActivity,
    ]

    public init() {}

    /// Returns the coarse `ShareSource` for an event_kind, or nil if the kind
    /// is not auto-shareable.
    public func classify(eventKind: String) -> ShareSource? {
        Self.kindToSource[eventKind]
    }

    /// All event_kinds registered for auto-share routing.
    public static var knownEventKinds: Set<String> {
        Set(kindToSource.keys)
    }
}
