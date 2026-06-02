import Foundation
import os

/// Phase 2.3 — tail-read collector for Claude Code session jsonl files.
///
/// Each tick:
///   1. Recursive 1-level list `~/.claude/projects/<slug>/*.jsonl`.
///   2. For each file — `URLResourceValues` (mtime, size, inode).
///   3. Lookup `collector_offsets[claude_code_jsonl, abs_path]`.
///   4. Bootstrap (no offset record): mtime ≥ now − backfillWindowDays → offset=0
///      (backfill); otherwise offset=fileSize (skip-backward).
///   5. Skip if mtime/size unchanged.
///   6. Inode/truncate guard: reset offset=0 on inode mismatch / size shrink.
///   7. `FileHandle.seek(toOffset:) → readToEnd()`. Split on \n. An incomplete
///      trailing fragment without \n — we skip it (the next tick picks it up).
///   8. Parser → `[RawEvent]` per line; `.malformed` log warning + skip line.
///   9. `Database.writeEventsAndOffset` — events + offset in a single transaction.
///
/// The pattern is identical to `MaintenanceScheduler`: actor, start/stop with cancel + await,
/// `performTick` separate from the loop wrapper for unit-testability.
public actor ClaudeCodeCollector {
    private let database: Database
    private let parser: any ClaudeCodeJSONLParsing
    private let projectsRoot: URL
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger

    private var loopTask: Task<Void, Never>?

    /// Track-6 P1 (Task 17) — LRU set of `tool_use_id` values observed via the
    /// hook path. Hook arrives faster than jsonl tail-read; we record each
    /// tool_use_id from `ingestHookEvents`, then drop matching events when
    /// jsonl ticks parse them later. Hook wins per spec §2.3 (strictly richer
    /// payload — has `duration_ms` + `permission_mode`).
    ///
    /// Capacity 2048 — generous over typical per-session tool counts (10-200).
    /// On overflow we drop random half (`shuffled().prefix(N/2)`) — simple,
    /// stateless, no true LRU bookkeeping. Phase 4.9 may upgrade if metric
    /// shows churn (e.g. ordered-set with timestamp eviction).
    ///
    /// Access is serial via actor isolation — no extra lock needed.
    private var hookSeenToolUseIDs: Set<String> = []
    private static let hookSeenLRUCapacity = 2048

    public init(
        database: Database,
        parser: any ClaudeCodeJSONLParsing,
        projectsRoot: URL,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        logger: Logger
    ) {
        self.database = database
        self.parser = parser
        self.projectsRoot = projectsRoot
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.logger = logger
    }

    // MARK: - Public control

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("ClaudeCodeCollector started (root=\(self.projectsRoot.path, privacy: .public), every=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        logger.info("ClaudeCodeCollector stopped")
    }

    // MARK: - Tick (unit-testable)

    public struct TickResult: Sendable, Equatable {
        public let filesScanned: Int
        public let filesProcessed: Int
        public let eventsWritten: Int
        public let malformedLines: Int
        public let bootstrappedFiles: Int
    }

    /// Single tick — testable without a timer. `now` is injected by tests for
    /// a deterministic bootstrap check (mtime relative to now).
    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            return TickResult(filesScanned: 0, filesProcessed: 0, eventsWritten: 0, malformedLines: 0, bootstrappedFiles: 0)
        }

        var filesScanned = 0
        var filesProcessed = 0
        var eventsWritten = 0
        var malformedLines = 0
        var bootstrappedFiles = 0

        let files = listJSONLFiles()
        for file in files {
            filesScanned += 1
            let processed = processFile(file, now: now)
            if processed.didProcess { filesProcessed += 1 }
            if processed.didBootstrap { bootstrappedFiles += 1 }
            eventsWritten += processed.eventsWritten
            malformedLines += processed.malformedLines
        }

        if filesProcessed > 0 || bootstrappedFiles > 0 {
            logger.info("tick: scanned=\(filesScanned, privacy: .public), processed=\(filesProcessed, privacy: .public), bootstrapped=\(bootstrappedFiles, privacy: .public), events=\(eventsWritten, privacy: .public), malformed=\(malformedLines, privacy: .public)")
        }

        return TickResult(
            filesScanned: filesScanned,
            filesProcessed: filesProcessed,
            eventsWritten: eventsWritten,
            malformedLines: malformedLines,
            bootstrappedFiles: bootstrappedFiles
        )
    }

    // MARK: - Loop

    private func runLoop() async {
        // Short initial settle delay — let the Agent's other subsystems start up
        // (writer/maintenance), plus we don't block main launch with a blocking I/O scan.
        await sleep(seconds: min(intervalSec, 5))
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }

    // MARK: - File discovery

    /// Track-6 P1 — 2-level discovery:
    ///   `<projectsRoot>/<projectSlug>/<sessionId>.jsonl`                          ← top-level (existing)
    ///   `<projectsRoot>/<projectSlug>/<parentSessionId>/subagents/agent-*.jsonl`  ← NEW (subagents)
    /// Pre-P1 the collector skipped the subagent subdir entirely ("We don't use a deep enumerator
    /// so we don't peek into arbitrary subdirs"). P1 enables it via narrow walk — exact known shape,
    /// no wildcard recursion. Random subdirs at the project level / nested under sessionId still
    /// ignored — see `testDoesNotRecurseIntoArbitrarySubdirs`.
    private func listJSONLFiles() -> [URL] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let entryIsDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !entryIsDir, entry.pathExtension == "jsonl" {
                    results.append(entry)
                    continue
                }
                // Possible session-uuid dir — look for sibling `subagents/agent-*.jsonl`.
                if entryIsDir {
                    let subagentsDir = entry.appendingPathComponent("subagents")
                    guard let agentFiles = try? fm.contentsOfDirectory(
                        at: subagentsDir,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    // `.jsonl` extension alone excludes the sibling `.meta.json` files;
                    // `agent-` prefix is defense-in-depth against future filenames Claude
                    // might add to the subagents dir (e.g. `summary.jsonl`, `index.jsonl`).
                    for file in agentFiles where file.pathExtension == "jsonl"
                        && file.lastPathComponent.hasPrefix("agent-") {
                        results.append(file)
                    }
                }
            }
        }
        return results
    }

    // MARK: - Per-file processing

    private struct FileResult {
        let didProcess: Bool
        let didBootstrap: Bool
        let eventsWritten: Int
        let malformedLines: Int
    }

    private func processFile(_ url: URL, now: Date) -> FileResult {
        let stat = fileStat(url)
        guard let stat else {
            // File disappeared between listing and stat — skip silently.
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Canonical path (resolves /var → /private/var symlinks etc) — without this
        // the same file could land in `collector_offsets` twice if the listing API
        // and a test pass different representations of the same pathname.
        let canonicalPath = url.resolvingSymlinksInPath().path

        let existing = (try? database.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: canonicalPath
        )) ?? nil

        // Bootstrap branch.
        if existing == nil {
            return bootstrap(url: url, canonicalPath: canonicalPath, stat: stat, nowMs: nowMs)
        }

        let stored = existing!

        // Skip-unchanged: mtime AND size match the stored values — no append.
        if stat.mtimeMs <= stored.lastModifiedMs && stat.size == stored.size {
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
        }

        // Inode/truncate reset: tail-read on a new / replayed file → start over.
        var startOffset = stored.byteOffset
        if let storedInode = stored.inode, storedInode != stat.inode {
            startOffset = 0
        } else if stat.size < stored.byteOffset {
            startOffset = 0
        }

        return readAndPersist(url: url, canonicalPath: canonicalPath, stat: stat, startOffset: startOffset, nowMs: nowMs)
    }

    private func bootstrap(url: URL, canonicalPath: String, stat: FileStat, nowMs: Int64) -> FileResult {
        let cutoffMs = nowMs - Int64(backfillWindowDays) * 86_400_000
        if stat.mtimeMs >= cutoffMs {
            // Within the window — backfill from 0.
            let result = readAndPersist(url: url, canonicalPath: canonicalPath, stat: stat, startOffset: 0, nowMs: nowMs)
            return FileResult(
                didProcess: result.didProcess,
                didBootstrap: true,
                eventsWritten: result.eventsWritten,
                malformedLines: result.malformedLines
            )
        } else {
            // Too old — skip-backward: record the current EOF, then tail-read from there.
            let offset = CollectorOffset(
                collectorID: CollectorID.claudeCodeJSONL,
                sourceID: canonicalPath,
                byteOffset: stat.size,
                inode: stat.inode,
                size: stat.size,
                lastModifiedMs: stat.mtimeMs,
                updatedMs: nowMs
            )
            do {
                try database.writeOffset(offset)
            } catch {
                logger.error("bootstrap skip-backward failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
            }
            return FileResult(didProcess: false, didBootstrap: true, eventsWritten: 0, malformedLines: 0)
        }
    }

    private func readAndPersist(url: URL, canonicalPath: String, stat: FileStat, startOffset: Int64, nowMs: Int64) -> FileResult {
        // Defensive case: the file hasn't grown and the offset is already at EOF — nothing to do.
        if startOffset >= stat.size {
            // Still UPSERT the offset so that lastModifiedMs is updated.
            let offset = CollectorOffset(
                collectorID: CollectorID.claudeCodeJSONL,
                sourceID: canonicalPath,
                byteOffset: stat.size,
                inode: stat.inode,
                size: stat.size,
                lastModifiedMs: stat.mtimeMs,
                updatedMs: nowMs
            )
            try? database.writeOffset(offset)
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
        }

        let payload: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(startOffset))
            payload = try handle.readToEnd() ?? Data()
        } catch {
            logger.error("read failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
        }

        // Split on \n. If the last fragment does NOT end with \n it is incomplete
        // (the writer is still appending the line), so we skip it in this tick.
        let (completeLines, consumedBytes) = splitCompleteLines(payload)

        var allEvents: [RawEvent] = []
        var malformedCount = 0
        for line in completeLines {
            let result = parser.parse(line: line, source: url.path, now: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0))
            switch result {
            case .events(let events):
                allEvents.append(contentsOf: events)
            case .irrelevant:
                continue
            case .malformed(let reason):
                malformedCount += 1
                logger.warning("malformed jsonl line in \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            }
        }

        // Track-6 P1 (Task 17) — dedup against hook-seen tool_use_ids. Hook
        // fires faster than the tail-read tick; for any tool_use_id already
        // observed via `ingestHookEvents` we drop the jsonl twin so exactly
        // one event (the hook one, richer payload) is persisted.
        let filteredEvents: [RawEvent]
        if hookSeenToolUseIDs.isEmpty {
            filteredEvents = allEvents
        } else {
            filteredEvents = allEvents.filter { event in
                guard let id = event.payload["tool_use_id"] else { return true }
                return !hookSeenToolUseIDs.contains(id)
            }
            let dropped = allEvents.count - filteredEvents.count
            if dropped > 0 {
                logger.info("dedup: dropped \(dropped, privacy: .public) jsonl events matching hook tool_use_id")
            }
        }

        let newOffset = CollectorOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: canonicalPath,
            byteOffset: startOffset + Int64(consumedBytes),
            inode: stat.inode,
            size: stat.size,
            lastModifiedMs: stat.mtimeMs,
            updatedMs: nowMs
        )

        do {
            try database.writeEventsAndOffset(filteredEvents, offset: newOffset)
        } catch {
            logger.error("persist failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: malformedCount)
        }

        return FileResult(
            didProcess: true,
            didBootstrap: false,
            eventsWritten: filteredEvents.count,
            malformedLines: malformedCount
        )
    }

    // MARK: - File stat

    private struct FileStat {
        let size: Int64
        let mtimeMs: Int64
        let inode: Int64?
    }

    /// `URLResourceKey` has no inode getter on macOS — we obtain it via
    /// `FileManager.attributesOfItem` (stat syscall, NSFileSystemFileNumber key).
    /// Size + mtime — via URLResourceValues (cheaper, no separate stat).
    private func fileStat(_ url: URL) -> FileStat? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ]) else { return nil }

        let size = Int64(values.fileSize ?? 0)
        let mtimeMs: Int64 = {
            guard let date = values.contentModificationDate else { return 0 }
            return Int64(date.timeIntervalSince1970 * 1000)
        }()

        let inode: Int64? = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            if let n = attrs[.systemFileNumber] as? NSNumber {
                return n.int64Value
            }
            return nil
        }()
        return FileStat(size: size, mtimeMs: mtimeMs, inode: inode)
    }

    // MARK: - Line splitting

    /// Returns:
    ///   - `lines` — only complete lines (terminated by `\n`)
    ///   - `consumedBytes` — number of bytes of complete lines (including `\n` terminators);
    ///     the incomplete trailing fragment (if any) is not counted → the next tick
    ///     reads it from byte_offset == startOffset + consumedBytes.
    private func splitCompleteLines(_ data: Data) -> (lines: [String], consumedBytes: Int) {
        guard !data.isEmpty else { return ([], 0) }

        var lines: [String] = []
        var lastNewlineEnd = 0  // exclusive index of last \n + 1

        let bytes = data.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        var lineStart = 0
        for i in 0..<bytes.count {
            if bytes[i] == 0x0A {  // \n
                let lineBytes = bytes[lineStart..<i]
                if let s = String(bytes: lineBytes, encoding: .utf8) {
                    lines.append(s)
                }
                lineStart = i + 1
                lastNewlineEnd = i + 1
            }
        }
        // The incomplete trailing fragment (without \n) is ignored — the next tick
        // reads it from byteOffset == startOffset + lastNewlineEnd.
        return (lines, lastNewlineEnd)
    }

    // MARK: - Track-6 P1 — Hook bridge ingestion (Task 17)

    /// Hook path entry point. Called by `ClaudeCodeHookSocketListener`'s
    /// per-envelope callback (wired in `LeafAgent/Agent.swift` under
    /// `#if LEAF_PROD`). Records each event's `tool_use_id` in the LRU set so
    /// the subsequent jsonl tick deduplicates, then persists.
    ///
    /// No offset tracking: hook path is socket-based (not file-based), so
    /// `collector_offsets` is meaningless here. We still call
    /// `writeEventsAndOffset` for transactional atomicity, passing `offset: nil`.
    public func ingestHookEvents(_ events: [RawEvent]) async {
        guard !events.isEmpty else { return }

        for event in events {
            if let id = event.payload["tool_use_id"] {
                hookSeenToolUseIDs.insert(id)
            }
        }
        // Trim-by-half overflow: simple, deterministic-enough until Phase 4.9
        // ships a true LRU. Worst case we re-emit a few duplicates after a
        // mass trim — substrate detector dedup already swallows that.
        if hookSeenToolUseIDs.count > Self.hookSeenLRUCapacity {
            hookSeenToolUseIDs = Set(
                hookSeenToolUseIDs.shuffled().prefix(Self.hookSeenLRUCapacity / 2)
            )
        }

        do {
            try database.writeEventsAndOffset(events, offset: nil)
        } catch {
            logger.error(
                "ingestHookEvents persist failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Test-only accessor — lets ClaudeCodeCollectorTests assert LRU population
    /// without exposing the underlying Set publicly.
    internal func hookSeenToolUseIDsCount_forTesting() -> Int {
        hookSeenToolUseIDs.count
    }
}
