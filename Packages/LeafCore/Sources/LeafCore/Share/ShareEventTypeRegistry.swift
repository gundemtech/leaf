import Foundation

/// Phase 4.7.A — registry of canonical event_kinds для share-controls
/// whitelist (whitepaper Section 7 / Share Controls model).
///
/// **Scope в Phase 4.7.A:** code-level constants only. `share_event_types`
/// table ещё не создана — runtime UPSERT logic откладывается до Phase 5
/// prep / отдельной mini-migration. До тех пор registry служит single source
/// of truth для:
/// - downstream code (share-control filters могут assert'ить полный set
///   известных event_kinds);
/// - onboarding default presets (`ShareEventTypeDefaults`);
/// - test coverage (любой новый event_kind должен быть registered).
///
/// Naming: rawValue матчит discriminator value в `events.payload_json.event_kind`
/// 1-в-1 — single string identity между registry, runtime emission и downstream
/// SQL queries.
public enum ShareEventTypeKey: String, CaseIterable, Sendable, Hashable {
    // MARK: - Phase 4.4 baseline (already shipped в alpha.5/6)
    // Track-3 D2: GitHub rawValues renamed to canonical `gh_*` form via M016
    // (Swift identifiers preserved for call-site stability).
    case slackMessageAuthored = "message_authored_aggregate"
    case slackHuddleStateChange = "huddle_state_change"
    case linearIssueUpdated = "issue_updated"
    case githubCommitPushed = "gh_commit_pushed"
    case githubPROpened = "gh_pr_opened"
    case githubPRMerged = "gh_pr_merged"
    case githubPRClosed = "gh_pr_closed"
    case githubReviewSubmitted = "gh_pr_review_submitted"
    case githubIssueOpened = "gh_issue_opened"
    case githubIssueClosed = "gh_issue_closed"

    // MARK: - Phase 4.6.B (alpha.7)
    case linearStatusTransition = "status_transition"

    // MARK: - Phase 4.7.A — wide cheap (this commit)
    case githubPRReviewCommentAuthored = "gh_pr_review_comment_authored"
    case githubIssueCommentAuthored = "gh_issue_comment_authored"
    case githubReleasePublished = "gh_release_published"
    case githubBranchCreated = "gh_branch_created"
    case githubBranchDeleted = "gh_branch_deleted"
    case githubTagCreated = "gh_tag_created"
    case githubDiscussionAuthored = "gh_discussion_authored"
    case githubDiscussionCommentAuthored = "gh_discussion_comment_authored"
    case slackThreadReplyAggregate = "slack_thread_reply_aggregate"
    case slackStatusChange = "slack_status_change"
    case linearCommentAuthored = "linear_comment_authored"

    // MARK: - Phase 4.7.B — presence-first first-class APIs (this commit)
    case githubNotificationsPulse = "gh_notifications_pulse"
    case githubPRAwaitingReviewCount = "gh_pr_awaiting_review_count"
    case githubMyOpenPRCount = "gh_my_open_pr_count"
    case githubActionsRunInitiated = "gh_actions_run_initiated"
    case githubCheckRunsStatus = "gh_check_runs_status"
    case linearAssignedWorkloadPulse = "linear_assigned_workload_pulse"
    case linearCycleProgress = "linear_cycle_progress"
    case slackPresenceState = "slack_presence_state"
    case slackDNDState = "slack_dnd_state"
    case slackMentionReceivedAggregate = "slack_mention_received_aggregate"
    case slackFileUploadedAggregate = "slack_file_uploaded_aggregate"
    // Note: linear `attachments` enrichment — extends existing `issue_updated`,
    // no new key. github contributions calendar — used for presence_state only,
    // no event key.

    // MARK: - Phase 4.7.C — triage / state-change depth + skeleton queries
    case linearPriorityChanged = "linear_priority_changed"
    case linearLabelAdded = "linear_label_added"
    case linearLabelRemoved = "linear_label_removed"
    case linearAssigneeChanged = "linear_assignee_changed"
    case linearCycleChanged = "linear_cycle_changed"
    case linearEstimateChanged = "linear_estimate_changed"
    case linearProjectUpdateAuthored = "linear_project_update_authored"
    case linearDocumentEdited = "linear_document_edited"
    case linearInitiativeObserved = "linear_initiative_observed"
    case githubPullRequestReviewThreadResolved = "gh_pr_review_thread_resolved"

