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
