import Foundation

/// Phase 2.4 — public-Core type for a row from the `watched_folders` table.
/// The user manages the list via Settings; `FSEventsCollector` reads it
/// at startup + on every Darwin notify / poll-fallback tick.
public struct WatchedFolder: Sendable, Hashable {
    /// UUID — stable identity when a folder is renamed (if we ever add auto-detect)
    /// and for the `update`/`remove` API. Not the path, to avoid cascading renames.
    public let id: String
    /// Canonical absolute path (`URL.resolvingSymlinksInPath`).
    /// `/var/...` and `/private/var/...` — the same path; canonicalization is done
    /// both in the UI service (before INSERT) and in FSEventsCollector (before `FSEventStreamCreate`).
    public let path: String
    /// L4 = parent dir at write-time (privacy-first default per architecture.md);
    /// L5 = full file path. The toggle applies only to future events.
    public let maxGranularity: WatchedFolderGranularity
    /// `false` — the collector stops writing new events, but historical events remain
    /// (non-retroactive; right-to-deletion is a separate flow OT-1).
    public let enabled: Bool
    /// When the user added the folder.
    public let addedAt: Date
    /// Last UPDATE of this row (toggle, granularity change, etc).
    public let updatedAt: Date

    public init(
        id: String,
        path: String,
        maxGranularity: WatchedFolderGranularity,
        enabled: Bool,
        addedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.path = path
        self.maxGranularity = maxGranularity
        self.enabled = enabled
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

/// L4 vs L5 — per-folder ceiling. See architecture.md "Granularity levels":
/// L6 (content) is always forbidden; this enum is only about the L4↔L5 trade-off.
public enum WatchedFolderGranularity: String, Sendable, Hashable {
    /// "App + folder/module" — payload writes the parent dir, without basename.
    case L4
    /// "App + file name" — payload writes the full file path. Opt-in per folder.
    case L5
}
