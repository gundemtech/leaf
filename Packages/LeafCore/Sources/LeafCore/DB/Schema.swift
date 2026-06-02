import Foundation

/// Namespace for table and column names. The names are public (already in architecture.md).
/// SQL bodies are not here — they live in LeafCorePrivate (moat).
public enum Schema {
    public enum Events {
        public static let tableName = "events"
        public static let id = "id"
        public static let ts = "ts"
        public static let signalType = "signal_type"
        public static let bundleID = "bundle_id"
        public static let payloadJSON = "payload_json"

        public static let indexTs = "events_ts"
        public static let indexBundleTs = "events_bundle_ts"
    }

    /// Phase 2.3 — byte-offset persistence for tail-read collectors.
    /// PK — composite (collector_id, source_id). UPSERT via `INSERT ... ON CONFLICT`.
    public enum CollectorOffsets {
        public static let tableName = "collector_offsets"
        public static let collectorID = "collector_id"
        public static let sourceID = "source_id"
        public static let byteOffset = "byte_offset"
        public static let inode = "inode"
        public static let size = "size"
        public static let lastModifiedMs = "last_modified_ms"
        public static let updatedMs = "updated_ms"
    }

    /// Phase 2.4 — user-managed list of folder paths under FSEvents watching.
    /// PK — `id` (UUID); `path` UNIQUE (canonical absolute, after resolvingSymlinksInPath).
    public enum WatchedFolders {
        public static let tableName = "watched_folders"
        public static let id = "id"
        public static let path = "path"
        public static let maxGranularity = "max_granularity"
        public static let enabled = "enabled"
        public static let addedTs = "added_ts"
        public static let updatedMs = "updated_ms"

        public static let indexEnabled = "watched_folders_enabled"
    }

    /// Phase 4.1 — OAuth credentials for third-party providers (Layer B).
    /// PK — `provider` (single-row-per-provider in MVP); multi-workspace
    /// will require lifting PK → composite (provider, workspace_id).
    public enum Integrations {
        public static let tableName = "integrations"
        public static let provider = "provider"
        public static let workspaceID = "workspace_id"
        public static let workspaceName = "workspace_name"
        public static let accessToken = "access_token"
        public static let refreshToken = "refresh_token"
        public static let expiresAtMs = "expires_at_ms"
        public static let scope = "scope"
        public static let connectedAtMs = "connected_at_ms"
        public static let updatedMs = "updated_ms"
    }

    /// Phase 4.7.A — single-row-per-provider materialized view current presence ceiling.
    /// Read by MenuBarApp (self-UI) + Phase 5 broadcaster (encrypted snapshot).
    /// PK — `provider` ('github' | 'linear' | 'slack' | 'derived'). Writes — Track B.
    public enum PresenceState {
        public static let tableName = "presence_state"
        public static let provider = "provider"
        public static let stateJSON = "state_json"
        public static let derivedMode = "derived_mode"
        public static let updatedAtMs = "updated_at_ms"
    }

    /// Phase Track-5 S2 — multi-workspace metadata table (renamed from `org`
    /// via M019). One device may host N workspaces. `created_by_member_id` —
    /// logical FK to `team_members.id` (no SQL FOREIGN KEY).
    /// `left_at_ms` IS NULL = active membership; non-NULL = soft-mark left
    /// (OQ-T5-2 resolution; data preserved, UI hides).
    /// `deleted_at_ms` IS NULL = not deleted; non-NULL = admin soft-deleted
    /// (Track 5 / S7 M025). Partial index `idx_workspaces_active` accelerates
    /// hot-path "list active workspaces" query.
    public enum Workspaces {
        public static let tableName = "workspaces"
        public static let id = "id"
        public static let name = "name"
        public static let createdAtMs = "created_at_ms"
        public static let createdByMemberID = "created_by_member_id"
        public static let leftAtMs = "left_at_ms"
        public static let deletedAtMs = "deleted_at_ms"         // Track-5 S7 M025
        public static let indexActive = "idx_workspaces_active" // Track-5 S7 M025
        // M027 — invite-redesign per-workspace defaults for new tokens.
        public static let defaultInviteTtlSeconds = "default_invite_ttl_seconds"
        public static let defaultSingleUse        = "default_single_use"
    }

    /// M027 — admin-generated invite tokens (closed-mode workspace gate).
    /// Local SQLCipher mirror of the Supabase row for admin's own workspace
    /// tokens — used for instant Active-tokens UI. Refreshed on workspace open
    /// + on admin generate/delete action.
    /// `code` PK — `LEAF-XXXX-XXXX-XXXX` 19-char base32 (excludes I/L/O/U/0/1).
    /// `expires_at_ms` IS NULL = never expires. `max_uses` IS NULL = unlimited.
    /// `deleted_at_ms` IS NULL = active; non-NULL = soft-deleted (row stays for audit).
    public enum InviteTokens {
        public static let tableName       = "invite_tokens"
        public static let code            = "code"
        public static let workspaceID     = "workspace_id"
        public static let createdByPubkey = "created_by_pubkey"
        public static let label           = "label"
        public static let ttlSeconds      = "ttl_seconds"
        public static let expiresAtMs     = "expires_at_ms"
        public static let maxUses         = "max_uses"
        public static let usedCount       = "used_count"
        public static let deletedAtMs     = "deleted_at_ms"
        public static let createdAtMs     = "created_at_ms"