    // MARK: - Phase Track-1 D3 — semantic detection facts
    // Default OFF: detector outputs expose deeper inference than raw events
    // (decisions / open questions / blockers извлекаются из тел сообщений
    // post-D1). Per Track 1 contract §5.3 — opt-in only, юзер сам включает.
    case decisionDetected = "decision_detected"
    case openQuestionOpened = "open_question_opened"
    case openQuestionResolved = "open_question_resolved"
    case blockerStarted = "blocker_started"
    case blockerResolved = "blocker_resolved"

    // MARK: - Phase Track-3 D1 — Linear deep sweep (18 new kinds, all default OFF)
    case linearCommentReactionAdded = "linear_comment_reaction_added"
    case linearRelationAdded = "linear_relation_added"
    case linearRelationRemoved = "linear_relation_removed"
    case linearTriageItemPickedUp = "linear_triage_item_picked_up"
    case linearTriageItemResolved = "linear_triage_item_resolved"
    case linearNotificationReceived = "linear_notification_received"
    case linearNotificationRead = "linear_notification_read"
    case linearNotificationArchived = "linear_notification_archived"
    case linearSubscriptionAdded = "linear_subscription_added"
    case linearSubscriptionRemoved = "linear_subscription_removed"
    case linearCycleStarted = "linear_cycle_started"
    case linearCycleCompleted = "linear_cycle_completed"
    case linearRoadmapStateObserved = "linear_roadmap_state_observed"
    case linearCustomViewCreated = "linear_custom_view_created"
    case linearCustomViewUpdated = "linear_custom_view_updated"
    case linearCustomViewDeleted = "linear_custom_view_deleted"
    case linearProjectMembershipAdded = "linear_project_membership_added"
    case linearProjectMembershipRemoved = "linear_project_membership_removed"

    // MARK: - Phase Track-3 D2 — GitHub deep sweep (31 new kinds, all default OFF per ADR-020)

    // Hot tier (7)
    case githubIssueLocked = "gh_issue_locked"
    case githubIssueUnlocked = "gh_issue_unlocked"
    case githubWorkflowManualTriggered = "gh_workflow_manual_triggered"
    case githubDeploymentCreated = "gh_deployment_created"
    case githubDeploymentStatusChanged = "gh_deployment_status_changed"
    case githubRepoCreated = "gh_repo_created"
    case githubRepoForked = "gh_repo_forked"

    // Warm tier (13)
    case githubProjectCardMoved = "gh_project_card_moved"
    case githubProjectIterationChanged = "gh_project_iteration_changed"
    case githubProjectFieldUpdated = "gh_project_field_updated"
    case githubGistCreated = "gh_gist_created"
    case githubGistUpdated = "gh_gist_updated"
    case githubGistDeleted = "gh_gist_deleted"
    case githubRepoInvitationReceived = "gh_repo_invitation_received"
    case githubRepoInvitationAccepted = "gh_repo_invitation_accepted"
    case githubCodespaceCreated = "gh_codespace_created"
    case githubCodespaceStarted = "gh_codespace_started"
    case githubCodespaceStopped = "gh_codespace_stopped"
    case githubCodespaceDeleted = "gh_codespace_deleted"
    case githubIssueReactionReceived = "gh_issue_reaction_received"

    // Cold tier (11)
    case githubRepoStarred = "gh_repo_starred"
    case githubRepoUnstarred = "gh_repo_unstarred"
    case githubRepoWatched = "gh_repo_watched"
    case githubRepoUnwatched = "gh_repo_unwatched"
    case githubSecretAlertObserved = "gh_secret_alert_observed"
    case githubSecretAlertResolved = "gh_secret_alert_resolved"
    case githubCodeAlertObserved = "gh_code_alert_observed"
    case githubCodeAlertResolved = "gh_code_alert_resolved"
    case githubDependabotAlertObserved = "gh_dependabot_alert_observed"
    case githubDependabotAlertResolved = "gh_dependabot_alert_resolved"
    case githubAuditActionObserved = "gh_audit_action_observed"
}

/// Phase 4.7.A — onboarding default enabled-state per event_kind.
/// Recommendation для UI Settings → Share Controls onboarding template
/// ("common dev defaults"). Юзер всегда может override per-key. Persistence
/// шкафа — Phase 5 prep (`share_event_types` table).
public struct ShareEventTypeDefault: Sendable, Hashable {
    public let key: ShareEventTypeKey
    public let defaultEnabled: Bool

