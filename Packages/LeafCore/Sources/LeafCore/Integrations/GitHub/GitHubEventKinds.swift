import Foundation

/// Phase Track-3 D2 — canonical GitHub event_kind identity. RawValue is the
/// JSON `event_kind` literal stored in `events.payload_json.$.event_kind`.
///
/// Source of truth for: ShareEventTypeRegistry (case-by-case mirror),
/// M016 rename mapping coverage (only the legacyKinds subset),
/// EventsFullTextStore body-kind dispatch (only body-bearing cases),
/// DispatchCoverageTests (the fence).
public enum GitHubEventKindKey: String, CaseIterable, Sendable, Hashable {
    // MARK: - Hot tier (existing 21, renamed to gh_*)
    case commitPushed                 = "gh_commit_pushed"
    case prOpened                     = "gh_pr_opened"
    case prMerged                     = "gh_pr_merged"
    case prClosed                     = "gh_pr_closed"
    case issueOpened                  = "gh_issue_opened"
    case issueClosed                  = "gh_issue_closed"
    case prReviewSubmitted            = "gh_pr_review_submitted"
    case prReviewCommentAuthored      = "gh_pr_review_comment_authored"
    case issueCommentAuthored         = "gh_issue_comment_authored"
    case releasePublished             = "gh_release_published"
    case branchCreated                = "gh_branch_created"
    case branchDeleted                = "gh_branch_deleted"
    case tagCreated                   = "gh_tag_created"
    case discussionAuthored           = "gh_discussion_authored"
    case discussionCommentAuthored    = "gh_discussion_comment_authored"
    case prReviewThreadResolved       = "gh_pr_review_thread_resolved"
    case notificationsPulse           = "gh_notifications_pulse"
    case prAwaitingReviewCount        = "gh_pr_awaiting_review_count"
    case myOpenPRCount                = "gh_my_open_pr_count"
    case actionsRunInitiated          = "gh_actions_run_initiated"
    case checkRunsStatus              = "gh_check_runs_status"

    // MARK: - Hot tier new (Task 4)
    case issueLocked                  = "gh_issue_locked"
    case issueUnlocked                = "gh_issue_unlocked"
    case workflowManualTriggered      = "gh_workflow_manual_triggered"
    case deploymentCreated            = "gh_deployment_created"
    case deploymentStatusChanged      = "gh_deployment_status_changed"
    case repoCreated                  = "gh_repo_created"
    case repoForked                   = "gh_repo_forked"

    // MARK: - Warm tier (Tasks 7–11)
    case projectCardMoved             = "gh_project_card_moved"
    case projectIterationChanged      = "gh_project_iteration_changed"
    case projectFieldUpdated          = "gh_project_field_updated"
    case gistCreated                  = "gh_gist_created"
    case gistUpdated                  = "gh_gist_updated"
    case gistDeleted                  = "gh_gist_deleted"
    case repoInvitationReceived       = "gh_repo_invitation_received"
    case repoInvitationAccepted       = "gh_repo_invitation_accepted"
    case codespaceCreated             = "gh_codespace_created"
    case codespaceStarted             = "gh_codespace_started"
    case codespaceStopped             = "gh_codespace_stopped"
    case codespaceDeleted             = "gh_codespace_deleted"
    case issueReactionReceived        = "gh_issue_reaction_received"

    // MARK: - Cold tier (Tasks 12–14)
    case repoStarred                  = "gh_repo_starred"
    case repoUnstarred                = "gh_repo_unstarred"
    case repoWatched                  = "gh_repo_watched"
    case repoUnwatched                = "gh_repo_unwatched"
    case secretAlertObserved          = "gh_secret_alert_observed"
    case secretAlertResolved          = "gh_secret_alert_resolved"
    case codeAlertObserved            = "gh_code_alert_observed"
    case codeAlertResolved            = "gh_code_alert_resolved"
    case dependabotAlertObserved      = "gh_dependabot_alert_observed"
    case dependabotAlertResolved      = "gh_dependabot_alert_resolved"
    case auditActionObserved          = "gh_audit_action_observed"

    /// Subset that existed before D2 (renamed by M016). DispatchCoverageTests
    /// asserts M016.renameMap covers exactly this set.
    public static let legacyRenamed: Set<GitHubEventKindKey> = [
        .commitPushed, .prOpened, .prMerged, .prClosed, .issueOpened, .issueClosed,
        .prReviewSubmitted, .prReviewCommentAuthored, .issueCommentAuthored,
        .releasePublished, .branchCreated, .branchDeleted, .tagCreated,
        .discussionAuthored, .discussionCommentAuthored, .prReviewThreadResolved,
        .notificationsPulse, .prAwaitingReviewCount, .myOpenPRCount,
        .actionsRunInitiated, .checkRunsStatus
    ]

    /// Subset that ships a body field in payload — body-kind dispatch in
    /// EventsFullTextStore must handle each of these.
    ///
    /// Discussion events (`gh_discussion_authored`, `gh_discussion_comment_authored`)
    /// are intentionally OMITTED: per ADR-010 §6 + Track-3 D2 spec §4.3, discussion
    /// bodies/titles are not captured (no `Schema.BodyKinds.ghDiscussion` constant).
    /// The mappers in `ProdGitHubAPIProvider.mapDiscussionEvent` /
    /// `mapDiscussionCommentEvent` emit `title: ""` and never set a body field.
    public static let bodyBearing: Set<GitHubEventKindKey> = [
        .commitPushed,                  // commit_msg
        .prOpened, .prMerged, .prClosed,   // gh_pr body
        .issueOpened, .issueClosed,        // gh_issue_comment (issue body indexed under same body_kind)
        .prReviewCommentAuthored,
        .issueCommentAuthored,
        .releasePublished,              // gh_release_body (Track-3 D2 §4.3 — formalize for future emit)
        .gistCreated, .gistUpdated,     // gh_gist_description
        .deploymentCreated              // gh_deployment_description
    ]
}
