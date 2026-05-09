import Foundation

/// Namespace для имён таблиц и колонок. Имена публичны (уже в architecture.md).
/// SQL тела — не здесь, живут в LeafCorePrivate (moat).
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

    /// Phase 2.3 — byte-offset persistence для tail-read collector'ов.
    /// PK — composite (collector_id, source_id). UPSERT через `INSERT ... ON CONFLICT`.
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

    /// Phase 2.4 — user-managed list folder paths под FSEvents-наблюдением.
    /// PK — `id` (UUID); `path` UNIQUE (canonical absolute, после resolvingSymlinksInPath).
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

    /// Phase 4.1 — OAuth credentials для third-party providers (Layer B).
    /// PK — `provider` (single-row-per-provider в MVP); multi-workspace
    /// потребует lift PK → composite (provider, workspace_id).
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

    /// Phase 5.1.A — organization metadata (1 row per device, single-org-per-device
    /// per Phase 5 architecture contract §11). PK — `id` UUID v4.
    /// `created_by_member_id` — logical FK на `team_members.id`; SQL FOREIGN KEY
    /// не объявляется (см. spec 5.1.A §4 "FK strategy").
    public enum Org {
        public static let tableName = "org"
        public static let id = "id"
        public static let name = "name"
        public static let createdAtMs = "created_at_ms"
        public static let createdByMemberID = "created_by_member_id"
    }

    /// Phase 5.1.A — long-term member identity + X25519 public key (contract §4, §7).
    /// PK — `id` UUID v4. `org_id` — logical FK на `org.id`.
    /// `removed_at_ms` IS NULL = active member; устанавливается в Phase 5.3
    /// на removal (contract §10). `role` — `TeamMemberRole.rawValue` ('admin' | 'member').
    /// `pubkey_hex` — X25519 32-byte public, hex-encoded (64 chars).
    public enum TeamMembers {
        public static let tableName = "team_members"
        public static let id = "id"
        public static let orgID = "org_id"
        public static let role = "role"
        public static let pubkeyHex = "pubkey_hex"
        public static let displayName = "display_name"
        public static let addedAtMs = "added_at_ms"
        public static let removedAtMs = "removed_at_ms"

        /// Partial index — фильтрует active members одной org для Team UI list.
        public static let indexOrgActive = "team_members_org_active"
    }

    /// Phase 5.1.A — team key rotation history (contract §7).
    /// PK — `id` UUID v4 (rotation identity; embedded as 16-byte `keyID` в envelope §6).
    /// `deprecated_at_ms` IS NULL = current rotation; устанавливается в Phase 5.3.
    /// `generated_by_member_id` — logical FK на `team_members.id` (audit who created rotation).
    /// **Forever-retained** — old rows нужны для decrypt'а `presence_history` (contract §12).
    public enum TeamKeys {
        public static let tableName = "team_keys"
        public static let id = "id"
        public static let generatedAtMs = "generated_at_ms"
        public static let deprecatedAtMs = "deprecated_at_ms"
        public static let generatedByMemberID = "generated_by_member_id"

        /// Partial index — query "current key" дёшево (1 row).
        public static let indexActive = "team_keys_active"
    }

    /// Phase 5.3.D — admin-side write-ahead journal of pending key-rotation POSTs.
    /// Composite PK `(peer_pubkey_hex, new_key_id)` matches relay's idempotency
    /// key (5.3.C). `posted_at_ms IS NULL` means the POST has not yet succeeded;
    /// `KeyRotationService.resumePendingPosts()` retries on next launch.
    /// `kind` — `'rotation'` (wrapped new teamKey) или `'tombstone'` (sentinel for removed peer).
    public enum RotationOutbox {
        public static let tableName = "rotation_outbox"
        public static let peerPubkeyHex = "peer_pubkey_hex"
        public static let newKeyID = "new_key_id"
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
        public static let otp = "otp"
        public static let inviteePubkeyHex = "invitee_pubkey_hex"
        public static let inviteeDisplayNameHint = "invitee_display_name_hint"
        public static let createdAtMs = "created_at_ms"
        public static let expiresAtMs = "expires_at_ms"
        public static let status = "status"
        public static let lastPolledAtMs = "last_polled_at_ms"

        public static let indexStatus = "idx_pending_invites_status"
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
    /// side table is the source of truth для retrieval после MATCH (search() join +
    /// D3 reverse-lookup). Composite write atomic в `EventsFullTextStore.indexEvent`.
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
    }

    /// Phase Track-1 D2 — target_kind discriminators for `event_links.target_kind`.
    public enum TargetKinds {
        public static let linearIssue = "linear_issue"
        public static let githubPR = "github_pr"
        public static let githubUser = "github_user"
    }
}

/// Канонические `collector_id` значения. Литералы — public, чтобы тесты
/// и Agent могли передавать одни и те же ID (single source of truth).
public enum CollectorID {
    /// Phase 2.3 — Claude Code session jsonl tail-reader.
    public static let claudeCodeJSONL = "claude_code_jsonl"
    /// Phase 2.4 — FSEvents content collector. Не используется для offsets
    /// (FSEvents stream-based, не tail-read), но фигурирует в diagnostic logs.
    public static let fsEvents = "fs_events"
    /// Phase 4.2 — Linear GraphQL polling collector. `sourceID = "linear:<workspaceID>"`.
    /// `lastModifiedMs` хранит cursor (epoch ms newest processed `updatedAt`).
    public static let linearPolling = "linear_polling"
    /// Phase 4.3 — GitHub REST events polling collector. `sourceID = "github:<login>"`.
    /// `lastModifiedMs` хранит cursor (epoch ms newest processed event `created_at`).
    public static let githubPolling = "github_polling"
    /// Phase 4.4 — Slack REST polling collector. `sourceID = "slack:<team_id>:<user_id>"`.
    /// `lastModifiedMs` хранит cursor (epoch ms newest processed message `ts`).
    public static let slackPolling = "slack_polling"
}

/// Канонические `provider` значения для `integrations` таблицы. Литералы —
/// public, single source of truth между OAuth-сервисом, DB и (Phase 4.2+) collector'ами.
public enum IntegrationProvider: String, Sendable, Hashable, CaseIterable {
    case linear
    case github
    case slack
}
