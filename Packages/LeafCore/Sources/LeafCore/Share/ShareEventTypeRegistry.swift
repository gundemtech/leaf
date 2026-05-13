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
    case slackMessageAuthored = "slack_message_authored_aggregate"
    case slackHuddleStateChange = "slack_huddle_state_change"
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

    // MARK: - Phase Track-3 D3 — Slack deep sweep (19 new kinds, all default OFF per ADR-020)

    // Warm tier (13)
    case slackReactionAdded               = "slack_reaction_added"
    case slackPinAdded                    = "slack_pin_added"
    case slackPinRemoved                  = "slack_pin_removed"
    case slackBookmarkAdded               = "slack_bookmark_added"
    case slackBookmarkRemoved             = "slack_bookmark_removed"
    case slackReminderCreated             = "slack_reminder_created"
    case slackReminderCompleted           = "slack_reminder_completed"
    case slackMessageScheduled            = "slack_message_scheduled"
    case slackMessageSentScheduled        = "slack_message_sent_scheduled"
    case slackItemSaved                   = "slack_item_saved"
    case slackItemUnsaved                 = "slack_item_unsaved"
    case slackChannelJoined               = "slack_channel_joined"
    case slackChannelLeft                 = "slack_channel_left"

    // Cold tier (6)
    case slackCanvasCreated               = "slack_canvas_created"
    case slackCanvasEdited                = "slack_canvas_edited"
    case slackCustomEmojiAdded            = "slack_custom_emoji_added"
    case slackUsergroupMembershipChanged  = "slack_usergroup_membership_changed"
    case slackChannelRenamed              = "slack_channel_renamed"
    case slackChannelArchived             = "slack_channel_archived"

    // MARK: - Phase Track-4 S1 — Architecture catch-up (9 new kinds, all default OFF per ADR-020)
    case meetingStateEntered              = "meeting_state_entered"
    case meetingStateExited               = "meeting_state_exited"
    case focusModeEnabled                 = "focus_mode_enabled"
    case focusModeDisabled                = "focus_mode_disabled"
    case systemLocked                     = "system_locked"
    case systemUnlocked                   = "system_unlocked"
    case systemSlept                      = "system_slept"
    case systemWoke                       = "system_woke"
    case spaceSwitched                    = "space_switched"

    // MARK: - Phase Track-4 S2 — AppleScript surface (14 new kinds, all default OFF per ADR-020)
    case xcodeActiveDocChanged            = "xcode_active_doc_changed"
    case xcodeBuildStateChanged           = "xcode_build_state_changed"
    case jetbrainsActiveDocChanged        = "jetbrains_active_doc_changed"
    case musicTrackChanged                = "music_track_changed"
    case spotifyTrackChanged              = "spotify_track_changed"
    case notesActiveTitleChanged          = "notes_active_title_changed"
    case reminderCompleted                = "reminder_completed"
    case calendarAppViewChanged           = "calendar_app_view_changed"
    case mailActiveMailboxChanged         = "mail_active_mailbox_changed"
    case zoomMeetingStateChanged          = "zoom_meeting_state_changed"
    case zoomMeetingNameObserved          = "zoom_meeting_name_observed"
    case safariTabsChanged                = "safari_tabs_changed"
    case chromeTabsChanged                = "chrome_tabs_changed"
    case arcTabsChanged                   = "arc_tabs_changed"

    // MARK: - Phase Track-4 S3 — system observers + intensity
    case intensitySnapshot                = "intensity_snapshot"
    case intensityBucketDropped           = "intensity_bucket_dropped"
    case audioRouteChanged                = "audio_route_changed"
    case micInUseEntered                  = "mic_in_use_entered"
    case micInUseExited                   = "mic_in_use_exited"
    case displayConnected                 = "display_connected"
    case displayDisconnected              = "display_disconnected"
    case vpnStateChanged                  = "vpn_state_changed"
    case wifiStateChanged                 = "wifi_state_changed"
    case clipboardEventCount              = "clipboard_event_count"
    case screenshotTaken                  = "screenshot_taken"
    case downloadAdded                    = "download_added"
    case trashChanged                     = "trash_changed"
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
        .init(key: .githubAuditActionObserved, defaultEnabled: false),

        // Phase Track-3 D3 — Slack deep sweep. All default OFF per ADR-020
        // (capture-everything locally, share-selectively).
        // Warm tier (13)
        .init(key: .slackReactionAdded, defaultEnabled: false),
        .init(key: .slackPinAdded, defaultEnabled: false),
        .init(key: .slackPinRemoved, defaultEnabled: false),
        .init(key: .slackBookmarkAdded, defaultEnabled: false),
        .init(key: .slackBookmarkRemoved, defaultEnabled: false),
        .init(key: .slackReminderCreated, defaultEnabled: false),
        .init(key: .slackReminderCompleted, defaultEnabled: false),
        .init(key: .slackMessageScheduled, defaultEnabled: false),
        .init(key: .slackMessageSentScheduled, defaultEnabled: false),
        .init(key: .slackItemSaved, defaultEnabled: false),
        .init(key: .slackItemUnsaved, defaultEnabled: false),
        .init(key: .slackChannelJoined, defaultEnabled: false),
        .init(key: .slackChannelLeft, defaultEnabled: false),
        // Cold tier (6)
        .init(key: .slackCanvasCreated, defaultEnabled: false),
        .init(key: .slackCanvasEdited, defaultEnabled: false),
        .init(key: .slackCustomEmojiAdded, defaultEnabled: false),
        .init(key: .slackUsergroupMembershipChanged, defaultEnabled: false),
        .init(key: .slackChannelRenamed, defaultEnabled: false),
        .init(key: .slackChannelArchived, defaultEnabled: false),

        // Phase Track-4 S1 — Architecture catch-up. All default OFF per
        // ADR-020 (capture-everything locally, share-selectively).
        .init(key: .meetingStateEntered, defaultEnabled: false),
        .init(key: .meetingStateExited, defaultEnabled: false),
        .init(key: .focusModeEnabled, defaultEnabled: false),
        .init(key: .focusModeDisabled, defaultEnabled: false),
        .init(key: .systemLocked, defaultEnabled: false),
        .init(key: .systemUnlocked, defaultEnabled: false),
        .init(key: .systemSlept, defaultEnabled: false),
        .init(key: .systemWoke, defaultEnabled: false),
        .init(key: .spaceSwitched, defaultEnabled: false),

        // Phase Track-4 S2 — AppleScript surface. All default OFF per ADR-020.
        .init(key: .xcodeActiveDocChanged, defaultEnabled: false),
        .init(key: .xcodeBuildStateChanged, defaultEnabled: false),
        .init(key: .jetbrainsActiveDocChanged, defaultEnabled: false),
        .init(key: .musicTrackChanged, defaultEnabled: false),
        .init(key: .spotifyTrackChanged, defaultEnabled: false),
        .init(key: .notesActiveTitleChanged, defaultEnabled: false),
        .init(key: .reminderCompleted, defaultEnabled: false),
        .init(key: .calendarAppViewChanged, defaultEnabled: false),
        .init(key: .mailActiveMailboxChanged, defaultEnabled: false),
        .init(key: .zoomMeetingStateChanged, defaultEnabled: false),
        .init(key: .zoomMeetingNameObserved, defaultEnabled: false),
        .init(key: .safariTabsChanged, defaultEnabled: false),
        .init(key: .chromeTabsChanged, defaultEnabled: false),
        .init(key: .arcTabsChanged, defaultEnabled: false),

        // Phase Track-4 S3 — system observers + intensity. All default OFF per
        // ADR-020 (capture-everything locally, share-selectively).
        .init(key: .intensitySnapshot, defaultEnabled: false),
        .init(key: .intensityBucketDropped, defaultEnabled: false),
        .init(key: .audioRouteChanged, defaultEnabled: false),
        .init(key: .micInUseEntered, defaultEnabled: false),
        .init(key: .micInUseExited, defaultEnabled: false),
        .init(key: .displayConnected, defaultEnabled: false),
        .init(key: .displayDisconnected, defaultEnabled: false),
        .init(key: .vpnStateChanged, defaultEnabled: false),
        .init(key: .wifiStateChanged, defaultEnabled: false),
        .init(key: .clipboardEventCount, defaultEnabled: false),
        .init(key: .screenshotTaken, defaultEnabled: false),
        .init(key: .downloadAdded, defaultEnabled: false),
        .init(key: .trashChanged, defaultEnabled: false)
    ]
}
