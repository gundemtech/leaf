import Foundation
import os

/// Phase 2.3 — tail-read collector для Claude Code session jsonl файлов.
///
/// Каждый tick:
///   1. Recursive 1-level list `~/.claude/projects/<slug>/*.jsonl`.
///   2. Для каждого файла — `URLResourceValues` (mtime, size, inode).
///   3. Lookup `collector_offsets[claude_code_jsonl, abs_path]`.
///   4. Bootstrap (no offset record): mtime ≥ now − backfillWindowDays → offset=0
///      (backfill); иначе offset=fileSize (skip-backward).
///   5. Skip if mtime/size unchanged.
///   6. Inode/truncate guard: reset offset=0 при inode mismatch / size shrink.
///   7. `FileHandle.seek(toOffset:) → readToEnd()`. Split по \n. Incomplete
///      trailing fragment без \n — пропускаем (next tick подберёт).
///   8. Parser → `[RawEvent]` per line; `.malformed` log warning + skip line.
///   9. `Database.writeEventsAndOffset` — events + offset в одной транзакции.
///
/// Pattern идентичен `MaintenanceScheduler`: actor, start/stop с cancel + await,
/// `performTick` отдельно от loop wrapper для unit-тестируемости.
public actor ClaudeCodeCollector {
    private let database: Database
    private let parser: any ClaudeCodeJSONLParsing
    private let projectsRoot: URL
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger

    private var loopTask: Task<Void, Never>?

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

    /// Single tick — testable без timer'а. `now` инжектируется тестами для
    /// детерминированной bootstrap-проверки (mtime relative к now).
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
        // Short initial settle delay — let Agent остальные подсистемы стартануть
        // (writer/maintenance), плюс не блокируем main launch с blocking I/O scan.
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

    /// 1-level recursive: `<projectsRoot>/<projectSlug>/<sessionId>.jsonl`.
    /// Не используем deep `enumerator` чтобы не глядеть в случайные subdirs.
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
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                results.append(f)
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
            // Файл исчез между listing и stat — skip silent.
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Canonical path (resolves /var → /private/var symlinks etc) — без этого
        // тот же файл может попасть в `collector_offsets` дважды если listing API
        // и тест передают разные представления одного pathname.
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

        // Skip-unchanged: mtime AND size совпадают со stored — нет append'а.
        if stat.mtimeMs <= stored.lastModifiedMs && stat.size == stored.size {
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: 0)
        }

        // Inode/truncate reset: tail-read на новом файле / replay'нутом → начать сначала.
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
            // В пределах окна — backfill от 0.
            let result = readAndPersist(url: url, canonicalPath: canonicalPath, stat: stat, startOffset: 0, nowMs: nowMs)
            return FileResult(
                didProcess: result.didProcess,
                didBootstrap: true,
                eventsWritten: result.eventsWritten,
                malformedLines: result.malformedLines
            )
        } else {
            // Slик starobi — skip-backward: запоминаем current EOF, дальше tail-read.
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
        // Защитный кейс: файл не вырос и offset уже в EOF — нет работы.
        if startOffset >= stat.size {
            // Всё-таки UPSERT'нем offset чтобы lastModifiedMs обновился.
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

        // Split по \n. Если последний фрагмент НЕ заканчивается \n — он incomplete
        // (writer ещё дописывает строку), пропускаем его в этом tick'е.
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
            try database.writeEventsAndOffset(allEvents, offset: newOffset)
        } catch {
            logger.error("persist failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return FileResult(didProcess: false, didBootstrap: false, eventsWritten: 0, malformedLines: malformedCount)
        }

        return FileResult(
            didProcess: true,
            didBootstrap: false,
            eventsWritten: allEvents.count,
            malformedLines: malformedCount
        )
    }

    // MARK: - File stat

    private struct FileStat {
        let size: Int64
        let mtimeMs: Int64
        let inode: Int64?
    }

    /// `URLResourceKey` не имеет inode getter'а на macOS — берём через
    /// `FileManager.attributesOfItem` (stat syscall, NSFileSystemFileNumber key).
    /// Size + mtime — через URLResourceValues (cheaper, no separate stat).
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
    ///   - `consumedBytes` — кол-во bytes полных строк (включая `\n` terminator'ы);
    ///     incomplete trailing fragment (если есть) не учитывается → next tick
    ///     прочитает его с byte_offset == startOffset + consumedBytes.
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
        // Incomplete trailing fragment (без \n) игнорируется — next tick
        // прочитает его с byteOffset == startOffset + lastNewlineEnd.
        return (lines, lastNewlineEnd)
    }
}
