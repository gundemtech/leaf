// Phase 4.4 B6 — SlackCollector polling lifecycle tests.
// Mock provider в этом файле; production REST parser tested separately
// в LeafCorePrivateTests/ProdSlackAPIProviderTests (moat).

import XCTest
import os
@testable import LeafCore

final class SlackCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-collector")

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

    // MARK: - Mock provider

    /// Captures `since` / `userID` calls для assertion'ов; injectable
    /// `nextResult: SlackTickResult` (default — `.empty`).
    private actor MockSlackAPIProvider: SlackAPIProvider {
        private(set) var sinceCalls: [Int64?] = []
        private(set) var userIDCalls: [String] = []
        private var nextResult: SlackTickResult = .empty

        func fetchTick(
            accessToken: String,
            userID: String,
            since: Int64?,
            now: Date
        ) async throws -> SlackTickResult {
            sinceCalls.append(since)
            userIDCalls.append(userID)
            return nextResult
        }

        func setResult(_ result: SlackTickResult) { nextResult = result }
        func sinceHistory() -> [Int64?] { sinceCalls }
        func userIDHistory() -> [String] { userIDCalls }
    }

    // MARK: - Helpers

    private func makeDB() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func insertFreshIntegration(
        db: Database,
        workspaceID: String = "T123:U456",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) throws {
        let record = IntegrationRecord(
            provider: .slack,
            workspaceID: workspaceID,
            workspaceName: "Acme",
            accessToken: "xoxe.xoxp-test",
            refreshToken: "xoxe-1-test",
            expiresAt: expiresAt,
            scope: SlackOAuthEndpoints.userScopes,
            connectedAt: Date(),
            updatedAt: Date()
        )
        try db.upsertIntegration(record)
    }

    private func makeCollector(
        db: Database,
        provider: any SlackAPIProvider,
        intervalSec: TimeInterval = 999
    ) -> SlackCollector {
        let refresher = SlackTokenRefresher(database: db, clientID: "test-client")
        return SlackCollector(
            database: db,
            provider: provider,
            refresher: refresher,
            intervalSec: intervalSec,
            backfillWindowDays: 7,
            logger: logger
        )
    }

    private func huddleEventInDB(state: String, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "huddle_state_change",
                "state": state
            ]
        )
    }

    // MARK: - Tests

    /// Без integration row → tick skipped, provider не вызывается.
    func testTickWithoutIntegrationSkips() async throws {
        let db = try makeDB()
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        let result = await collector.performTick()

        XCTAssertTrue(result.skipped)
        XCTAssertEqual(result.messageEventsEmitted, 0)
        XCTAssertFalse(result.huddleTransitionEmitted)
        XCTAssertNil(result.cursorAdvancedMs)

        let calls = await provider.sinceHistory()
        XCTAssertEqual(calls.count, 0)
    }

    /// Со свежим integration + 2 channels × counts → 2 message events
    /// + offset cursor в одной транзакции. Bootstrap path → since=nil.
    func testTickPersistsMessageEventsAndCursor() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        let cursorMs: Int64 = 1_700_000_300_000
        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        await provider.setResult(SlackTickResult(
            huddle: .unknown,  // не emit'ит huddle event — очищает изоляцию теста
            channelMessageCounts: [
                SlackChannelMessageCount(channelName: "engineering", count: 3),
                SlackChannelMessageCount(channelName: "DM", count: 5)
            ],
            cursorMs: cursorMs,
            periodStartMs: periodStart,
            periodEndMs: periodEnd
        ))

        let collector = makeCollector(db: db, provider: provider)
        let result = await collector.performTick()

        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.messageEventsEmitted, 2)
        XCTAssertFalse(result.huddleTransitionEmitted)
        XCTAssertEqual(result.cursorAdvancedMs, cursorMs)

        // Offset persisted.
        let offset = try db.readOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: "slack:T123:U456"
        )
        XCTAssertEqual(offset?.lastModifiedMs, cursorMs)

        // Bootstrap: первый call → since=nil; userID извлечён из workspaceID после ":".
        let sinceCalls = await provider.sinceHistory()
        XCTAssertEqual(sinceCalls.count, 1)
        XCTAssertNil(sinceCalls[0])
        let userIDCalls = await provider.userIDHistory()
        XCTAssertEqual(userIDCalls, ["U456"])

        // Events действительно записаны в DB как action со source=slack.
        let writtenEvents = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 - 1),
                end: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 + 1)
            )
        )
        XCTAssertEqual(writtenEvents.count, 2)
        XCTAssertEqual(Set(writtenEvents.map { $0.payload["channel_name"] ?? "" }), ["engineering", "DM"])
        XCTAssertEqual(Set(writtenEvents.map { $0.payload["count"] ?? "" }), ["3", "5"])
        for e in writtenEvents {
            XCTAssertEqual(e.signalType, .action)
            XCTAssertEqual(e.payload["source"], "slack")
            XCTAssertEqual(e.payload["event_kind"], "message_authored_aggregate")
        }
    }

    /// Last DB huddle event = default_unset, tick.huddle = inAHuddle →
    /// emit одно context event с state="in_a_huddle".
    func testTickEmitsHuddleTransitionOnStateChange() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        // baseline: предыдущее состояние было default_unset.
        try db.write([huddleEventInDB(state: "default_unset", atMs: 1_700_000_000_000)])

        let provider = MockSlackAPIProvider()
        await provider.setResult(SlackTickResult(
            huddle: .inAHuddle,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))

        let now = Date(timeIntervalSince1970: 1_700_000_900)
        let collector = makeCollector(db: db, provider: provider)
        let result = await collector.performTick(now: now)

        XCTAssertFalse(result.skipped)
        XCTAssertEqual(result.messageEventsEmitted, 0)
        XCTAssertTrue(result.huddleTransitionEmitted)

        let latest = try db.readLatestSlackHuddleEvent()
        XCTAssertEqual(latest?.state, "in_a_huddle")
        XCTAssertEqual(latest?.tsMs, Int64(now.timeIntervalSince1970 * 1000))
    }

    /// Last DB huddle event = inAHuddle, tick.huddle = inAHuddle →
    /// transition НЕ emit'ится. Latest huddle event в DB остаётся прежним.
    func testTickSuppressesHuddleEventWhenStateUnchanged() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let baselineMs: Int64 = 1_700_000_000_000
        try db.write([huddleEventInDB(state: "in_a_huddle", atMs: baselineMs)])

        let provider = MockSlackAPIProvider()
        await provider.setResult(SlackTickResult(
            huddle: .inAHuddle,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))

        let collector = makeCollector(db: db, provider: provider)
        let result = await collector.performTick()

        XCTAssertFalse(result.huddleTransitionEmitted)

        let latest = try db.readLatestSlackHuddleEvent()
        XCTAssertEqual(latest?.state, "in_a_huddle")
        XCTAssertEqual(latest?.tsMs, baselineMs, "baseline ts должен сохраниться — нового event нет")
    }

    /// tick.huddle = .unknown (provider не смог fetch / forward-compat) →
    /// transition НЕ emit'ится независимо от DB-state.
    func testTickSuppressesHuddleEventWhenUnknown() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        try db.write([huddleEventInDB(state: "in_a_huddle", atMs: 1_700_000_000_000)])

        let provider = MockSlackAPIProvider()
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))

        let collector = makeCollector(db: db, provider: provider)
        let result = await collector.performTick()

        XCTAssertFalse(result.huddleTransitionEmitted)
        XCTAssertEqual(result.messageEventsEmitted, 0)
    }

    /// Empty batch (no messages, huddle .unknown) → cursor НЕ двигается.
    /// Второй tick передаёт прежний since.
    func testTickDoesNotAdvanceCursorOnEmptyBatch() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        // First tick: даёт cursor=10000.
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [
                SlackChannelMessageCount(channelName: "engineering", count: 1)
            ],
            cursorMs: 10_000,
            periodStartMs: 5_000,
            periodEndMs: 10_000
        ))
        let collector = makeCollector(db: db, provider: provider)
        _ = await collector.performTick()

        // Second tick: empty batch, no transition.
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))
        let result = await collector.performTick()

        XCTAssertEqual(result.messageEventsEmitted, 0)
        // Cursor остался 10000 (since из stored offset; provider не дал новый).
        XCTAssertEqual(result.cursorAdvancedMs, 10_000)

        // Третий tick передаёт тот же since=10000 (cursor не двинулся).
        let sinceCalls = await provider.sinceHistory()
        XCTAssertEqual(sinceCalls.count, 2)
        XCTAssertNil(sinceCalls[0], "первый tick — bootstrap")
        XCTAssertEqual(sinceCalls[1], 10_000, "второй tick — stored cursor")

        let offset = try db.readOffset(
            collectorID: CollectorID.slackPolling,
            sourceID: "slack:T123:U456"
        )
        XCTAssertEqual(offset?.lastModifiedMs, 10_000, "cursor не двигается на empty batch")
    }

    /// Phase 4.6.A.3 — reactionsCount > 0 → payload содержит "reactions_count";
    /// reactionsCount == 0 → ключ ОТСУТСТВУЕТ (не пустая строка). Это позволяет
    /// SQL aggregator'у различать pre-4.6 events от 0-samples через `IS NOT NULL`.
    func testTickEncodesReactionsCountInPayloadWhenPositive() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)

        let provider = MockSlackAPIProvider()
        let cursorMs: Int64 = 1_700_000_300_000
        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [
                SlackChannelMessageCount(channelName: "engineering", count: 3, reactionsCount: 7),
                SlackChannelMessageCount(channelName: "random", count: 1, reactionsCount: 0)
            ],
            cursorMs: cursorMs,
            periodStartMs: periodStart,
            periodEndMs: periodEnd
        ))

        let collector = makeCollector(db: db, provider: provider)
        let result = await collector.performTick()
        XCTAssertEqual(result.messageEventsEmitted, 2)

        let writtenEvents = try db.events(
            in: DateInterval(
                start: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 - 1),
                end: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 + 1)
            )
        )
        XCTAssertEqual(writtenEvents.count, 2)
        let eng = writtenEvents.first(where: { $0.payload["channel_name"] == "engineering" })
        let rand = writtenEvents.first(where: { $0.payload["channel_name"] == "random" })
        XCTAssertEqual(eng?.payload["reactions_count"], "7")
        XCTAssertNil(rand?.payload["reactions_count"], "ключ должен ОТСУТСТВОВАТЬ при reactionsCount=0, не быть пустой строкой")

        // Sanity: existing fields неизменны.
        XCTAssertEqual(eng?.payload["count"], "3")
        XCTAssertEqual(rand?.payload["count"], "1")
        XCTAssertEqual(eng?.payload["event_kind"], "message_authored_aggregate")
    }

    /// start запускает loopTask, stop его cancels + awaits.
    /// Без integration row provider не должен вызываться (skip path).
    func testStartStopLifecycle() async throws {
        let db = try makeDB()
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider, intervalSec: 0.05)

        await collector.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        await collector.stop()

        let calls = await provider.sinceHistory()
        XCTAssertEqual(calls.count, 0, "skip path не должен вызывать provider")
    }
}