    public init(key: ShareEventTypeKey, defaultEnabled: Bool) {
        self.key = key
        self.defaultEnabled = defaultEnabled
    }
}

public enum ShareEventTypeDefaults {
    /// Полный default set across baseline + Phase 4.7.A. Defaults reflect
    /// "common dev team" preset: outcome-bearing events default ON, niche
    /// social-feature events (discussions) default OFF.
    public static let all: [ShareEventTypeDefault] = [
        // Phase 4.4 baseline
        .init(key: .slackMessageAuthored, defaultEnabled: true),
        .init(key: .slackHuddleStateChange, defaultEnabled: true),
        .init(key: .linearIssueUpdated, defaultEnabled: true),
        .init(key: .githubCommitPushed, defaultEnabled: true),
        .init(key: .githubPROpened, defaultEnabled: true),
        .init(key: .githubPRMerged, defaultEnabled: true),
        .init(key: .githubPRClosed, defaultEnabled: true),
        // Track-3 D2: re-treated as new (discriminator-only upgrade adds state field);
        // flipped OFF per testNewD2GitHubKindsAllDefaultOff.
        .init(key: .githubReviewSubmitted, defaultEnabled: false),
        .init(key: .githubIssueOpened, defaultEnabled: true),
        .init(key: .githubIssueClosed, defaultEnabled: true),

        // Phase 4.6.B
        .init(key: .linearStatusTransition, defaultEnabled: true),

        // Phase 4.7.A — additions
        .init(key: .githubPRReviewCommentAuthored, defaultEnabled: true),
        .init(key: .githubIssueCommentAuthored, defaultEnabled: true),
        .init(key: .githubReleasePublished, defaultEnabled: true),
        .init(key: .githubBranchCreated, defaultEnabled: true),
        .init(key: .githubBranchDeleted, defaultEnabled: true),
        .init(key: .githubTagCreated, defaultEnabled: true),
        // Discussions — нишевые; OFF by default (юзер может включить).
        .init(key: .githubDiscussionAuthored, defaultEnabled: false),
        .init(key: .githubDiscussionCommentAuthored, defaultEnabled: false),
        .init(key: .slackThreadReplyAggregate, defaultEnabled: true),
        .init(key: .slackStatusChange, defaultEnabled: true),
        .init(key: .linearCommentAuthored, defaultEnabled: true),

        // Phase 4.7.B — presence-first first-class APIs
        .init(key: .githubNotificationsPulse, defaultEnabled: true),
        .init(key: .githubPRAwaitingReviewCount, defaultEnabled: true),
        .init(key: .githubMyOpenPRCount, defaultEnabled: true),
        .init(key: .githubActionsRunInitiated, defaultEnabled: true),
        .init(key: .githubCheckRunsStatus, defaultEnabled: true),
        .init(key: .linearAssignedWorkloadPulse, defaultEnabled: true),
        .init(key: .linearCycleProgress, defaultEnabled: true),
        // Slack presence/DND — Slack уже шарит это нативно, default ON.
        .init(key: .slackPresenceState, defaultEnabled: true),
        .init(key: .slackDNDState, defaultEnabled: true),
        .init(key: .slackMentionReceivedAggregate, defaultEnabled: true),
        .init(key: .slackFileUploadedAggregate, defaultEnabled: true),

        // Phase 4.7.C — outcome-bearing transitions / project updates ON;
        // skeleton-style features (documents / initiatives) OFF на legacy
        // workspaces без feature support.
        .init(key: .linearPriorityChanged, defaultEnabled: true),
        .init(key: .linearLabelAdded, defaultEnabled: true),
        .init(key: .linearLabelRemoved, defaultEnabled: true),
        .init(key: .linearAssigneeChanged, defaultEnabled: true),
        .init(key: .linearCycleChanged, defaultEnabled: true),
        .init(key: .linearEstimateChanged, defaultEnabled: true),
        .init(key: .linearProjectUpdateAuthored, defaultEnabled: true),
        // Skeleton — могут вернуть 0 events на workspaces без feature; OFF.
        .init(key: .linearDocumentEdited, defaultEnabled: false),
        .init(key: .linearInitiativeObserved, defaultEnabled: false),
        .init(key: .githubPullRequestReviewThreadResolved, defaultEnabled: true),

        // Phase Track-1 D3 — semantic detection facts. Все OFF by default:
        // detector outputs выводят более глубокий смысл из bodies (см. §5.3
        // контракта Track 1), юзер должен явно opt-in перед broadcast.
        .init(key: .decisionDetected, defaultEnabled: false),
        .init(key: .openQuestionOpened, defaultEnabled: false),
        .init(key: .openQuestionResolved, defaultEnabled: false),
        .init(key: .blockerStarted, defaultEnabled: false),
        .init(key: .blockerResolved, defaultEnabled: false),

        // Phase Track-3 D1 — Linear deep sweep. All default OFF per ADR-020
        // (capture-everything locally, share-selectively). User opts in via
        // Share Controls UI per provider expansion.
        .init(key: .linearCommentReactionAdded, defaultEnabled: false),
        .init(key: .linearRelationAdded, defaultEnabled: false),
        .init(key: .linearRelationRemoved, defaultEnabled: false),
        .init(key: .linearTriageItemPickedUp, defaultEnabled: false),
        .init(key: .linearTriageItemResolved, defaultEnabled: false),
        .init(key: .linearNotificationReceived, defaultEnabled: false),
        .init(key: .linearNotificationRead, defaultEnabled: false),
        .init(key: .linearNotificationArchived, defaultEnabled: false),
        .init(key: .linearSubscriptionAdded, defaultEnabled: false),
        .init(key: .linearSubscriptionRemoved, defaultEnabled: false),
        .init(key: .linearCycleStarted, defaultEnabled: false),
        .init(key: .linearCycleCompleted, defaultEnabled: false),
        .init(key: .linearRoadmapStateObserved, defaultEnabled: false),
        .init(key: .linearCustomViewCreated, defaultEnabled: false),
        .init(key: .linearCustomViewUpdated, defaultEnabled: false),
        .init(key: .linearCustomViewDeleted, defaultEnabled: false),
        .init(key: .linearProjectMembershipAdded, defaultEnabled: false),
        .init(key: .linearProjectMembershipRemoved, defaultEnabled: false),

        // Phase Track-3 D2 — GitHub deep sweep. All default OFF per ADR-020
        // (capture-everything locally, share-selectively). User opts in via
        // Share Controls UI per provider expansion.
        // Hot tier (7)
        .init(key: .githubIssueLocked, defaultEnabled: false),
        .init(key: .githubIssueUnlocked, defaultEnabled: false),
        .init(key: .githubWorkflowManualTriggered, defaultEnabled: false),
        .init(key: .githubDeploymentCreated, defaultEnabled: false),
        .init(key: .githubDeploymentStatusChanged, defaultEnabled: false),
        .init(key: .githubRepoCreated, defaultEnabled: false),
        .init(key: .githubRepoForked, defaultEnabled: false),
        // Warm tier (13)
        .init(key: .githubProjectCardMoved, defaultEnabled: false),
        .init(key: .githubProjectIterationChanged, defaultEnabled: false),
        .init(key: .githubProjectFieldUpdated, defaultEnabled: false),
        .init(key: .githubGistCreated, defaultEnabled: false),
        .init(key: .githubGistUpdated, defaultEnabled: false),
        .init(key: .githubGistDeleted, defaultEnabled: false),
        .init(key: .githubRepoInvitationReceived, defaultEnabled: false),
        .init(key: .githubRepoInvitationAccepted, defaultEnabled: false),
        .init(key: .githubCodespaceCreated, defaultEnabled: false),
        .init(key: .githubCodespaceStarted, defaultEnabled: false),
        .init(key: .githubCodespaceStopped, defaultEnabled: false),
        .init(key: .githubCodespaceDeleted, defaultEnabled: false),
        .init(key: .githubIssueReactionReceived, defaultEnabled: false),
        // Cold tier (11)
        .init(key: .githubRepoStarred, defaultEnabled: false),
        .init(key: .githubRepoUnstarred, defaultEnabled: false),
        .init(key: .githubRepoWatched, defaultEnabled: false),
        .init(key: .githubRepoUnwatched, defaultEnabled: false),
        .init(key: .githubSecretAlertObserved, defaultEnabled: false),
        .init(key: .githubSecretAlertResolved, defaultEnabled: false),
        .init(key: .githubCodeAlertObserved, defaultEnabled: false),
        .init(key: .githubCodeAlertResolved, defaultEnabled: false),
        .init(key: .githubDependabotAlertObserved, defaultEnabled: false),
        .init(key: .githubDependabotAlertResolved, defaultEnabled: false),
        .init(key: .githubAuditActionObserved, defaultEnabled: false)
    ]
}
