// Phase 2.3 — integration test для tail-read mechanics. Mock parser в этом
// файле — schema mapping тестируется отдельно в LeafCorePrivateTests/
// ClaudeCodeJSONLParserTests.swift (moat).

import XCTest
import os
@testable import LeafCore

final class ClaudeCodeCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var projectsRoot: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "claude-code-collector")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-cc-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        projectsRoot = tempDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Tail-read with byte-offset resume:
    ///   tick 1: backfill 3 lines → 3 events + offset == EOF.
    ///   append 2 lines.
    ///   tick 2: only delta (2 events) → events count == 5, offset advanced.
    func testTailReadResumesFromOffset() async throws {
        // Arrange: project dir + .jsonl с 3 строками.
        let projectDir = projectsRoot.appendingPathComponent("-Users-x-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionFile = projectDir.appendingPathComponent("session-A.jsonl")

        let line1 = #"{"type":"user","sessionId":"S1","content":"prompt-1"}"#
        let line2 = #"{"type":"user","sessionId":"S1","content":"prompt-2"}"#
        let line3 = #"{"type":"user","sessionId":"S1","content":"prompt-3"}"#
        try (line1 + "\n" + line2 + "\n" + line3 + "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = ClaudeCodeCollector(
            database: writer,
            parser: MockOneEventParser(),
            projectsRoot: projectsRoot,
            intervalSec: 999,  // не запускаем loop — только performTick напрямую
            backfillWindowDays: 7,
            logger: logger
        )

        // Act 1: первый tick — backfill (mtime в пределах окна) от offset 0.
        let now = Date()
        let result1 = await collector.performTick(now: now)

        // Assert 1.
        XCTAssertEqual(result1.filesScanned, 1)
        XCTAssertEqual(result1.eventsWritten, 3, "3 lines → 3 RawEvents (mock)")
        XCTAssertEqual(result1.bootstrappedFiles, 1)

        let allRange = DateInterval(start: .distantPast, end: .distantFuture)
        let events1 = try writer.events(in: allRange)
        XCTAssertEqual(events1.count, 3)

        let offset1 = try writer.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: sessionFile.resolvingSymlinksInPath().path
        )
        XCTAssertNotNil(offset1)
        // EOF position == bytes prefix to last \n inclusive — для backfill case
        // == file size (все строки terminated \n).
        let initialAttrs = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let initialSize = (initialAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(offset1?.byteOffset, initialSize, "consumed == EOF")

        // Act 2: append 2 more lines.
        let line4 = #"{"type":"user","sessionId":"S1","content":"prompt-4"}"#
        let line5 = #"{"type":"user","sessionId":"S1","content":"prompt-5"}"#
        let appendData = (line4 + "\n" + line5 + "\n").data(using: .utf8)!
        let handle = try FileHandle(forWritingTo: sessionFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendData)
        try handle.close()

        // Slight delay чтобы mtime сдвинулась — APFS даёт ms-precision, обычно
        // достаточно одного поля file write (atomic file rename меняет mtime).
        try await Task.sleep(nanoseconds: 30_000_000)

        // Act 3: второй tick — только дельта.
        let result2 = await collector.performTick(now: Date())
        XCTAssertEqual(result2.filesScanned, 1)
        XCTAssertEqual(result2.eventsWritten, 2, "delta only — 2 new lines")
        XCTAssertEqual(result2.bootstrappedFiles, 0, "уже не bootstrap")

        let events2 = try writer.events(in: allRange)
        XCTAssertEqual(events2.count, 5, "3 initial + 2 delta")

        let offset2 = try writer.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: sessionFile.resolvingSymlinksInPath().path
        )
        XCTAssertNotNil(offset2)
        let finalAttrs = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let finalSize = (finalAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(offset2?.byteOffset, finalSize, "offset advanced to new EOF")
    }

    /// Bootstrap skip-backward для старых файлов (mtime < now - backfillWindowDays).
    /// offset = file size, БЕЗ events.
    func testBootstrapSkipsBackwardForOldFiles() async throws {
        let projectDir = projectsRoot.appendingPathComponent("-Users-x-old", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let oldFile = projectDir.appendingPathComponent("ancient.jsonl")

        // Создаём файл и устанавливаем mtime на 30 дней назад.
        try #"{"type":"user","content":"x"}"#.write(to: oldFile, atomically: true, encoding: .utf8)
        let oldDate = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)

        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = ClaudeCodeCollector(
            database: writer,
            parser: MockOneEventParser(),
            projectsRoot: projectsRoot,
            intervalSec: 999,
            backfillWindowDays: 7,
            logger: logger
        )

        let result = await collector.performTick(now: Date())
        XCTAssertEqual(result.eventsWritten, 0, "old file → skip-backward, no events")
        XCTAssertEqual(result.bootstrappedFiles, 1)

        // Offset upsert'ed на file size — следующий append подхватим.
        let stored = try writer.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: oldFile.resolvingSymlinksInPath().path
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: oldFile.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(stored?.byteOffset, fileSize)
    }

    /// Track-6 P1 — subagent transcripts live in `<projectSlug>/<sessionId>/subagents/agent-*.jsonl`
    /// (sibling subdir to the parent's `<sessionId>.jsonl`). Today's 1-level glob silently skipped
    /// those — subagent activity dropped pre-P1.
    func testDiscoversSubagentTranscripts() async throws {
        // Arrange: parent jsonl + subagent jsonl in known subdir shape.
        let projectDir = projectsRoot.appendingPathComponent("-Users-x-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let parentUUID = "parent-abc"
        let agentID = "agent-xyz"

        // Parent jsonl
        let parentFile = projectDir.appendingPathComponent("\(parentUUID).jsonl")
        let parentLine = #"{"type":"user","sessionId":"\#(parentUUID)","content":"parent"}"#
        try (parentLine + "\n").write(to: parentFile, atomically: true, encoding: .utf8)

        // Subagent transcript (sibling subdir)
        let subagentDir = projectDir.appendingPathComponent("\(parentUUID)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        let subagentFile = subagentDir.appendingPathComponent("agent-\(agentID).jsonl")
        let subagentLine = #"{"type":"user","sessionId":"\#(parentUUID)","content":"subagent"}"#
        try (subagentLine + "\n").write(to: subagentFile, atomically: true, encoding: .utf8)

        // Meta sidecar (not strictly required for this discovery test — discovery should
        // find the jsonl whether or not meta.json exists yet; Task 7 + Task 10 handle meta).
        let metaFile = subagentDir.appendingPathComponent("agent-\(agentID).meta.json")
        try Data(#"{"agentType":"Explore","description":"audit"}"#.utf8).write(to: metaFile)

        // Act: full tick. MockOneEventParser emits 1 RawEvent per line → 2 events total.
        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = ClaudeCodeCollector(
            database: writer,
            parser: MockOneEventParser(),
            projectsRoot: projectsRoot,
            intervalSec: 999,
            backfillWindowDays: 7,
            logger: logger
        )
        let result = await collector.performTick(now: Date())

        // Assert: both files discovered + tail-read → 2 events.
        XCTAssertEqual(result.filesScanned, 2, "discovery must include both parent and subagent jsonl")
        XCTAssertEqual(result.eventsWritten, 2, "1 line per file → 2 events total")

        let allRange = DateInterval(start: .distantPast, end: .distantFuture)
        let events = try writer.events(in: allRange)
        XCTAssertEqual(events.count, 2)
    }

    /// Track-6 P1 — multiple concurrent subagents under one parent: each gets its own offset.
    func testDiscoversMultipleSubagentsUnderOneParent() async throws {
        let projectDir = projectsRoot.appendingPathComponent("-Users-x-multi", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let parentUUID = "parent-multi"
        try Data(#"{"type":"user","sessionId":"\#(parentUUID)"}"#.utf8 + Data("\n".utf8))
            .write(to: projectDir.appendingPathComponent("\(parentUUID).jsonl"))

        let subagentDir = projectDir.appendingPathComponent("\(parentUUID)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        for agentID in ["a1", "a2", "a3"] {
            let url = subagentDir.appendingPathComponent("agent-\(agentID).jsonl")
            try Data(#"{"type":"user","sessionId":"\#(parentUUID)","agent":"\#(agentID)"}"#.utf8 + Data("\n".utf8))
                .write(to: url)
        }

        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = ClaudeCodeCollector(
            database: writer,
            parser: MockOneEventParser(),
            projectsRoot: projectsRoot,
            intervalSec: 999,
            backfillWindowDays: 7,
            logger: logger
        )
        let result = await collector.performTick(now: Date())
        XCTAssertEqual(result.filesScanned, 4, "1 parent + 3 subagents")
        XCTAssertEqual(result.eventsWritten, 4)
    }

    /// Track-6 P1 — discovery must NOT recurse beyond `<projectSlug>/<sessionId>/subagents/`.
    /// Random subdir at the project-slug level (e.g. `cache-random/`) must be ignored.
    func testDoesNotRecurseIntoArbitrarySubdirs() async throws {
        let projectDir = projectsRoot.appendingPathComponent("-Users-x-strict", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Top-level jsonl — should be discovered
        try Data(#"{"type":"user","sessionId":"X"}"#.utf8 + Data("\n".utf8))
            .write(to: projectDir.appendingPathComponent("topX.jsonl"))

        // Random subdir with .jsonl — must NOT be discovered.
        // Use `cache-random` (no leading dot) so `.skipsHiddenFiles` doesn't make
        // the test pass for the wrong reason.
        let randomSubdir = projectDir.appendingPathComponent("cache-random", isDirectory: true)
        try FileManager.default.createDirectory(at: randomSubdir, withIntermediateDirectories: true)
        try Data(#"{"type":"user","sessionId":"Y"}"#.utf8 + Data("\n".utf8))
            .write(to: randomSubdir.appendingPathComponent("cached.jsonl"))

        // A nested random subdir (not `subagents/`) under a uuid-like dir — must NOT be discovered.
        let uuidDir = projectDir.appendingPathComponent("uuid-thing", isDirectory: true)
        try FileManager.default.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        let nestedRandom = uuidDir.appendingPathComponent("nested-not-subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRandom, withIntermediateDirectories: true)
        try Data(#"{"type":"user","sessionId":"Z"}"#.utf8 + Data("\n".utf8))
            .write(to: nestedRandom.appendingPathComponent("deep.jsonl"))

        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let collector = ClaudeCodeCollector(
            database: writer,
            parser: MockOneEventParser(),
            projectsRoot: projectsRoot,
            intervalSec: 999,
            backfillWindowDays: 7,
            logger: logger
        )
        let result = await collector.performTick(now: Date())
        XCTAssertEqual(result.filesScanned, 1, "only top-level jsonl, not random subdirs")
        XCTAssertEqual(result.eventsWritten, 1)
    }
}

// MARK: - Mock parser

/// Возвращает `.events([RawEvent])` size 1 для каждой непустой line. Не парсит
/// JSON — нужен только для проверки collector mechanics (split / offset / atomic write).
private struct MockOneEventParser: ClaudeCodeJSONLParsing {
    func parse(line: String, source: String, now: Date) -> ClaudeCodeParseResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .irrelevant
        }
        let event = RawEvent(
            timestamp: now,
            signalType: .aiCollaboration,
            bundleID: "com.anthropic.claude-code",
            payload: [
                "event_kind": "user_prompt",
                "source": source
            ]
        )
        return .events([event])
    }
}