        public static let indexWorkspaceActive = "idx_invite_tokens_workspace_active"
    }

    /// Phase 5.1.A — long-term member identity + X25519 public key (contract §4, §7).
    /// PK — `id` UUID v4. `org_id` — logical FK to `org.id`.
    /// `removed_at_ms` IS NULL = active member; set in Phase 5.3
    /// on removal (contract §10). `role` — `TeamMemberRole.rawValue` ('admin' | 'member').
    /// `pubkey_hex` — X25519 32-byte public, hex-encoded (64 chars).
    public enum TeamMembers {
        public static let tableName = "team_members"
        public static let id = "id"
        public static let workspaceID = "workspace_id"           // Track-5 S2 rename (M019)
        public static let role = "role"
        public static let pubkeyHex = "pubkey_hex"
        public static let displayName = "display_name"
        public static let addedAtMs = "added_at_ms"
        public static let removedAtMs = "removed_at_ms"

        /// Partial index — active members per workspace for the Team UI list.
        public static let indexWorkspaceActive = "team_members_workspace_active"
    }

    /// Phase 5.1.A — team key rotation history (contract §7).
    /// PK — `id` UUID v4 (rotation identity; embedded as 16-byte `keyID` in envelope §6).
    /// `deprecated_at_ms` IS NULL = current rotation; set in Phase 5.3.
    /// `generated_by_member_id` — logical FK to `team_members.id` (audit who created rotation).
    /// **Forever-retained** — old rows are needed to decrypt `presence_history` (contract §12).
    public enum TeamKeys {
        public static let tableName = "team_keys"
        public static let id = "id"
        public static let workspaceID = "workspace_id"           // Track-5 S2 (M019)
        public static let generatedAtMs = "generated_at_ms"
        public static let deprecatedAtMs = "deprecated_at_ms"
        public static let generatedByMemberID = "generated_by_member_id"

        /// Partial index — query "current key" cheaply (1 row).
        public static let indexActive = "team_keys_active"
    }

    /// Phase 5.3.D — admin-side write-ahead journal of pending key-rotation POSTs.
    /// Composite PK `(peer_pubkey_hex, new_key_id)` matches relay's idempotency
    /// key (5.3.C). `posted_at_ms IS NULL` means the POST has not yet succeeded;
    /// `KeyRotationService.resumePendingPosts()` retries on next launch.
    /// `kind` — `'rotation'` (wrapped new teamKey) or `'tombstone'` (sentinel for removed peer).
    public enum RotationOutbox {
        public static let tableName = "rotation_outbox"
        public static let peerPubkeyHex = "peer_pubkey_hex"
        public static let newKeyID = "new_key_id"
        public static let workspaceID = "workspace_id"           // Track-5 S2 (M019)
        public static let priorKeyID = "prior_key_id"
        public static let kind = "kind"
        public static let peerMemberID = "peer_member_id"
        public static let blob = "blob"
        public static let expiresAtMs = "expires_at_ms"
        public static let createdAtMs = "created_at_ms"
        public static let postedAtMs = "posted_at_ms"

        /// Partial index — query "unposted rows" cheap (drained on launch via Task.detached).
        public static let indexUnposted = "rotation_outbox_unposted"
    }

    /// Phase 5.5.A — admin-side cache of issued invites (token + OTP + invitee
    /// pubkey hint). One row per active invite; lifecycle in `PendingInviteStatus`.
    /// PK — `token` (32-char base64url, unique per relay). OTP at rest acceptable
    /// (same SQLCipher DB as teamKey, no incremental risk).
    public enum PendingInvites {
        public static let tableName = "pending_invites"
        public static let token = "token"
        public static let workspaceID = "workspace_id"           // Track-5 S2 (M019)
        public static let otp = "otp"
        public static let inviteePubkeyHex = "invitee_pubkey_hex"
        public static let inviteeDisplayNameHint = "invitee_display_name_hint"
        public static let createdAtMs = "created_at_ms"
        public static let expiresAtMs = "expires_at_ms"
        public static let status = "status"
        public static let lastPolledAtMs = "last_polled_at_ms"

        public static let indexStatus = "idx_pending_invites_status"
    }

    /// Phase Track-5 S4 — direct messages local mirror (recipient + sender's
    /// own timeline). One row per message_id. `direction` discriminates
    /// outbound (sender's row) vs inbound (recipient's row). Forever retention.
    /// Encrypted payload not stored here — only decrypted plaintext columns.
    public enum MessagesMirror {
        public static let tableName = "messages_mirror"
        public static let messageID = "message_id"
        public static let workspaceID = "workspace_id"
        public static let senderPubkeyHex = "sender_pubkey_hex"
        public static let senderMemberID = "sender_member_id"
        public static let senderDisplayName = "sender_display_name"
        public static let recipientPubkeyHex = "recipient_pubkey_hex"
        public static let kind = "kind"
        public static let body = "body"
        public static let attachmentKind = "attachment_kind"
        public static let attachmentExternalRef = "attachment_external_ref"
        public static let replyTo = "reply_to"
        public static let sentAtMs = "sent_at_ms"
        public static let serverCreatedAtMs = "server_created_at_ms"
        public static let readAtMs = "read_at_ms"
        public static let doneAtMs = "done_at_ms"
        public static let doneByPubkeyHex = "done_by_pubkey_hex"
        public static let direction = "direction"
        public static let lastSyncedAtMs = "last_synced_at_ms"

