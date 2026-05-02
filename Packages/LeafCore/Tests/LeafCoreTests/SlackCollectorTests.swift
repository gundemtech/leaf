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
    /// Phase 4.7.B-9 — также injectable presence + counter для tick'ов.
    /// Phase 4.7.B-10 — также injectable DND + counter для tick'ов.
    /// Phase 4.7.B-11 — также injectable mentions + counter для tick'ов.
    /// Phase 4.7.B-12 — также injectable file upload summary + counter.
    private actor MockSlackAPIProvider: SlackAPIProvider {
        private(set) var sinceCalls: [Int64?] = []
        private(set) var userIDCalls: [String] = []
        private(set) var presenceCalls: Int = 0
        private(set) var dndCalls: Int = 0
        private(set) var mentionCalls: Int = 0
        private(set) var mentionSinceCalls: [Int64] = []
        private(set) var filesCalls: Int = 0
        private(set) var filesSinceCalls: [Int64] = []
        private var nextResult: SlackTickResult = .empty
        private var nextPresence: SlackPresenceState = .unknown
        private var nextDND: SlackDNDState = .empty
        private var nextMentions: [SlackMentionChannelCount] = []
        private var nextFiles: SlackFileUploadSummary = .empty(periodStartMs: 0, periodEndMs: 0)
        private var presenceShouldThrow: Bool = false
        private var dndShouldThrow: Bool = false
        private var mentionsShouldThrow: Bool = false
        private var filesShouldThrow: Bool = false

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

        func fetchPresence(
            accessToken: String,
            userID: String
        ) async throws -> SlackPresenceState {
            presenceCalls += 1
            if presenceShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextPresence
        }

        func fetchDND(
            accessToken: String,
            userID: String
        ) async throws -> SlackDNDState {
            dndCalls += 1
            if dndShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextDND
        }

        func fetchMentionsReceived(
            accessToken: String,
            userID: String,
            since: Int64
        ) async throws -> [SlackMentionChannelCount] {
            mentionCalls += 1
            mentionSinceCalls.append(since)
            if mentionsShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextMentions
        }

        func fetchFilesUploaded(
            accessToken: String,
            userID: String,
            since: Int64
        ) async throws -> SlackFileUploadSummary {
            filesCalls += 1
            filesSinceCalls.append(since)
            if filesShouldThrow {
                struct DummyError: Error {}
                throw DummyError()
            }
            return nextFiles
        }

        func setResult(_ result: SlackTickResult) { nextResult = result }
        func setPresence(_ presence: SlackPresenceState) { nextPresence = presence }
        func setPresenceShouldThrow(_ shouldThrow: Bool) { presenceShouldThrow = shouldThrow }
        func setDND(_ dnd: SlackDNDState) { nextDND = dnd }
        func setDNDShouldThrow(_ shouldThrow: Bool) { dndShouldThrow = shouldThrow }
        func setMentions(_ mentions: [SlackMentionChannelCount]) { nextMentions = mentions }
        func setMentionsShouldThrow(_ shouldThrow: Bool) { mentionsShouldThrow = shouldThrow }
        func setFiles(_ files: SlackFileUploadSummary) { nextFiles = files }
        func setFilesShouldThrow(_ shouldThrow: Bool) { filesShouldThrow = shouldThrow }
        func sinceHistory() -> [Int64?] { sinceCalls }
        func userIDHistory() -> [String] { userIDCalls }
        func presenceCallCount() -> Int { presenceCalls }
        func dndCallCount() -> Int { dndCalls }
        func mentionCallCount() -> Int { mentionCalls }
        func mentionSinceHistory() -> [Int64] { mentionSinceCalls }
        func filesCallCount() -> Int { filesCalls }
        func filesSinceHistory() -> [Int64] { filesSinceCalls }
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

    // MARK: - Phase 4.7.A — slack_status_change

    /// First tick observed=":coffee:", lastEmitted=nil → emit. Second tick тот же
    /// emoji → no emit. Third tick observed=":pizza:" → emit.
    func testTickStatusEmojiChangeEmitsEvent() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        // Tick 1: observed=":coffee:" → emit slack_status_change.
        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0, periodEndMs: 0,
            statusEmoji: ":coffee:",
            statusExpirationTs: 0
        ))
        let r1 = await collector.performTick()
        XCTAssertTrue(r1.statusChangeEmitted, "first observation always emits")

        // Tick 2: same emoji → no emit.
        let r2 = await collector.performTick()
        XCTAssertFalse(r2.statusChangeEmitted, "unchanged emoji не emit")

        // Tick 3: different emoji → emit.
        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0, periodEndMs: 0,
            statusEmoji: ":pizza:",
            statusExpirationTs: 1_730_000_000_000
        ))
        let r3 = await collector.performTick()
        XCTAssertTrue(r3.statusChangeEmitted, "different emoji → emit")

        // Verify DB rows.
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSinceNow: -3600),
            end: Date(timeIntervalSinceNow: 3600)
        ))
        let statusEvents = stored.filter { $0.payload["event_kind"] == "slack_status_change" }
        XCTAssertEqual(statusEvents.count, 2, "1 + 1 status_change events")
        XCTAssertEqual(Set(statusEvents.compactMap { $0.payload["status_emoji"] }),
                       Set([":coffee:", ":pizza:"]))
        let pizza = try XCTUnwrap(statusEvents.first { $0.payload["status_emoji"] == ":pizza:" })
        XCTAssertEqual(pizza.payload["status_expiration_ts"], "1730000000000")
    }

    /// emoji "" → "" → "" — no emit ни разу (lastEmittedStatusEmoji=nil
    /// only first tick).
    func testTickStatusEmojiUnsetFirstObservationEmitsBaseline() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0, periodEndMs: 0,
            statusEmoji: "",
            statusExpirationTs: 0
        ))
        // First-ever observation always emits (nil → "").
        let r1 = await collector.performTick()
        XCTAssertTrue(r1.statusChangeEmitted)
        // Second tick — equal "" → no emit.
        let r2 = await collector.performTick()
        XCTAssertFalse(r2.statusChangeEmitted)
    }

    // MARK: - Phase 4.7.A — slack_thread_reply_aggregate

    func testTickThreadReplyAggregateEmittedWhenCountPositive() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        let baseMs: Int64 = 1_700_000_000_000
        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [
                SlackChannelMessageCount(
                    channelName: "engineering",
                    count: 7,
                    reactionsCount: 0,
                    threadReplyCount: 5
                )
            ],
            cursorMs: baseMs,
            periodStartMs: baseMs - 300_000,
            periodEndMs: baseMs,
            statusEmoji: "",
            statusExpirationTs: 0
        ))

        let r = await collector.performTick()
        XCTAssertEqual(r.messageEventsEmitted, 1)
        XCTAssertEqual(r.threadReplyEventsEmitted, 1)

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(baseMs - 1_000_000) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(baseMs + 1_000_000) / 1000)
        ))
        let regular = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "message_authored_aggregate" })
        XCTAssertEqual(regular.payload["count"], "7")

        let thread = try XCTUnwrap(stored.first { $0.payload["event_kind"] == "slack_thread_reply_aggregate" })
        XCTAssertEqual(thread.payload["count"], "5", "subset of total — replies only")
        XCTAssertEqual(thread.payload["channel_name"], "engineering")
    }

    func testTickNoThreadReplyEventWhenCountZero() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        let baseMs: Int64 = 1_700_000_000_000
        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [
                SlackChannelMessageCount(
                    channelName: "engineering",
                    count: 5,
                    reactionsCount: 0,
                    threadReplyCount: 0
                )
            ],
            cursorMs: baseMs,
            periodStartMs: baseMs - 300_000,
            periodEndMs: baseMs
        ))

        let r = await collector.performTick()
        XCTAssertEqual(r.messageEventsEmitted, 1)
        XCTAssertEqual(r.threadReplyEventsEmitted, 0, "threadReplyCount=0 → no event")
    }

    // MARK: - Phase 4.7.B-9 — slack_presence_state pulse

    /// Pulse emit'ится КАЖДЫЙ non-skipped tick (active / away / unknown). Mirror
    /// к github_notifications_pulse: observation continuity > shrunk row count.
    /// Также проверяем что network throw в provider'е graceful'но degrade'ит в
    /// state="unknown" event (не блокирует tick).
    func testTick_EmitsSlackPresenceStateEvent() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        // Tick 1 — presence=active.
        await provider.setPresence(.active)
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))
        let now1 = Date(timeIntervalSince1970: 1_700_000_100)
        let r1 = await collector.performTick(now: now1)
        XCTAssertTrue(r1.presenceStateEmitted, "always emit on non-skipped tick")
        let calls1 = await provider.presenceCallCount()
        XCTAssertEqual(calls1, 1)

        // Tick 2 — presence=away.
        await provider.setPresence(.away)
        let now2 = Date(timeIntervalSince1970: 1_700_000_400)
        let r2 = await collector.performTick(now: now2)
        XCTAssertTrue(r2.presenceStateEmitted)
        let calls2 = await provider.presenceCallCount()
        XCTAssertEqual(calls2, 2)

        // Tick 3 — provider throws → graceful unknown, pulse still emit.
        await provider.setPresenceShouldThrow(true)
        let now3 = Date(timeIntervalSince1970: 1_700_000_700)
        let r3 = await collector.performTick(now: now3)
        XCTAssertTrue(r3.presenceStateEmitted, "even на network throw мы emit pulse (unknown)")
        let calls3 = await provider.presenceCallCount()
        XCTAssertEqual(calls3, 3)

        // Verify DB: 3 slack_presence_state events с правильным state mapping.
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_001_000)
        ))
        let presenceEvents = stored.filter { $0.payload["event_kind"] == "slack_presence_state" }
        XCTAssertEqual(presenceEvents.count, 3, "3 ticks → 3 pulses")
        for e in presenceEvents {
            XCTAssertEqual(e.signalType, .context, "pulse — state event, не user action")
            XCTAssertEqual(e.payload["source"], "slack")
            XCTAssertNotNil(e.payload["observed_at_ms"])
        }
        let states = presenceEvents
            .compactMap { $0.payload["state"] }
            .sorted()
        XCTAssertEqual(states, ["active", "away", "unknown"])

        // observed_at_ms = nowMs (per tick).
        let activeEv = try XCTUnwrap(presenceEvents.first { $0.payload["state"] == "active" })
        XCTAssertEqual(activeEv.payload["observed_at_ms"], String(Int64(now1.timeIntervalSince1970 * 1000)))
    }

    // MARK: - Phase 4.7.B-10 — slack_dnd_state pulse

    /// Pulse emit'ится КАЖДЫЙ non-skipped tick (active DND / inactive / scheduled-only /
    /// graceful empty). Mirror к slack_presence_state. Также проверяем что network
    /// throw в provider'е graceful'но degrade'ит в empty event без блокировки tick'а,
    /// и что nil ts-поля омитятся из payload (consistent с existing conventions).
    func testTick_EmitsSlackDNDStateEvent() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        // Tick 1 — DND active с user-set snooze.
        await provider.setDND(SlackDNDState(
            dndEnabled: true,
            snoozeUntilMs: 1_700_001_000_000,
            nextDNDStartMs: nil,
            nextDNDEndMs: nil
        ))
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))
        let now1 = Date(timeIntervalSince1970: 1_700_000_100)
        let r1 = await collector.performTick(now: now1)
        XCTAssertTrue(r1.dndStateEmitted, "always emit on non-skipped tick")
        let calls1 = await provider.dndCallCount()
        XCTAssertEqual(calls1, 1)

        // Tick 2 — scheduled DND only (recurring schedule), no active snooze.
        await provider.setDND(SlackDNDState(
            dndEnabled: false,
            snoozeUntilMs: nil,
            nextDNDStartMs: 1_700_010_000_000,
            nextDNDEndMs: 1_700_020_000_000
        ))
        let now2 = Date(timeIntervalSince1970: 1_700_000_400)
        let r2 = await collector.performTick(now: now2)
        XCTAssertTrue(r2.dndStateEmitted)
        let calls2 = await provider.dndCallCount()
        XCTAssertEqual(calls2, 2)

        // Tick 3 — provider throws → graceful .empty, pulse still emit.
        await provider.setDNDShouldThrow(true)
        let now3 = Date(timeIntervalSince1970: 1_700_000_700)
        let r3 = await collector.performTick(now: now3)
        XCTAssertTrue(r3.dndStateEmitted, "even на network throw мы emit pulse (empty)")
        let calls3 = await provider.dndCallCount()
        XCTAssertEqual(calls3, 3)

        // Verify DB: 3 slack_dnd_state events с правильным payload mapping.
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_001_000)
        ))
        let dndEvents = stored.filter { $0.payload["event_kind"] == "slack_dnd_state" }
        XCTAssertEqual(dndEvents.count, 3, "3 ticks → 3 pulses")
        for e in dndEvents {
            XCTAssertEqual(e.signalType, .context, "pulse — state event, не user action")
            XCTAssertEqual(e.payload["source"], "slack")
            XCTAssertNotNil(e.payload["observed_at_ms"])
            XCTAssertNotNil(e.payload["dnd_enabled"])
        }

        // Tick 1 — dnd_enabled=true + snooze_until_ms; next_dnd_* ОМИТЯТСЯ (nil → no key).
        let activeEv = try XCTUnwrap(dndEvents.first {
            $0.payload["observed_at_ms"] == String(Int64(now1.timeIntervalSince1970 * 1000))
        })
        XCTAssertEqual(activeEv.payload["dnd_enabled"], "true")
        XCTAssertEqual(activeEv.payload["snooze_until_ms"], "1700001000000")
        XCTAssertNil(activeEv.payload["next_dnd_start_ms"], "nil ts → omitted from payload")
        XCTAssertNil(activeEv.payload["next_dnd_end_ms"])

        // Tick 2 — dnd_enabled=false + scheduled window; snooze_until ОМИТНУТ.
        let scheduledEv = try XCTUnwrap(dndEvents.first {
            $0.payload["observed_at_ms"] == String(Int64(now2.timeIntervalSince1970 * 1000))
        })
        XCTAssertEqual(scheduledEv.payload["dnd_enabled"], "false")
        XCTAssertNil(scheduledEv.payload["snooze_until_ms"])
        XCTAssertEqual(scheduledEv.payload["next_dnd_start_ms"], "1700010000000")
        XCTAssertEqual(scheduledEv.payload["next_dnd_end_ms"], "1700020000000")

        // Tick 3 — graceful empty: dnd_enabled=false, все ts nil.
        let emptyEv = try XCTUnwrap(dndEvents.first {
            $0.payload["observed_at_ms"] == String(Int64(now3.timeIntervalSince1970 * 1000))
        })
        XCTAssertEqual(emptyEv.payload["dnd_enabled"], "false")
        XCTAssertNil(emptyEv.payload["snooze_until_ms"])
        XCTAssertNil(emptyEv.payload["next_dnd_start_ms"])
        XCTAssertNil(emptyEv.payload["next_dnd_end_ms"])
    }

    // MARK: - Phase 4.7.B-11 — slack_mention_received_aggregate

    /// Per-channel mention counts → 1 RawEvent per (channel, count > 0). Verifies
    /// payload shape (event_kind, channel, count, period_*_ms), `signal_type=.action`,
    /// и что графа provider'а вызывается с корректным `since`.
    func testTick_EmitsMentionReceivedAggregatePerChannel() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        // Two channels: "engineering" — 3 mentions, "DM" — 1 mention.
        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        await provider.setMentions([
            SlackMentionChannelCount(
                channelName: "engineering",
                count: 3,
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            ),
            SlackMentionChannelCount(
                channelName: "DM",
                count: 1,
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            )
        ])
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))

        let now = Date(timeIntervalSince1970: 1_700_000_400)
        let result = await collector.performTick(now: now)

        XCTAssertEqual(result.mentionEventsEmitted, 2, "2 channel buckets → 2 events")
        let mentionCalls = await provider.mentionCallCount()
        XCTAssertEqual(mentionCalls, 1, "fetchMentionsReceived вызывается ровно раз per tick")
        // First tick — bootstrap path (no stored cursor) → since=0.
        let mentionSinceHistory = await provider.mentionSinceHistory()
        XCTAssertEqual(mentionSinceHistory, [0], "bootstrap → since=0 (no stored cursor)")

        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 - 1),
            end: Date(timeIntervalSince1970: TimeInterval(periodEnd) / 1000.0 + 1)
        ))
        let mentions = stored.filter { $0.payload["event_kind"] == "slack_mention_received_aggregate" }
        XCTAssertEqual(mentions.count, 2)
        for e in mentions {
            XCTAssertEqual(e.signalType, .action, "mention — triggering action, не state")
            XCTAssertEqual(e.payload["source"], "slack")
            XCTAssertEqual(e.payload["period_start_ms"], String(periodStart))
            XCTAssertEqual(e.payload["period_end_ms"], String(periodEnd))
        }
        let eng = try XCTUnwrap(mentions.first { $0.payload["channel"] == "engineering" })
        XCTAssertEqual(eng.payload["count"], "3")
        let dm = try XCTUnwrap(mentions.first { $0.payload["channel"] == "DM" })
        XCTAssertEqual(dm.payload["count"], "1")
    }

    // MARK: - Phase 4.7.B-12 — slack_file_uploaded_aggregate

    /// Single aggregate event per tick (NOT per-file). Verifies payload shape
    /// (event_kind, count, image_count, code_count, doc_count, other_count,
    /// period_*_ms), `signal_type=.action`, always-emit semantics (даже на zero
    /// count), и что fetchFilesUploaded вызывается ровно раз per tick.
    func testTick_EmitsFileUploadedAggregateEvent() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        // 5 files: 2 images + 1 code + 1 doc + 1 other.
        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        await provider.setFiles(SlackFileUploadSummary(
            count: 5,
            typesSummary: ["image": 2, "code": 1, "doc": 1, "other": 1],
            periodStartMs: periodStart,
            periodEndMs: periodEnd
        ))
        await provider.setResult(SlackTickResult(
            huddle: .unknown,
            channelMessageCounts: [],
            cursorMs: nil,
            periodStartMs: 0,
            periodEndMs: 0
        ))

        let now = Date(timeIntervalSince1970: 1_700_000_400)
        let result = await collector.performTick(now: now)

        XCTAssertTrue(result.fileUploadEventEmitted, "always-emit semantics: 1 aggregate per tick")
        let filesCalls = await provider.filesCallCount()
        XCTAssertEqual(filesCalls, 1, "fetchFilesUploaded вызывается ровно раз per tick")
        // First tick — bootstrap (no stored cursor) → since=0.
        let filesSinceHistory = await provider.filesSinceHistory()
        XCTAssertEqual(filesSinceHistory, [0], "bootstrap → since=0")

        // Найти сам event — timestamp = nowMs (UTC).
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let stored = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 - 1),
            end: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0 + 1)
        ))
        let fileEvents = stored.filter { $0.payload["event_kind"] == "slack_file_uploaded_aggregate" }
        XCTAssertEqual(fileEvents.count, 1, "single aggregate per tick")
        let ev = try XCTUnwrap(fileEvents.first)
        XCTAssertEqual(ev.signalType, .action, "file upload — triggering action")
        XCTAssertEqual(ev.payload["source"], "slack")
        XCTAssertEqual(ev.payload["count"], "5")
        XCTAssertEqual(ev.payload["image_count"], "2")
        XCTAssertEqual(ev.payload["code_count"], "1")
        XCTAssertEqual(ev.payload["doc_count"], "1")
        XCTAssertEqual(ev.payload["other_count"], "1")
        XCTAssertEqual(ev.payload["period_start_ms"], String(periodStart))
        XCTAssertEqual(ev.payload["period_end_ms"], String(periodEnd))

        // Always-emit: tick 2 с zero count тоже emit'ит.
        await provider.setFiles(.empty(periodStartMs: periodEnd, periodEndMs: periodEnd + 1000))
        let now2 = Date(timeIntervalSince1970: 1_700_000_500)
        let result2 = await collector.performTick(now: now2)
        XCTAssertTrue(result2.fileUploadEventEmitted, "zero count → still emit (substrate continuity)")
        let nowMs2 = Int64(now2.timeIntervalSince1970 * 1000)
        let stored2 = try db.events(in: DateInterval(
            start: Date(timeIntervalSince1970: TimeInterval(nowMs2) / 1000.0 - 1),
            end: Date(timeIntervalSince1970: TimeInterval(nowMs2) / 1000.0 + 1)
        ))
        let fileEvents2 = stored2.filter { $0.payload["event_kind"] == "slack_file_uploaded_aggregate" }
        XCTAssertEqual(fileEvents2.count, 1)
        let ev2 = try XCTUnwrap(fileEvents2.first)
        XCTAssertEqual(ev2.payload["count"], "0")
        XCTAssertEqual(ev2.payload["image_count"], "0", "zero buckets explicit, не omitted")
        XCTAssertEqual(ev2.payload["code_count"], "0")
        XCTAssertEqual(ev2.payload["doc_count"], "0")
        XCTAssertEqual(ev2.payload["other_count"], "0")
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
