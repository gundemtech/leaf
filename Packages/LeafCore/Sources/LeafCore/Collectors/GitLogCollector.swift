import Foundation
import os

/// Use-case rebuild Track A1 — local `git log` polling collector.
///
/// ADR-015 promised "git log polling in watched folders"; it was never built,
/// so commit messages — the densest self-authored decision corpus — never
/// reached the memory layer (the GitHub feed's stripped PushEvents carry no
/// `commits[]`). This collector reads self-authored commits straight from the
/// local repos inside enabled watched folders: history is free (the initial
/// window doubles as backfill), authorship is verified by the reader
/// (`--author` filter — moat), private/offline repos work, no API budgets.
///
/// Emits `git_commit_authored` events (payload: repo / branch / sha / body =
/// subject [+ blank line + body]). LOCAL-ONLY in v1: deliberately NOT
/// registered in `ShareSourceClassifier` — the initial 90-day window lands
/// with fresh event ids above the team-broadcast cursor and would otherwise
/// blast months of history to the team in one tick. Teammates keep seeing
/// `gh_commit_pushed`.
///
/// Cursor: one `collector_offsets` row per repo (`collectorID` =
/// "git_log_polling", `sourceID` = canonical repo path, `lastModifiedMs` =
/// newest committedAtMs processed). Event + cursor land atomically via
/// `writeEventsAndOffset` (A0-fixed: indexes FTS + derives links).
public actor GitLogCollector {

  public static let collectorID = "git_log_polling"
  public static let eventKind = "git_commit_authored"

  /// Repo-count cap per tick — a watched "projects" folder with hundreds of
  /// children must not turn one tick into hundreds of subprocess sweeps.
  private static let repoCap = 20

  /// Per-repo read budget per tick. The initial 90-day window on an active
  /// repo fits comfortably; pathological histories get the rest next tick.
  private static let perRepoLimit = 500

  private let database: Database
  private let reader: any GitCommitLogReading
  private let pollIntervalSec: TimeInterval
  private let logger: Logger

  private var loopTask: Task<Void, Never>?

  public init(
    database: Database,
    reader: any GitCommitLogReading,
    pollIntervalSec: TimeInterval,
    logger: Logger = Logger(subsystem: "tech.gundem.leaf.core", category: "git-log")
  ) {
    self.database = database
    self.reader = reader
    self.pollIntervalSec = pollIntervalSec
    self.logger = logger
  }

  public func start() {
    guard loopTask == nil else { return }
    loopTask = Task { [weak self] in
      await self?.runLoop()
    }
    logger.info("GitLogCollector started (interval=\(self.pollIntervalSec, privacy: .public)s)")
  }

  public func stop() async {
    loopTask?.cancel()
    await loopTask?.value
    loopTask = nil
    logger.info("GitLogCollector stopped")
  }

  private func runLoop() async {
    // First tick shortly after start (the initial window is the backfill);
    // subsequent ticks on the poll cadence.
    await sleep(seconds: min(pollIntervalSec / 10, 30))
    while !Task.isCancelled {
      await tick()
      await sleep(seconds: pollIntervalSec)
    }
  }

  /// One poll pass — exposed for tests + opportunistic invocation.
  public func tick() async {
    let repos = discoverRepos()
    for repoPath in repos {
      if Task.isCancelled { return }
      await pollRepo(at: repoPath)
    }
  }

  // MARK: - Repo discovery

  /// Enabled watched folders that are git repos themselves, plus one level of
  /// child repos (a watched "~/Projects" folder of clones), capped.
  private func discoverRepos() -> [String] {
    let folders = (try? database.listWatchedFolders(includingDisabled: false)) ?? []
    let fm = FileManager.default
    var out: [String] = []

    for folder in folders {
      let url = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath()
      if Self.isGitRepo(url, fm: fm) {
        out.append(url.path)
        continue
      }
      let children = (try? fm.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []
      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where Self.isGitRepo(child, fm: fm) {
        out.append(child.resolvingSymlinksInPath().path)
      }
    }

    if out.count > Self.repoCap {
      logger.warning("GitLogCollector: \(out.count, privacy: .public) repos discovered, capping at \(Self.repoCap, privacy: .public)")
    }
    var seen = Set<String>()
    return out.filter { seen.insert($0).inserted }.prefix(Self.repoCap).map { $0 }
  }

  private static func isGitRepo(_ url: URL, fm: FileManager) -> Bool {
    var isDir: ObjCBool = false
    let gitPath = url.appendingPathComponent(".git").path
    // `.git` is a directory for normal clones and a FILE for worktrees/submodules
    // (gitdir pointer) — both are valid repos for `git log`.
    return fm.fileExists(atPath: gitPath, isDirectory: &isDir)
  }

  // MARK: - Per-repo poll

  private func pollRepo(at repoPath: String) async {
    let cursor = try? database.readOffset(collectorID: Self.collectorID, sourceID: repoPath)
    let sinceMs = cursor?.lastModifiedMs

    let records = await reader.selfAuthoredCommits(
      repoPath: repoPath, sinceMs: sinceMs, limit: Self.perRepoLimit)

    // Defensive re-filter: the reader's --since boundary is fuzzy (git date
    // parsing); the cursor is the contract.
    let fresh = records
      .filter { sinceMs == nil || $0.committedAtMs > sinceMs! }
      .sorted { $0.committedAtMs < $1.committedAtMs }
    guard !fresh.isEmpty else { return }

    let folderName = (repoPath as NSString).lastPathComponent
    let events = fresh.map { record in
      Self.makeEvent(record: record, folderName: folderName)
    }
    let newestMs = fresh.last!.committedAtMs
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let offset = CollectorOffset(
      collectorID: Self.collectorID,
      sourceID: repoPath,
      byteOffset: 0,
      inode: nil,
      size: 0,
      lastModifiedMs: newestMs,
      updatedMs: nowMs
    )

    do {
      try database.writeEventsAndOffset(events, offset: offset)
      logger.info("GitLogCollector: \(events.count, privacy: .public) commits captured from \(folderName, privacy: .public)")
    } catch {
      // Cursor did not advance — next tick retries the same window.
      logger.error("GitLogCollector write failed for \(folderName, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  static func makeEvent(record: GitCommitRecord, folderName: String) -> RawEvent {
    var body = record.subject
    if let extra = record.body, !extra.isEmpty {
      body += "\n\n" + extra
    }
    var payload: [String: String] = [
      "event_kind": eventKind,
      "source": "git_local",
      "repo": record.remote.map { "\($0.owner)/\($0.repo)" } ?? folderName,
      "sha": record.sha,
      "authored_by_viewer": "true",
      Schema.EventPayloadKeys.body: body,
    ]
    if let branch = record.branch, !branch.isEmpty {
      payload["branch"] = branch
    }
    return RawEvent(
      timestamp: Date(timeIntervalSince1970: TimeInterval(record.committedAtMs) / 1000.0),
      signalType: .action,
      bundleID: nil,
      payload: payload
    )
  }

  private func sleep(seconds: TimeInterval) async {
    let ns = UInt64(max(0, seconds) * 1_000_000_000)
    try? await Task.sleep(nanoseconds: ns)
  }
}