        public static let indexWorkspaceRecent = "idx_messages_mirror_workspace_recent"
        public static let indexUnread = "idx_messages_mirror_unread"
        public static let indexOpenTasks = "idx_messages_mirror_open_tasks"

        /// Track 5 / S8 / T1 — pending Mark Done retry queue flag (M026 ALTER).
        /// 1 when APNs dm.markDone optimistic-update succeeded locally but the
        /// server PATCH failed — background retry until success or row delete.
        public static let pendingMarkDone = "pending_mark_done"
        public static let indexPendingMarkDone = "idx_messages_mirror_pending_mark_done"

        public static let directionOutbound = "outbound"
        public static let directionInbound = "inbound"
    }

    /// Phase Track-5 S4 — singleton-per-device APNs token row, mirroring the
    /// Supabase `apns_tokens` row owned by this Mac. `server_synced_at_ms`
    /// IS NULL = locally captured but not yet pushed to Supabase; retried on
    /// next launch / scenePhase=active.
    public enum APNsTokenLocal {
        public static let tableName = "apns_token_local"
        public static let deviceID = "device_id"
        public static let apnsToken = "apns_token"
        public static let environment = "environment"
        public static let registeredAtMs = "registered_at_ms"
        public static let lastPushedAtMs = "last_pushed_at_ms"
        public static let serverSyncedAtMs = "server_synced_at_ms"

        public static let environmentDevelopment = "development"
        public static let environmentProduction = "production"
    }

    /// Phase Track-5 S5 — per-source share toggle persistence. Row absent →
    /// `ShareRuleDefaults` semantics apply. PK (workspace_id, source_kind).
    /// `source_kind` value space lives in `ShareSource.rawValue`; CHECK constraint
    /// intentionally omitted (registry source of truth is Swift enum, mirroring
    /// `share_event_types` design comment in ShareEventTypeRegistry.swift).
    public enum ShareRules {
        public static let tableName = "share_rules"
        public static let workspaceID = "workspace_id"
        public static let sourceKind = "source_kind"
        public static let enabled = "enabled"
        public static let updatedAtMs = "updated_at_ms"

        public static let indexWorkspace = "idx_share_rules_workspace"
    }

    /// Track 5 / S8 / T1 — per-device notification preferences (M026).
    /// Mirrors `ShareRules` normalized per-row + defaults map fallback pattern, but
    /// keyed on a single `pref_kind` column (no workspace_id — toggles are
    /// device-wide). Row absent → `NotificationKind.defaultEnabled` semantics.
    /// `pref_kind` value space lives in `NotificationKind.rawValue`; CHECK constraint
    /// intentionally omitted (registry source of truth is the Swift enum, mirroring
    /// `ShareRules` design comment).
    public enum NotificationPrefs {
        public static let tableName = "notification_prefs"
        public static let prefKind = "pref_kind"
        public static let enabled = "enabled"
        public static let updatedAtMs = "updated_at_ms"
    }

    /// Phase Track-5 S5 — auto-shared events local mirror (incoming from
    /// teammates). Composite PK (workspace_id, event_id). Forever retention here
    /// is bounded by `TeamEventMirrorRetentionPruner` (90d default).
    public enum TeamEventsMirror {
        public static let tableName = "team_events_mirror"
        public static let eventID = "event_id"
        public static let workspaceID = "workspace_id"
        public static let senderPubkeyHex = "sender_pubkey_hex"
        public static let sourceKind = "source_kind"
        public static let kind = "kind"
        public static let plaintextPayloadJSON = "plaintext_payload_json"
        public static let serverCreatedAtMs = "server_created_at_ms"
        public static let eventTsMs = "event_ts_ms"
        public static let receivedAtMs = "received_at_ms"

        public static let indexWorkspaceCreated = "idx_team_events_mirror_workspace_created"
        public static let indexSender = "idx_team_events_mirror_sender"
    }

    /// Phase Track-5 S5 — per-workspace cursor for `TeamEventBroadcastService`.
    /// One row per workspace. `cursor_event_id` advances monotonically over
    /// `events.id` integers.
    public enum TeamEventBroadcastOffsets {
        public static let tableName = "team_event_broadcast_offsets"
        public static let workspaceID = "workspace_id"
        public static let cursorEventID = "cursor_event_id"
        public static let lastAttemptAtMs = "last_attempt_at_ms"
        public static let lastSuccessAtMs = "last_success_at_ms"
        public static let consecutiveFailures = "consecutive_failures"
    }

    /// Phase Track-5 S5 — `ShareSource.rawValue` mirror, in Schema namespace for
    /// non-Swift consumers (SQL queries, debug dumps). Kept lockstep with the
    /// `ShareSource` enum cases in `LeafCore/Team/ShareSource.swift` (only single
    /// source of truth).
    public enum ShareSources {
        public static let gitCommits = "git_commits"
        public static let linearIssues = "linear_issues"
        public static let slackMentions = "slack_mentions"
        public static let githubPRs = "github_prs"
        public static let detectedDecisions = "detected_decisions"
        public static let detectedBlockers = "detected_blockers"
        public static let detectedOpenQuestions = "detected_open_questions"
        public static let detectedWhereStopped = "detected_where_stopped"
        public static let rawGitHubActivity = "raw_github_activity"
    }

