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
    /// потребует M005 lift PK → composite (provider, workspace_id).
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
