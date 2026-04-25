import Foundation

/// Phase 2.4 — public-Core type для row из `watched_folders` таблицы.
/// Юзер управляет списком через Settings; `FSEventsCollector` читает
/// при старте + на каждый Darwin notify / poll-fallback tick.
public struct WatchedFolder: Sendable, Hashable {
    /// UUID — stable identity при rename folder (если когда-то добавим auto-detect)
    /// и для `update`/`remove` API. Не path, чтобы не каскадить переименования.
    public let id: String
    /// Canonical absolute path (`URL.resolvingSymlinksInPath`).
    /// `/var/...` и `/private/var/...` — один и тот же путь; канонизация делается
    /// и в UI service (перед INSERT), и в FSEventsCollector (перед `FSEventStreamCreate`).
    public let path: String
    /// L4 = parent dir at write-time (privacy-first default per architecture.md);
    /// L5 = full file path. Toggle применяется только к future events.
    public let maxGranularity: WatchedFolderGranularity
    /// `false` — collector не пишет new events, но historical events остаются
    /// (non-retroactive; right-to-deletion — отдельный flow OT-1).
    public let enabled: Bool
    /// Когда юзер добавил folder.
    public let addedAt: Date
    /// Последний UPDATE этой row (toggle, granularity change, etc).
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

/// L4 vs L5 — per-folder ceiling. См. architecture.md "Granularity levels":
/// L6 (content) запрещено всегда; этот enum только про L4↔L5 trade-off.
public enum WatchedFolderGranularity: String, Sendable, Hashable {
    /// "App + folder/module" — payload пишет parent dir, без basename.
    case L4
    /// "App + file name" — payload пишет full file path. Opt-in per folder.
    case L5
}