    /// Phase Track-1 D1 — canonical names for new payload keys carrying bodies +
    /// attachment metadata + Phase 4.8 PR metrics. Single source of truth for
    /// collectors + D2 FTS5 + D3 detector query paths.
    ///
    /// Note: these are JSON keys inside the `events.payload_json` blob — not
    /// column names like the sibling enums in this namespace.
    public enum EventPayloadKeys {
        public static let body = "body"
        public static let bodyTruncated = "body_truncated"
        public static let attachmentsJson = "attachments_json"
        public static let commentBodiesJson = "comment_bodies_json"
        public static let threadRepliesJson = "thread_replies_json"
        public static let messagesJson = "messages_json"
        // GitHub PR metadata (Phase 4.8 carry-over)
        public static let filesCount = "files_count"
        public static let additions = "additions"
        public static let deletions = "deletions"
        public static let requestedReviewersJson = "requested_reviewers_json"
        public static let mentionCount = "mention_count"
        public static let linkCount = "link_count"
        // Phase Track-3 D1 — Linear deep sweep payload keys.
        // Snapshot-diff derived events use `observedAtMs` (= nowMs);
        // Linear-side timestamps use specific field names.
        public static let notificationId = "notification_id"
        public static let notificationKind = "notification_kind"
        public static let notificationTitle = "notification_title"
        public static let issueId = "issue_id"
        public static let issueIdentifier = "issue_identifier"
        public static let commentId = "comment_id"
        public static let relationId = "relation_id"
        public static let fromIssueId = "from_issue_id"
        public static let fromIssueIdentifier = "from_issue_identifier"
        public static let toIssueId = "to_issue_id"
        public static let toIssueIdentifier = "to_issue_identifier"
        public static let relationKind = "relation_kind"
        public static let emoji = "emoji"
        public static let teamId = "team_id"
        public static let toStateName = "to_state_name"
        public static let toStateType = "to_state_type"
        public static let resolutionKind = "resolution_kind"
        public static let cycleId = "cycle_id"
        public static let cycleNumber = "cycle_number"
        public static let cycleName = "cycle_name"
        public static let viewId = "view_id"
        public static let viewName = "view_name"
        public static let roadmapId = "roadmap_id"
        public static let roadmapName = "roadmap_name"
        public static let projectId = "project_id"
        public static let projectName = "project_name"
        public static let stateEnum = "state_enum"
        public static let issuesCompletedCount = "issues_completed_count"
        public static let progress = "progress"
        public static let observedAtMs = "observed_at_ms"
        public static let receivedAtMs = "received_at_ms"
        public static let readAtMs = "read_at_ms"
        public static let archivedAtMs = "archived_at_ms"
        public static let reactedAtMs = "reacted_at_ms"
        public static let startedAtMs = "started_at_ms"
        public static let endsAtMs = "ends_at_ms"
        public static let completedAtMs = "completed_at_ms"
        public static let removedAtMs = "removed_at_ms"
        // Phase Track-3 D2 — GitHub D2 payload keys.
        public static let prReviewState = "pr_review_state"
        public static let workflowName = "workflow_name"
        public static let workflowRef = "workflow_ref"
        public static let deploymentEnvironment = "deployment_environment"
        public static let deploymentState = "deployment_state"
        public static let repositoryVisibility = "repository_visibility"
        public static let forkeeFullName = "forkee_full_name"
        public static let gistId = "gist_id"
        public static let gistDescription = "gist_description"
        public static let projectV2Id = "projectv2_id"
        public static let projectV2CardId = "projectv2_card_id"
        public static let projectV2FieldName = "projectv2_field_name"
        public static let projectV2OldValue = "projectv2_old_value"
        public static let projectV2NewValue = "projectv2_new_value"
        public static let iterationId = "iteration_id"
        public static let codespaceName = "codespace_name"
        public static let codespaceState = "codespace_state"
        public static let repoInvitationId = "repo_invitation_id"
        public static let repoInvitationFromLogin = "repo_invitation_from_login"
        public static let repoFullName = "repo_full_name"
        public static let reactionEmoji = "reaction_emoji"
        public static let reactionCount = "reaction_count"
        public static let reactionDelta = "reaction_delta"
        public static let alertNumber = "alert_number"
        public static let alertSeverity = "alert_severity"
        public static let alertRule = "alert_rule"
        public static let dependabotPackageName = "dependabot_package_name"
        public static let auditAction = "audit_action"
        public static let auditActorLogin = "audit_actor_login"
        // Phase Track-3 D3 — Slack warm/cold payload keys.
        public static let workspaceId = "workspace_id"
        public static let userId = "user_id"
        public static let channelId = "channel_id"
        public static let channelName = "channel_name"
        public static let itemRef = "item_ref"
        public static let emojiBucket = "emoji_bucket"
        public static let pinnedAtMs = "pinned_at_ms"
        public static let bookmarkId = "bookmark_id"
        public static let bookmarkTitle = "title"
        public static let bookmarkURL = "url"
        public static let lastEditedMs = "last_edited_ms"
        public static let reminderId = "reminder_id"
        public static let dueTs = "due_ts"
        public static let completedTs = "completed_ts"
        public static let scheduledMessageId = "scheduled_message_id"
        public static let scheduledFor = "scheduled_for"
        public static let savedAtMs = "saved_at_ms"
        // Slack D3 cold-tier (Task 14).
        public static let canvasId = "canvas_id"
        public static let emojiName = "emoji_name"
        public static let groupId = "group_id"
        public static let addedUserIdsJson = "added_user_ids_json"
        public static let removedUserIdsJson = "removed_user_ids_json"
        public static let oldName = "old_name"
        public static let newName = "new_name"

