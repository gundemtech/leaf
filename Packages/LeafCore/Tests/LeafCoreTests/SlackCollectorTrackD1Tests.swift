// Track-1 D1 — SlackCollector thread reply aggregation, fan-out budgets,
// per-thread cursors, and 429 graceful degrade. Split from
// SlackCollectorTests.swift for type_body_length.

import XCTest
import os

@testable import LeafCore

// swiftlint:disable force_unwrapping

final class SlackCollectorTrackD1Tests: XCTestCase {
    private typealias Support = SlackCollectorTestSupport
    private typealias MockSlackAPIProvider = SlackCollectorTestSupport.MockSlackAPIProvider

    private var tempDir: URL!
    private var dbURL: URL!
    private var logger: Logger { SlackCollectorTestSupport.logger }

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .removeObject(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .removeObject(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> Database {
        try Support.makeDB(at: dbURL)
    }

    private func insertFreshIntegration(
        db: Database, workspaceID: String = "T123:U456",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        try Support.insertFreshIntegration(db: db, workspaceID: workspaceID, expiresAt: expiresAt)
    }

    private func makeCollector(
        db: Database, provider: any SlackAPIProvider,
        intervalSec: TimeInterval = 999, maxThreadsPerTick: Int = Int.max
    ) -> SlackCollector {
        Support.makeCollector(db: db, provider: provider, intervalSec: intervalSec, maxThreadsPerTick: maxThreadsPerTick)
    }

    // MARK: - Track-1 D1 tests

    /// Track-1 D1: provider returns batch with 2 messages per channel.
    /// message_authored_aggregate event must carry `messages_json` payload key,
    /// must NOT carry a top-level `body` key.
    func testTick_MessagesJSON_ForAggregate_TrackD1() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        let msgs = [
            SlackMessageRecord(ts: "1700000001.000001", threadTs: nil, channelID: "C001", text: "Hello team"),
            SlackMessageRecord(ts: "1700000002.000001", threadTs: nil, channelID: "C001", text: "Follow-up message"),
        ]
        await provider.setResult(
            SlackTickResult(
                huddle: .unknown,
                channelMessageCounts: [
                    SlackChannelMessageCount(
                        channelName: "engineering",
                        count: 2,
                        messages: msgs
                    )
                ],
                cursorMs: periodEnd,
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            ))

        let collector = makeCollector(db: db, provider: provider)
        let result = await collector.performTick()

        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.messageEventsEmitted, 1)

        // Read message_authored_aggregate event from DB.
        let events = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 - 1),
                end: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 + 1)
            )
        ).filter { $0.payload["event_kind"] == "slack_message_authored_aggregate" }

        XCTAssertEqual(events.count, 1, "должен быть ровно 1 message_authored_aggregate event")
        let event = try XCTUnwrap(events.first)

        // messages_json must be present and decodable.
        let messagesJsonStr = try XCTUnwrap(
            event.payload["messages_json"],
            "messages_json payload key должен присутствовать")
        let messagesData = try XCTUnwrap(messagesJsonStr.data(using: .utf8))
        let decoded = try JSONDecoder().decode([SlackMessageRecord].self, from: messagesData)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(Set(decoded.map { $0.ts }), ["1700000001.000001", "1700000002.000001"])

        // Top-level `body` key must NOT be present (multiple messages, no single body).
        XCTAssertNil(event.payload["body"], "message_authored_aggregate не должен иметь top-level body key")
    }

    /// Track-1 D1: N threads in batch > maxThreadsPerTick cap.
    /// fetchThreadReplies call count must equal cap, not N.
    func testTick_ThreadFanOut_BoundedByBudget_TrackD1() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        let cap = 3
        let periodEnd: Int64 = 1_700_000_300_000

        // Build 5 messages, each starting a distinct thread (thread_ts == ts → initiation).
        // threadReplyCount = 0 here since replies are fetched from the batch,
        // but we need threads with thread_ts to trigger fan-out.
        // Use messages field to carry thread ts info so collector knows which threads to fan-out.
        var msgs: [SlackMessageRecord] = []
        for i in 1...5 {
            let ts = "1700000\(String(format: "%03d", i)).000001"
            // thread_ts == ts → this message initiates a thread that may have replies.
            msgs.append(SlackMessageRecord(ts: ts, threadTs: ts, channelID: "C001", text: "Thread starter \(i)"))
        }

        // Set a non-empty reply batch so threads are actually processed.
        let parentMsg = SlackMessageRecord(
            ts: "1700000001.000001", threadTs: "1700000001.000001", channelID: "C001", text: "Parent")
        let replyMsg = SlackMessageRecord(
            ts: "1700000001.000100", threadTs: "1700000001.000001", channelID: "C001", text: "Reply")
        await provider.setThreadReplyBatch(
            SlackThreadReplyBatch(parent: parentMsg, replies: [replyMsg], nextCursor: nil))

        await provider.setResult(
            SlackTickResult(
                huddle: .unknown,
                channelMessageCounts: [
                    SlackChannelMessageCount(
                        channelName: "engineering",
                        count: 5,
                        messages: msgs
                    )
                ],
                cursorMs: periodEnd,
                periodStartMs: 1_700_000_000_000,
                periodEndMs: periodEnd
            ))

        let collector = makeCollector(db: db, provider: provider, maxThreadsPerTick: cap)
        _ = await collector.performTick()

        let calls = await provider.threadReplyCallHistory()
        XCTAssertEqual(
            calls.count, cap,
            "fetchThreadReplies должен вызываться не более maxThreadsPerTick раз (\(cap)), но вызван \(calls.count) раз"
        )
    }

    /// Track-1 D1: per-thread cursor advances after successful reply fetch.
    /// First tick: replies returned with latestTs; read collector_offsets row,
    /// assert cursor matches. Second tick: provider called with oldest=cursor.
    func testTick_PerThreadCursorAdvances_TrackD1() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        let channelID = "C001"
        let threadTs = "1700000001.000001"
        let replyTs = "1700000002.000050"
        let periodEnd: Int64 = 1_700_000_300_000

        let msgs = [
            SlackMessageRecord(ts: threadTs, threadTs: threadTs, channelID: channelID, text: "Thread starter")
        ]
        let parentMsg = SlackMessageRecord(ts: threadTs, threadTs: threadTs, channelID: channelID, text: "Parent text")
        let replyMsg = SlackMessageRecord(ts: replyTs, threadTs: threadTs, channelID: channelID, text: "Reply text")

        await provider.setThreadReplyBatch(
            SlackThreadReplyBatch(parent: parentMsg, replies: [replyMsg], nextCursor: nil))
        await provider.setResult(
            SlackTickResult(
                huddle: .unknown,
                channelMessageCounts: [
                    SlackChannelMessageCount(channelName: "engineering", count: 1, messages: msgs)
                ],
                cursorMs: periodEnd,
                periodStartMs: 1_700_000_000_000,
                periodEndMs: periodEnd
            ))

        let collector = makeCollector(db: db, provider: provider)

        // First tick — cursor starts nil, thread should be fetched.
        _ = await collector.performTick()

        // Verify cursor was stored in collector_offsets.
        let threadSourceID = "slack:thread:\(channelID):\(threadTs)"
        let storedOffset = try db.readOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: threadSourceID
        )
        XCTAssertNotNil(storedOffset, "collector_offsets должен содержать курсор для thread \(threadTs)")
        // The cursor should reflect the latest reply ts.
        let expectedCursorMs = Int64(Double(replyTs)! * 1000)
        XCTAssertEqual(
            storedOffset?.lastModifiedMs, expectedCursorMs,
            "Cursor должен соответствовать ms времени последнего reply")

        // Second tick — collector must pass oldest based on stored cursor (ms precision).
        // Slack ts "1700000002.000050" → Int64 ms truncation → "1700000002.000000".
        // This is expected: Int64 ms gives millisecond precision (Slack ts = sec.microsec).
        _ = await collector.performTick()

        let calls = await provider.threadReplyCallHistory()
        XCTAssertGreaterThanOrEqual(calls.count, 2, "второй tick должен вызвать fetchThreadReplies снова")
        let secondCall = calls[1]
        let expectedOldest = String(format: "%.6f", Double(Int64(Double(replyTs)! * 1000)) / 1000.0)
        XCTAssertEqual(
            secondCall.oldest, expectedOldest,
            "второй tick должен передавать oldest с ms-точностью (Slack ts truncated to ms)")
    }

    /// Track-1 D1: mock throws RateLimitError on N-th thread.
    /// Events for first N-1 threads written; N-th thread cursor not advanced.
    func testTick_429GracefulDegrade_TrackD1() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        let channelID = "C001"
        let ts1 = "1700000001.000001"
        let ts2 = "1700000002.000001"
        let ts3 = "1700000003.000001"
        let periodEnd: Int64 = 1_700_000_300_000

        let msgs = [
            SlackMessageRecord(ts: ts1, threadTs: ts1, channelID: channelID, text: "Thread 1"),
            SlackMessageRecord(ts: ts2, threadTs: ts2, channelID: channelID, text: "Thread 2"),
            SlackMessageRecord(ts: ts3, threadTs: ts3, channelID: channelID, text: "Thread 3"),
        ]

        let parentMsg = SlackMessageRecord(ts: ts1, threadTs: ts1, channelID: channelID, text: "Parent")
        let replyMsg = SlackMessageRecord(ts: "1700000001.500000", threadTs: ts1, channelID: channelID, text: "Reply")
        await provider.setThreadReplyBatch(
            SlackThreadReplyBatch(parent: parentMsg, replies: [replyMsg], nextCursor: nil))

        // 3rd thread throws 429.
        await provider.setThreadReplyThrowOn(ts3)

        await provider.setResult(
            SlackTickResult(
                huddle: .unknown,
                channelMessageCounts: [
                    SlackChannelMessageCount(channelName: "engineering", count: 3, messages: msgs)
                ],
                cursorMs: periodEnd,
                periodStartMs: 1_700_000_000_000,
                periodEndMs: periodEnd
            ))

        let collector = makeCollector(db: db, provider: provider)
        _ = await collector.performTick()

        // Threads 1 and 2 should have cursor offsets (processed successfully).
        let offset1 = try db.readOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: "slack:thread:\(channelID):\(ts1)")
        let offset2 = try db.readOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: "slack:thread:\(channelID):\(ts2)")
        // Thread 3 should NOT have a cursor (429 broke the loop before it was processed).
        let offset3 = try db.readOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: "slack:thread:\(channelID):\(ts3)")

        XCTAssertNotNil(offset1, "thread 1 должен иметь курсор — успешно обработан")
        XCTAssertNotNil(offset2, "thread 2 должен иметь курсор — успешно обработан")
        XCTAssertNil(offset3, "thread 3 не должен иметь курсор — 429 до обработки")

        // Calls: ts1, ts2, ts3 (throws) → 3 calls total.
        let calls = await provider.threadReplyCallHistory()
        XCTAssertEqual(calls.count, 3, "fetchThreadReplies должен вызываться до 429-го thread'а включительно")
    }
}
// swiftlint:enable force_unwrapping
