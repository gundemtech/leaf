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
        // Track-1 D1 — thread reply tracking
        private(set) var threadReplyCalls: [(channelID: String, threadTs: String, oldest: String?)] = []
        private var nextResult: SlackTickResult = .empty
        private var nextPresence: SlackPresenceState = .unknown
        private var nextDND: SlackDNDState = .empty
        private var nextMentions: [SlackMentionChannelCount] = []
        private var nextFiles: SlackFileUploadSummary = .empty(periodStartMs: 0, periodEndMs: 0)
        private var presenceShouldThrow: Bool = false
        private var dndShouldThrow: Bool = false
        private var mentionsShouldThrow: Bool = false
        private var filesShouldThrow: Bool = false
        // Track-1 D1 — per-thread reply config
        private var nextThreadReplyBatch: SlackThreadReplyBatch = .empty
        // Maps threadTs → throw RateLimitError when called (for 429 test)
        private var threadReplyThrowOn: Set<String> = []

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

        func fetchThreadReplies(
            accessToken: String,
            channelID: String,
            threadTs: String,
            ownerUserID: String,
            oldest: String?
        ) async throws -> SlackThreadReplyBatch {
            threadReplyCalls.append((channelID: channelID, threadTs: threadTs, oldest: oldest))
            if threadReplyThrowOn.contains(threadTs) {
                throw RateLimitError.retryAfter(30)
            }
            return nextThreadReplyBatch
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
        // Track-1 D1 thread reply helpers
        func setThreadReplyBatch(_ batch: SlackThreadReplyBatch) { nextThreadReplyBatch = batch }
        func setThreadReplyThrowOn(_ threadTs: String) { threadReplyThrowOn.insert(threadTs) }
        func threadReplyCallHistory() -> [(channelID: String, threadTs: String, oldest: String?)] { threadReplyCalls }
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
        intervalSec: TimeInterval = 999,
        maxThreadsPerTick: Int = Int.max
    ) -> SlackCollector {
        let refresher = SlackTokenRefresher(database: db, clientID: "test-client")
        return SlackCollector(
            database: db,
            provider: provider,
            refresher: refresher,
            intervalSec: intervalSec,
            backfillWindowDays: 7,
            maxThreadsPerTick: maxThreadsPerTick,
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

    // MARK: - Phase 4.7.B-13 — presence_state.slack writer

    /// Plan-required: после tick'а presence_state.slack row существует с composite
    /// state (native presence + dnd + status + huddle + last activity + mention/file
    /// counts), все expected keys присутствуют, derivedMode=nil.
    func testTick_WritesSlackPresenceState() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        await provider.setResult(SlackTickResult(
            huddle: .inAHuddle,
            channelMessageCounts: [
                SlackChannelMessageCount(channelName: "engineering", count: 5),
                SlackChannelMessageCount(channelName: "DM", count: 2)
            ],
            cursorMs: periodEnd,
            periodStartMs: periodStart,
            periodEndMs: periodEnd,
            statusEmoji: ":coffee:",
            statusExpirationTs: 1_700_010_000_000
        ))
        await provider.setPresence(.active)
        await provider.setDND(SlackDNDState(
            dndEnabled: true,
            snoozeUntilMs: 1_700_001_000_000,
            nextDNDStartMs: 1_700_010_000_000,
            nextDNDEndMs: 1_700_020_000_000
        ))
        await provider.setMentions([
            SlackMentionChannelCount(
                channelName: "engineering",
                count: 3,
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            ),
            SlackMentionChannelCount(
                channelName: "DM",
                count: 2,
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            )
        ])
        await provider.setFiles(SlackFileUploadSummary(
            count: 4,
            typesSummary: ["image": 2, "code": 1, "doc": 1, "other": 0],
            periodStartMs: periodStart,
            periodEndMs: periodEnd
        ))

        _ = await collector.performTick()

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .slack, in: rawDB)
        }
        let row = try XCTUnwrap(presence, "presence_state.slack row должен существовать после tick'а")
        XCTAssertNil(row.derivedMode, "derivedMode=nil в Phase 4.7 (Phase 4.9 начнёт populate)")

        let state = row.state
        XCTAssertEqual(state["native_presence"] as? String, "active")
        XCTAssertEqual(state["status_emoji"] as? String, ":coffee:")
        XCTAssertEqual(state["status_expiration_ts"] as? Int64, 1_700_010_000_000)
        XCTAssertEqual(state["in_huddle"] as? Bool, true)
        XCTAssertEqual(state["huddle_channel"] as? String, "")
        XCTAssertEqual(state["last_activity_channel"] as? String, "engineering",
                       "max-count channel — engineering (5) > DM (2)")
        XCTAssertEqual(state["mention_count_today"] as? Int, 5, "3 + 2 = 5")
        XCTAssertEqual(state["file_count_today"] as? Int, 4)

        // Nested dnd dict: 4 keys.
        let dnd = try XCTUnwrap(state["dnd"] as? [String: Any])
        XCTAssertEqual(dnd["is_active"] as? Bool, true)
        XCTAssertEqual(dnd["snooze_until_ms"] as? Int64, 1_700_001_000_000)
        XCTAssertEqual(dnd["next_dnd_start_ms"] as? Int64, 1_700_010_000_000)
        XCTAssertEqual(dnd["next_dnd_end_ms"] as? Int64, 1_700_020_000_000)
    }

    /// ADR-010 regression: presence_state JSON не должен содержать reserved
    /// content keys ("text" / "preview" / "title" / "body") — defensive shape check.
    /// Caller responsibility — этот тест guards boundary.
    func testTick_SlackPresenceStateOmitsBodyFields() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        // Inject sentinel-like channel name (paranoid: это всё равно public-safe
        // identifier, но сверим что body keys никогда не появляются).
        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [
                SlackChannelMessageCount(channelName: "engineering", count: 1)
            ],
            cursorMs: 1_700_000_300_000,
            periodStartMs: 1_700_000_000_000,
            periodEndMs: 1_700_000_300_000,
            statusEmoji: ":pizza:",
            statusExpirationTs: 0
        ))
        await provider.setPresence(.active)
        await provider.setDND(.empty)

        _ = await collector.performTick()

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .slack, in: rawDB)
        }
        let row = try XCTUnwrap(presence)
        let topLevelKeys = Set(row.state.keys)
        XCTAssertFalse(topLevelKeys.contains("text"),
                       "presence_state.slack не должен содержать 'text' top-level key")
        XCTAssertFalse(topLevelKeys.contains("preview"),
                       "presence_state.slack не должен содержать 'preview' top-level key")
        XCTAssertFalse(topLevelKeys.contains("title"),
                       "presence_state.slack не должен содержать 'title' top-level key")
        XCTAssertFalse(topLevelKeys.contains("body"),
                       "presence_state.slack не должен содержать 'body' top-level key")

        // Paranoid: serialized JSON не должен иметь body markers.
        let serialized = try JSONSerialization.data(withJSONObject: row.state, options: [])
        let serializedStr = String(data: serialized, encoding: .utf8) ?? ""
        for forbidden in ["\"text\"", "\"preview\"", "\"title\"", "\"body\""] {
            XCTAssertFalse(serializedStr.contains(forbidden),
                           "serialized state не должен содержать ключ \(forbidden)")
        }
    }

    /// Roundtrip: write → read → assert dict equality для всех expected keys
    /// (включая nested `dnd`). Verifies, что JSONSerialization сохранение через
    /// `PresenceStateWriter.upsert` + `read` не теряет nested struct.
    func testTick_SlackPresenceStateRoundtrips() async throws {
        let db = try makeDB()
        try insertFreshIntegration(db: db)
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        let periodStart: Int64 = 1_700_000_000_000
        let periodEnd: Int64 = 1_700_000_300_000
        await provider.setResult(SlackTickResult(
            huddle: .defaultUnset,
            channelMessageCounts: [
                SlackChannelMessageCount(channelName: "design", count: 7),
                SlackChannelMessageCount(channelName: "engineering", count: 3)
            ],
            cursorMs: periodEnd,
            periodStartMs: periodStart,
            periodEndMs: periodEnd,
            statusEmoji: ":spiral_calendar_pad:",
            statusExpirationTs: 1_700_005_000_000
        ))
        await provider.setPresence(.away)
        await provider.setDND(SlackDNDState(
            dndEnabled: false,
            snoozeUntilMs: nil,
            nextDNDStartMs: 1_700_030_000_000,
            nextDNDEndMs: 1_700_050_000_000
        ))
        await provider.setMentions([
            SlackMentionChannelCount(
                channelName: "design",
                count: 1,
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            )
        ])
        await provider.setFiles(SlackFileUploadSummary(
            count: 0,
            typesSummary: [:],
            periodStartMs: periodStart,
            periodEndMs: periodEnd
        ))

        _ = await collector.performTick()

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .slack, in: rawDB)
        }
        let row = try XCTUnwrap(presence)
        let state = row.state

        // Verify every plan-required key is present + correct value.
        XCTAssertEqual(state["native_presence"] as? String, "away")
        XCTAssertEqual(state["status_emoji"] as? String, ":spiral_calendar_pad:")
        XCTAssertEqual(state["status_expiration_ts"] as? Int64, 1_700_005_000_000)
        XCTAssertEqual(state["in_huddle"] as? Bool, false, ".defaultUnset → in_huddle=false")
        XCTAssertEqual(state["huddle_channel"] as? String, "")
        XCTAssertEqual(state["last_activity_channel"] as? String, "design",
                       "max-count channel — design (7) > engineering (3)")
        XCTAssertEqual(state["mention_count_today"] as? Int, 1)
        XCTAssertEqual(state["file_count_today"] as? Int, 0)

        // dnd nested dict roundtripped:
        let dnd = try XCTUnwrap(state["dnd"] as? [String: Any])
        XCTAssertEqual(dnd.keys.sorted(),
                       ["is_active", "next_dnd_end_ms", "next_dnd_start_ms", "snooze_until_ms"],
                       "ровно 4 keys в nested dnd dict")
        XCTAssertEqual(dnd["is_active"] as? Bool, false)
        XCTAssertEqual(dnd["snooze_until_ms"] as? Int64, 0, "nil → 0 per plan literal")
        XCTAssertEqual(dnd["next_dnd_start_ms"] as? Int64, 1_700_030_000_000)
        XCTAssertEqual(dnd["next_dnd_end_ms"] as? Int64, 1_700_050_000_000)

        // Top-level keys count check (defensive against accidental drift).
        XCTAssertEqual(Set(state.keys), [
            "native_presence", "dnd", "status_emoji", "status_expiration_ts",
            "in_huddle", "huddle_channel", "last_activity_channel",
            "mention_count_today", "file_count_today"
        ])
    }

    /// Skip path: без integration row → presence_state.slack row НЕ записан
    /// (early return до writeEventsOffsetAndPresence).
    func testTickSkipPathDoesNotWritePresenceRow() async throws {
        let db = try makeDB()
        let provider = MockSlackAPIProvider()
        let collector = makeCollector(db: db, provider: provider)

        let result = await collector.performTick()
        XCTAssertTrue(result.skipped)

        let presence = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .slack, in: rawDB)
        }
        XCTAssertNil(presence, "skip path не должен создавать presence_state.slack row")
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
            SlackMessageRecord(ts: "1700000002.000001", threadTs: nil, channelID: "C001", text: "Follow-up message")
        ]
        await provider.setResult(SlackTickResult(
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
        ).filter { $0.payload["event_kind"] == "message_authored_aggregate" }

        XCTAssertEqual(events.count, 1, "должен быть ровно 1 message_authored_aggregate event")
        let event = try XCTUnwrap(events.first)

        // messages_json must be present and decodable.
        let messagesJsonStr = try XCTUnwrap(event.payload["messages_json"],
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
        let parentMsg = SlackMessageRecord(ts: "1700000001.000001", threadTs: "1700000001.000001", channelID: "C001", text: "Parent")
        let replyMsg = SlackMessageRecord(ts: "1700000001.000100", threadTs: "1700000001.000001", channelID: "C001", text: "Reply")
        await provider.setThreadReplyBatch(SlackThreadReplyBatch(parent: parentMsg, replies: [replyMsg], nextCursor: nil))

        await provider.setResult(SlackTickResult(
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
        XCTAssertEqual(calls.count, cap,
                       "fetchThreadReplies должен вызываться не более maxThreadsPerTick раз (\(cap)), но вызван \(calls.count) раз")
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

        await provider.setThreadReplyBatch(SlackThreadReplyBatch(parent: parentMsg, replies: [replyMsg], nextCursor: nil))
        await provider.setResult(SlackTickResult(
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
        XCTAssertEqual(storedOffset?.lastModifiedMs, expectedCursorMs,
                       "Cursor должен соответствовать ms времени последнего reply")

        // Second tick — collector must pass oldest based on stored cursor (ms precision).
        // Slack ts "1700000002.000050" → Int64 ms truncation → "1700000002.000000".
        // This is expected: Int64 ms gives millisecond precision (Slack ts = sec.microsec).
        _ = await collector.performTick()

        let calls = await provider.threadReplyCallHistory()
        XCTAssertGreaterThanOrEqual(calls.count, 2, "второй tick должен вызвать fetchThreadReplies снова")
        let secondCall = calls[1]
        let expectedOldest = String(format: "%.6f", Double(Int64(Double(replyTs)! * 1000)) / 1000.0)
        XCTAssertEqual(secondCall.oldest, expectedOldest,
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
            SlackMessageRecord(ts: ts3, threadTs: ts3, channelID: channelID, text: "Thread 3")
        ]

        let parentMsg = SlackMessageRecord(ts: ts1, threadTs: ts1, channelID: channelID, text: "Parent")
        let replyMsg = SlackMessageRecord(ts: "1700000001.500000", threadTs: ts1, channelID: channelID, text: "Reply")
        await provider.setThreadReplyBatch(SlackThreadReplyBatch(parent: parentMsg, replies: [replyMsg], nextCursor: nil))

        // 3rd thread throws 429.
        await provider.setThreadReplyThrowOn(ts3)

        await provider.setResult(SlackTickResult(
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
        let offset1 = try db.readOffset(collectorID: CollectorID.slackPolling,
                                        sourceID: "slack:thread:\(channelID):\(ts1)")
        let offset2 = try db.readOffset(collectorID: CollectorID.slackPolling,
                                        sourceID: "slack:thread:\(channelID):\(ts2)")
        // Thread 3 should NOT have a cursor (429 broke the loop before it was processed).
        let offset3 = try db.readOffset(collectorID: CollectorID.slackPolling,
                                        sourceID: "slack:thread:\(channelID):\(ts3)")

        XCTAssertNotNil(offset1, "thread 1 должен иметь курсор — успешно обработан")
        XCTAssertNotNil(offset2, "thread 2 должен иметь курсор — успешно обработан")
        XCTAssertNil(offset3, "thread 3 не должен иметь курсор — 429 до обработки")

        // Calls: ts1, ts2, ts3 (throws) → 3 calls total.
        let calls = await provider.threadReplyCallHistory()
        XCTAssertEqual(calls.count, 3, "fetchThreadReplies должен вызываться до 429-го thread'а включительно")
    }
}