        // Phase Track-4 S2 — AppleScript surface payload keys.
        public static let docPath = "doc_path"
        public static let project = "project"
        public static let scheme = "scheme"
        public static let buildState = "build_state"
        public static let ideBundleID = "ide_bundle_id"
        public static let track = "track"
        public static let artist = "artist"
        public static let playerState = "player_state"
        public static let noteTitle = "note_title"
        public static let listName = "list_name"
        public static let completedCountDelta = "completed_count_delta"
        public static let viewMode = "view_mode"
        public static let visibleDateRangeDays = "visible_date_range_days"
        public static let mailboxName = "mailbox_name"
        public static let meetingState = "meeting_state"
        public static let meetingTopic = "meeting_topic"
        public static let tabs = "tabs"
        public static let activeWindowID = "active_window_id"
        public static let tabTitle = "title"
        public static let tabURL = "url"
        public static let browser = "browser"

        // Phase Track-4 S3 — system observers + intensity payload keys.
        // (`state` / `count` / `filename` / `action` already canonical baseline.)
        public static let keystrokeCount = "keystroke_count"
        public static let mouseMoveCount = "mouse_move_count"
        public static let appSwitchCount = "app_switch_count"
        public static let foregroundApp = "foreground_app"
        public static let audioRoute = "audio_route"

        // Phase Track-6 P5 — Zoom meeting → calendar event cross-link.
        // SHA256(EKEvent.eventIdentifier)[:16] hex string; opaque target_ref.
        public static let linkedCalendarEventID = "linked_calendar_event_id"
    }

    /// Phase Track-4 S3 — per-minute intensity aggregates (CGEventTap counter-only).
    /// PK — `minute_bucket_ms` (minute-truncated wall clock). UPSERT replaces existing
    /// bucket so re-emission on restart is safe. Counter fields counter-only —
    /// NEVER include keycode/characters/modifierFlags per ADR-010 Won't-list.
    public enum IntensityAggregates {
        public static let tableName = "intensity_aggregates"
        public static let minuteBucketMs = "minute_bucket_ms"
        public static let keystrokes = "keystrokes"
        public static let mouseMoves = "mouse_moves"
        public static let appSwitches = "app_switches"
        public static let foregroundApp = "foreground_app"
    }

    /// Phase Track-1 D2 — FTS5 contentless virtual table over event bodies
    /// (commit_msg / linear_desc / linear_comment / slack_msg / slack_thread_*
    /// / gh_pr / gh_issue_comment / gh_pr_review_comment).
    public enum EventsFTS {
        public static let tableName = "events_fts"
        public static let body = "body"
        public static let bodyKind = "body_kind"
        public static let eventID = "event_id"
    }

    /// Phase Track-1 D2 — sidecar table mapping FTS5 rowid → (event_id, body_kind).
    /// Contentless `events_fts` does not retain UNINDEXED column values, so the
    /// side table is the source of truth for retrieval after MATCH (search() join +
    /// D3 reverse-lookup). Composite write is atomic in `EventsFullTextStore.indexEvent`.
    public enum EventsFTSMeta {
        public static let tableName = "events_fts_meta"
        public static let ftsRowID = "fts_rowid"
        public static let eventID = "event_id"
        public static let bodyKind = "body_kind"

        public static let indexEventID = "idx_events_fts_meta_event_id"
    }

    /// Phase Track-1 D2 — body provenance tags. Single source of truth between
    /// EventsFullTextStore body extraction + D3 query path filter clauses.
    public enum BodyKinds {
        public static let commitMsg = "commit_msg"
        public static let linearDesc = "linear_desc"
        public static let linearComment = "linear_comment"
        public static let slackMsg = "slack_msg"
        public static let slackThreadParent = "slack_thread_parent"
        public static let slackThreadReply = "slack_thread_reply"
        public static let ghPR = "gh_pr"
        public static let ghIssueComment = "gh_issue_comment"
        public static let ghPRReviewComment = "gh_pr_review_comment"
        // Phase Track-3 D1 — Linear notification titles routed through FTS.
        public static let linearNotificationTitle = "linear_notification_title"
        // Phase Track-3 D2 — GitHub D2 body provenance.
        public static let ghGistDescription = "gh_gist_description"
        public static let ghReleaseBody = "gh_release_body"
        public static let ghDeploymentDescription = "gh_deployment_description"
        // Phase Track-3 D3 — Slack body provenance (canvas + bookmark titles per ADR-010 §6).
        public static let slackCanvasTitle = "slack_canvas_title"
        public static let slackBookmarkTitle = "slack_bookmark_title"
        // Phase Track-4 S4 — user-authored title/filename body provenance.
        // ADR-010 commit-message precedent: user-namespace labels are allowed
        // through FTS while bodies / previews / message texts remain forbidden.
        public static let notesTitle = "notes_title"
        public static let zoomMeetingName = "zoom_meeting_name"
        public static let screenshotFilename = "screenshot_filename"
        public static let downloadFilename = "download_filename"
    }

