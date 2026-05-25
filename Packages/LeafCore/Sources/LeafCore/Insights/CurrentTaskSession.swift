import Foundation

/// Discriminator for the substrate path that resolved the current task
/// session. Track-10 Phase B — carries the brainstorm gate decision (AI
/// wins if more recent — symmetric compare-by-latestTs between IDE
/// attention events and aiCollaboration cwd-match events within today).
/// Composer reads this to append " via Claude Code" suffix in the YOU'RE
/// ON session line when the AI candidate's latest activity beat the IDE's.
public enum SessionSource: String, Sendable, Equatable, Hashable, Codable {
    /// Per-IDE dispatch matched (Xcode doc_path / VSCode-family
    /// `workspace_root` / JetBrains `workspace_root`).
    case ide
    /// aiCollaboration cwd-match won the latestTs compare.
    case aiCollaboration
    /// Neither IDE nor aiCollaboration produced a match today.
    case fallback
}

/// Bundled view of the user's current task session — composed once per
/// `InsightsReader.refresh()` tick and threaded through `InsightsSnapshot`
/// to the YOU'RE ON Home block (Track-10 T7).
///
/// Composition source: `DerivedInsights.currentTaskSession()`. Production
/// moat impl in `LeafCorePrivate` assembles the bundle via per-IDE dispatch
/// (`xcode_active_doc_changed.doc_path` → workspace path walk;
/// `vscode_active_doc_changed` / `jetbrains_recent_project_observed`
/// `workspace_root` direct match) for session start, attention-event dwell
/// walk for per-task focused minutes, and basename-only projection
/// (via `NSString.lastPathComponent`) for open files.
///
/// Returns `nil` upstream when `currentTaskIdentity()` resolves nil OR
/// `currentWorkspacePath()` resolves nil — UI surfaces empty state
/// ("No active task identified — …" per master spec §3.6).
///
/// `Equatable + Hashable + Sendable` cover SwiftUI diff, Set dedup, and
/// concurrency safety. `Codable` is intentionally omitted (F-CTO-A):
/// `TaskIdentity` is not Codable and T7 has no MCP JSON round-trip
/// requirement.
public struct CurrentTaskSession: Equatable, Hashable, Sendable {
    /// Task identity (LEAF-ID / branch / repo / linearWorkspaceSlug) —
    /// shared with the RESUME hero CTA composition (T2 substrate reuse).
    /// `workspacePath` stays nil per Track-9 T5 D-8 (path bytes never
    /// flow into `InsightsSnapshot`).
    public let taskIdentity: TaskIdentity

    /// Millisecond epoch of the earliest IDE attention event today
    /// matching the current workspace (per-IDE dispatch). Falls back to
    /// today 00:00 local TZ when no matching event is found (rare edge:
    /// task identity resolved via Track-9 T5 substrate path-walk but no
    /// IDE attention event landed today).
    public let sessionStartMs: Int64

    /// Focused minutes during the current task session — sum of attention
    /// dwell intervals where `bundle_id` matches the task's IDE bundle
    /// AND `ts >= sessionStartMs`. Per-task subset (NOT today total) —
    /// matches master spec §3.6 "1h 32m focused so far" wording.
    public let focusedMinSoFar: Int

    /// Recent open files in the current workspace as basenames-only.
    /// Capped at 3 per master spec §3.6 mockup. Sorted by most-recent
    /// `ts` descending; deduplicated by basename. Every element MUST
    /// satisfy `!contains("/")` — regression test in moat
    /// (`test_currentTaskSession_OpenFilesAreBasenamesOnly_NoSentinelLeak`).
    public let openFiles: [String]

    /// Track-10 Phase B — substrate path that resolved this session
    /// (IDE dispatch vs aiCollaboration cwd-match vs fallback). Drives
    /// the " via Claude Code" provenance suffix in the YOU'RE ON line.
    /// Defaulted `.fallback` so pre-Phase-B callers stay source-compatible.
    public let sessionSource: SessionSource

    public init(
        taskIdentity: TaskIdentity,
        sessionStartMs: Int64,
        focusedMinSoFar: Int,
        openFiles: [String],
        sessionSource: SessionSource = .fallback
    ) {
        self.taskIdentity = taskIdentity
        self.sessionStartMs = sessionStartMs
        self.focusedMinSoFar = focusedMinSoFar
        self.openFiles = openFiles
        self.sessionSource = sessionSource
    }
}