    /// Phase Track-1 D2 — cross-source association graph row.
    /// Composite PK `(from_event_id, link_kind, target_ref)` dedupes per-event-per-target.
    /// `from_event_id` — logical FK to `events.id` (no SQL FOREIGN KEY per repo
    /// convention). Reverse index supports D3 query "events linked to target X".
    public enum EventLinks {
        public static let tableName = "event_links"
        public static let fromEventID = "from_event_id"
        public static let linkKind = "link_kind"
        public static let targetKind = "target_kind"
        public static let targetRef = "target_ref"
        public static let confidence = "confidence"
        public static let createdAtMs = "created_at_ms"

        public static let indexTarget = "idx_event_links_target"
    }

    /// Phase Track-1 D2 — link_kind discriminators. Numeric confidence values
    /// are private (LeafCorePrivate `LinkConfidence`).
    public enum LinkKinds {
        public static let linearIDInText = "linear_id_in_text"
        public static let branchNameLinearRef = "branch_name_linear_ref"
        public static let prURLInSlack = "pr_url_in_slack"
        public static let prNumberHashRef = "pr_number_hash_ref"
        public static let reviewerAssigned = "reviewer_assigned"
        /// Track-6 P5 — Zoom meeting matched to a concurrent calendar event via
        /// EventKit URL regex. Target ref = SHA256(EKEvent.eventIdentifier)[:16].
        public static let zoomToCalendarMeeting = "zoom_to_calendar_meeting"
    }

    /// Phase Track-1 D2 — target_kind discriminators for `event_links.target_kind`.
    public enum TargetKinds {
        public static let linearIssue = "linear_issue"
        public static let githubPR = "github_pr"
        public static let githubUser = "github_user"
        /// Track-6 P5 — Anonymized calendar event reference (SHA256 hash, source-agnostic).
        public static let calendarEvent = "calendar_event"
    }

    /// Phase Track-1 D3 — decision detector hits (one row per source event).
    /// `event_id` — logical FK to `events.id` (UNIQUE — per-event idempotency).
    /// SQL FOREIGN KEY is not declared (repo convention — see M013_EventLinks).
    public enum Decisions {
        public static let tableName = "decisions"
        public static let id = "id"
        public static let eventID = "event_id"
        public static let topicKeywordsJSON = "topic_keywords_json"
        public static let reasoningExcerpt = "reasoning_excerpt"
        public static let confidence = "confidence"
        public static let detectedAtMs = "detected_at_ms"

        public static let indexDetectedAt = "idx_decisions_detected_at"
    }

    /// Phase Track-1 D3 — open question detector hits + resolution flow.
    /// `event_id` UNIQUE (per-event idempotency). `resolved_by_event_id` —
    /// nullable logical FK to `events.id`, populated when a resolving event
    /// is matched (see resolution flow in DetectorPipeline).
    public enum OpenQuestions {
        public static let tableName = "open_questions"
        public static let id = "id"
        public static let eventID = "event_id"
        public static let questionExcerpt = "question_excerpt"
        public static let alternativesJSON = "alternatives_json"
        public static let slackThreadTs = "slack_thread_ts"
        public static let linearIssueRef = "linear_issue_ref"
        public static let githubPRRef = "github_pr_ref"
        public static let resolvedByEventID = "resolved_by_event_id"
        public static let openedAtMs = "opened_at_ms"
        public static let resolvedAtMs = "resolved_at_ms"

        public static let indexUnresolved = "idx_open_questions_unresolved"
        public static let indexSlack = "idx_open_questions_slack"
        public static let indexLinear = "idx_open_questions_linear"
        public static let indexPR = "idx_open_questions_pr"
    }

    /// Phase Track-1 D3 — blocker hits (one OPEN blocker per
    /// `(target_kind, target_ref)`, partial unique index `idx_blockers_open`).
    /// Resolved rows are excluded from uniqueness — allows reopening a
    /// blocker after resolve. `detected_by_event_id` / `resolved_by_event_id` —
    /// nullable logical FKs to `events.id`.
    public enum Blockers {
        public static let tableName = "blockers"
        public static let id = "id"
        public static let targetKind = "target_kind"
        public static let targetRef = "target_ref"
        public static let blockerKind = "blocker_kind"
        public static let blockerExcerpt = "blocker_excerpt"
        public static let detectedByEventID = "detected_by_event_id"
        public static let startedAtMs = "started_at_ms"
        public static let resolvedAtMs = "resolved_at_ms"
        public static let resolvedByEventID = "resolved_by_event_id"

        public static let indexOpen = "idx_blockers_open"
        public static let indexTarget = "idx_blockers_target"
    }

    /// Phase Track-1 D3 — append-only "where I stopped" snapshots generated by
    /// `WhereStoppedDeriver` (scheduled detector). `anchor_event_id` — nullable
    /// logical FK to `events.id` (anchor may be a derived window without a single
    /// canonical event).
    public enum WhereStoppedLog {
        public static let tableName = "where_stopped_log"
        public static let id = "id"
        public static let generatedAtMs = "generated_at_ms"
        public static let anchorEventID = "anchor_event_id"
        public static let excerpt = "excerpt"
        public static let wipSignalsJSON = "wip_signals_json"

        public static let indexGeneratedAt = "idx_where_stopped_generated_at"
    }

    /// Phase Track-1 D3 — per-detector progress cursor for the incremental
    /// per-event detector pipeline. PK — `detector_kind`. Pre-seeded in the
    /// migration with three rows (`decision`, `open_question`,
    /// `blocker_pattern`). Scheduled detectors (linear_stuck, where_stopped)
    /// do not use a cursor.
    public enum DetectorOffsets {
        public static let tableName = "detector_offsets"
        public static let detectorKind = "detector_kind"
        public static let cursorEventID = "cursor_event_id"
        public static let lastRunAtMs = "last_run_at_ms"
    }

    /// Phase Track-1 D3 — `detector_kind` discriminators for
    /// `detector_offsets.detector_kind`. Single source of truth between the
    /// migration pre-seed + DetectorPipeline cursor reads.
    public enum DetectorKinds {
        public static let decision = "decision"
        public static let openQuestion = "open_question"
        public static let blockerPattern = "blocker_pattern"
    }

    /// Phase Track-1 D3 — `blocker_kind` discriminators for `blockers.blocker_kind`.
    /// Single source of truth between BlockersStore callers (per-event pattern
    /// detector + scheduled LinearStuck scanner) and downstream readers.
    public enum BlockerKinds {
        public static let patternBlockedOn = "pattern_blocked_on"
        public static let linearStuck = "linear_stuck"
    }

    /// Phase Track-3 D1 — generic per-provider state snapshot table.
    /// Composite PK `(provider, snapshot_kind)`. snapshot_json holds JSON-encoded
    /// snapshot bodies used for delta-mode collectors (subscribed issues / custom
    /// views / project memberships / roadmaps). D2+ may add new provider/kind
    /// combinations without further migration.
    public enum ProviderSnapshots {
        public static let tableName = "provider_snapshots"
        public static let provider = "provider"
        public static let snapshotKind = "snapshot_kind"
        public static let snapshotJSON = "snapshot_json"
        public static let capturedAtMs = "captured_at_ms"
    }

    /// Phase Track-3 D1 — canonical snapshot_kind values used by Linear warm/cold
    /// collectors. Centralized to keep collector code + tests in sync without
    /// repeating raw string literals.
    public enum ProviderSnapshotKinds {
        public static let linearSubscribedIssues = "linear_subscribed_issues"
        public static let linearCustomViews = "linear_custom_views"
        public static let linearProjectMemberships = "linear_project_memberships"
        public static let linearRoadmapState = "linear_roadmap_state"

        // GitHub D2 — singleton snapshot kinds (no per-key suffix).
        public static let githubStarredRepos = "github_starred_repos"
        public static let githubWatchedRepos = "github_watched_repos"
        public static let githubGists = "github_gists"
        public static let githubCodespaces = "github_codespaces"
        public static let githubRepoInvitations = "github_repo_invitations"
        public static let githubAuditCursor = "github_audit_cursor" // Cursor (last-processed audit event id), not state snapshot

        // GitHub D2 — parameterized snapshot kind prefixes (composite key embedded in value).
        // Callers compose: `Schema.ProviderSnapshotKinds.githubProjectV2ItemsPrefix + projectID`.
        public static let githubProjectV2ItemsPrefix = "github_projectv2_items:"
        public static let githubIssueReactionsPrefix = "github_issue_reactions:"
        public static let githubSecretAlertsPrefix = "github_secret_alerts:"
        public static let githubCodeAlertsPrefix = "github_code_alerts:"
        public static let githubDependabotAlertsPrefix = "github_dependabot_alerts:"

        // Slack D3 — warm-tier (15m) snapshot kinds. Per-channel fans live under
        // singleton snapshots as JSON arrays of channel-keyed records.
        //
        // `slackMemberChannels` holds the FULL set of member channels (not a
        // top-10 cap) — diff source for `slack_channel_joined/_left`. Top-10
        // fan-out cap is applied AT FAN-OUT TIME (pins/bookmarks per-channel,
        // cold conversations.info) via `rankTop10ByLatestTs`, never to the
        // persisted snapshot. C3 review fix (D3 follow-up): persisting the
        // top-10 cap caused false-positive join/left events whenever a member
        // channel slid out of the top-10 ranking by activity.
        public static let slackMemberChannels = "slack_member_channels"
        public static let slackPinsPerChannel = "slack_pins_per_channel"
        public static let slackBookmarksPerChannel = "slack_bookmarks_per_channel"
        public static let slackReminders = "slack_reminders"
        public static let slackScheduledMessages = "slack_scheduled_messages"
        public static let slackStars = "slack_stars"

        // Slack D3 — cold-tier (4am local daily) snapshot kinds.
        public static let slackCanvasesPerChannel = "slack_canvases_per_channel"
        public static let slackEmojiList = "slack_emoji_list"
        public static let slackUsergroups = "slack_usergroups"
        public static let slackChannelsInfo = "slack_channels_info"
    }

    /// Track-6 P3 — per-domain allow-list for browser URL granularity control.
    /// Default empty; non-matching domains resolve to `domainOnly` at filter time.
    /// Migration M029 (renamed from M026 — slot M026 occupied by Track-5/S8
    /// substrate on integration-T10).
    public enum BrowserDomainAllow {
        public static let tableName = "browser_domain_allow"
        public static let domain = "domain"
        public static let granularity = "granularity"
        public static let addedAtMs = "added_at_ms"
        public static let notes = "notes"
    }

    /// Phase Track-6 P4 — `google_calendar_typed_event_tracker` per-event row
    /// tracking clock-driven `_started` / `_ended` / `_changed` transitions for
    /// Google Calendar `eventType IN (focusTime, outOfOffice, workingLocation)`.
    public enum GoogleCalendarTracker {
        public static let tableName = "google_calendar_typed_event_tracker"
        public static let eventID = "event_id"
        public static let calendarID = "calendar_id"
        public static let iCalUID = "i_cal_uid"
        public static let eventType = "event_type"
        public static let startMs = "start_ms"
        public static let endMs = "end_ms"
        public static let startedEmittedAtMs = "started_emitted_at_ms"
        public static let endedEmittedAtMs = "ended_emitted_at_ms"
        public static let workingLocationType = "working_location_type"
        // Active-phase metadata sourced from the original Google API Event's
        // focusTimeProperties / outOfOfficeProperties (autoDeclineMode applies
        // to both; chatStatus only to focusTime). Persisted on the tracker so
        // the Task 14 transition scan can rebuild `_started` payloads without
        // re-fetching the Event. ADR-010: both are public Google enum buckets
        // (none / declineOnlyNewConflictingInvitations / declineAllConflictingInvitations
        // for autoDeclineMode; doNotDisturb for chatStatus), not freeform text.
        public static let autoDeclineMode = "auto_decline_mode"
        public static let chatStatus = "chat_status"
        public static let upsertedAtMs = "upserted_at_ms"
    }
}

/// Canonical `collector_id` values. The literals are public so that tests
/// and the Agent can pass the same IDs (single source of truth).
public enum CollectorID {
    /// Phase 2.3 — Claude Code session jsonl tail-reader.
    public static let claudeCodeJSONL = "claude_code_jsonl"
    /// Phase 2.4 — FSEvents content collector. Not used for offsets
    /// (FSEvents is stream-based, not tail-read), but appears in diagnostic logs.
    public static let fsEvents = "fs_events"
    /// Phase 4.2 — Linear GraphQL polling collector. `sourceID = "linear:<workspaceID>"`.
    /// `lastModifiedMs` holds the cursor (epoch ms newest processed `updatedAt`).
    public static let linearPolling = "linear_polling"
    /// Phase 4.3 — GitHub REST events polling collector. `sourceID = "github:<login>"`.
    /// `lastModifiedMs` holds the cursor (epoch ms newest processed event `created_at`).
    public static let githubPolling = "github_polling"
    /// Phase 4.4 — Slack REST polling collector. `sourceID = "slack:<team_id>:<user_id>"`.
    /// `lastModifiedMs` holds the cursor (epoch ms newest processed message `ts`).
    public static let slackPolling = "slack_polling"
    /// Phase Track-3 D1 — Linear warm-tier (15m) state sweep:
    /// notifications + cycles + subscribed_issues. sourceID format:
    /// `linear:notifications:<workspaceID>`, `linear:cycles:<workspaceID>`.
    public static let linearWarmPolling = "linear_warm_polling"
    /// Phase Track-3 D1 — Linear cold-tier (4am local) state sweep:
    /// roadmaps + customViews + projectMemberships. sourceID:
    /// `linear:cold:<workspaceID>`. `lastModifiedMs` holds last cold tick ms
    /// (catch-up gate uses `now - lastModifiedMs > 24h` to trigger immediate tick).
    public static let linearColdPolling = "linear_cold_polling"
    /// Phase Track-3 D2 — GitHub warm-tier (15m): projectsV2 + gists + invitations
    /// + codespaces + issue-reactions. sourceID `github:warm:<login>`.
    public static let githubWarmPolling = "github_warm_polling"
    /// Phase Track-3 D2 — GitHub cold-tier (4am local). sourceID `github:cold:<login>`.
    /// `lastModifiedMs` holds last cold tick ms (catch-up gate uses
    /// `now - lastModifiedMs > 24h`).
    public static let githubColdPolling = "github_cold_polling"
    /// Phase Track-3 D3 — Slack warm-tier (15m): reactions + pins + bookmarks +
    /// reminders + scheduled + stars + user.conversations. sourceID `slack:warm:<workspaceID>`.
    public static let slackWarmPolling = "slack_warm_polling"
    /// Phase Track-3 D3 — Slack cold-tier (4am local). sourceID `slack:cold:<workspaceID>`.
    /// `lastModifiedMs` holds last cold tick ms (catch-up gate uses
    /// `now - lastModifiedMs > 24h`).
    public static let slackColdPolling = "slack_cold_polling"
}

/// Canonical `provider` values for the `integrations` table. The literals are
/// public, single source of truth between the OAuth service, DB and (Phase 4.2+) collectors.
public enum IntegrationProvider: String, Sendable, Hashable, CaseIterable {
    case linear
    case github
    case slack
    case googleCalendar = "google_calendar"  // Track-6 P4
}
