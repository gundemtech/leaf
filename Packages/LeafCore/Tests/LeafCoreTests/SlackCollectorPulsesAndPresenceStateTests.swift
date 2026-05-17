// Phase 4.7.B-10..13 + Track-1 D1 — SlackCollector pulses (DND, mention, file),
// presence_state writer, lifecycle, and Track-1 D1 thread reply tests. Split from
// SlackCollectorTests.swift for type_body_length.

import XCTest
import os

@testable import LeafCore

final class SlackCollectorPulsesAndPresenceStateTests: XCTestCase {
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

    private func huddleEventInDB(state: String, atMs: Int64) -> RawEvent {
        Support.huddleEventInDB(state: state, atMs: atMs)
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
        await provider.setDND(
            SlackDNDState(
                dndEnabled: true,
                snoozeUntilMs: 1_700_001_000_000,
                nextDNDStartMs: nil,
                nextDNDEndMs: nil
            ))
        await provider.setResult(
            SlackTickResult(
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
        await provider.setDND(
            SlackDNDState(
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
        let stored = try db.events(
            in: DateInterval(
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
        let activeEv = try XCTUnwrap(
            dndEvents.first {
                $0.payload["observed_at_ms"] == String(Int64(now1.timeIntervalSince1970 * 1000))
            })
        XCTAssertEqual(activeEv.payload["dnd_enabled"], "true")
        XCTAssertEqual(activeEv.payload["snooze_until_ms"], "1700001000000")
        XCTAssertNil(activeEv.payload["next_dnd_start_ms"], "nil ts → omitted from payload")
        XCTAssertNil(activeEv.payload["next_dnd_end_ms"])

        // Tick 2 — dnd_enabled=false + scheduled window; snooze_until ОМИТНУТ.
        let scheduledEv = try XCTUnwrap(
            dndEvents.first {
                $0.payload["observed_at_ms"] == String(Int64(now2.timeIntervalSince1970 * 1000))
            })
        XCTAssertEqual(scheduledEv.payload["dnd_enabled"], "false")
        XCTAssertNil(scheduledEv.payload["snooze_until_ms"])
        XCTAssertEqual(scheduledEv.payload["next_dnd_start_ms"], "1700010000000")
        XCTAssertEqual(scheduledEv.payload["next_dnd_end_ms"], "1700020000000")

        // Tick 3 — graceful empty: dnd_enabled=false, все ts nil.
        let emptyEv = try XCTUnwrap(
            dndEvents.first {
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
            ),
        ])
        await provider.setResult(
            SlackTickResult(
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

        let stored = try db.events(
            in: DateInterval(
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
        await provider.setFiles(
            SlackFileUploadSummary(
                count: 5,
                typesSummary: ["image": 2, "code": 1, "doc": 1, "other": 1],
                periodStartMs: periodStart,
                periodEndMs: periodEnd
            ))
        await provider.setResult(
            SlackTickResult(
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
        let stored = try db.events(
            in: DateInterval(
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
        let stored2 = try db.events(
            in: DateInterval(
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
        await provider.setResult(
            SlackTickResult(
                huddle: .inAHuddle,
                channelMessageCounts: [
                    SlackChannelMessageCount(channelName: "engineering", count: 5),
                    SlackChannelMessageCount(channelName: "DM", count: 2),
                ],
                cursorMs: periodEnd,
                periodStartMs: periodStart,
                periodEndMs: periodEnd,
                statusEmoji: ":coffee:",
                statusExpirationTs: 1_700_010_000_000
            ))
        await provider.setPresence(.active)
        await provider.setDND(
            SlackDNDState(
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
            ),
        ])
        await provider.setFiles(
            SlackFileUploadSummary(
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
        XCTAssertEqual(
            state["last_activity_channel"] as? String, "engineering",
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
        await provider.setResult(
            SlackTickResult(
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
        XCTAssertFalse(
            topLevelKeys.contains("text"),
            "presence_state.slack не должен содержать 'text' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("preview"),
            "presence_state.slack не должен содержать 'preview' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("title"),
            "presence_state.slack не должен содержать 'title' top-level key")
        XCTAssertFalse(
            topLevelKeys.contains("body"),
            "presence_state.slack не должен содержать 'body' top-level key")

        // Paranoid: serialized JSON не должен иметь body markers.
        let serialized = try JSONSerialization.data(withJSONObject: row.state, options: [])
        let serializedStr = String(data: serialized, encoding: .utf8) ?? ""
        for forbidden in ["\"text\"", "\"preview\"", "\"title\"", "\"body\""] {
            XCTAssertFalse(
                serializedStr.contains(forbidden),
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
        await provider.setResult(
            SlackTickResult(
                huddle: .defaultUnset,
                channelMessageCounts: [
                    SlackChannelMessageCount(channelName: "design", count: 7),
                    SlackChannelMessageCount(channelName: "engineering", count: 3),
                ],
                cursorMs: periodEnd,
                periodStartMs: periodStart,
                periodEndMs: periodEnd,
                statusEmoji: ":spiral_calendar_pad:",
                statusExpirationTs: 1_700_005_000_000
            ))
        await provider.setPresence(.away)
        await provider.setDND(
            SlackDNDState(
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
        await provider.setFiles(
            SlackFileUploadSummary(
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
        XCTAssertEqual(
            state["last_activity_channel"] as? String, "design",
            "max-count channel — design (7) > engineering (3)")
        XCTAssertEqual(state["mention_count_today"] as? Int, 1)
        XCTAssertEqual(state["file_count_today"] as? Int, 0)

        // dnd nested dict roundtripped:
        let dnd = try XCTUnwrap(state["dnd"] as? [String: Any])
        XCTAssertEqual(
            dnd.keys.sorted(),
            ["is_active", "next_dnd_end_ms", "next_dnd_start_ms", "snooze_until_ms"],
            "ровно 4 keys в nested dnd dict")
        XCTAssertEqual(dnd["is_active"] as? Bool, false)
        XCTAssertEqual(dnd["snooze_until_ms"] as? Int64, 0, "nil → 0 per plan literal")
        XCTAssertEqual(dnd["next_dnd_start_ms"] as? Int64, 1_700_030_000_000)
        XCTAssertEqual(dnd["next_dnd_end_ms"] as? Int64, 1_700_050_000_000)

        // Top-level keys count check (defensive against accidental drift).
        XCTAssertEqual(
            Set(state.keys),
            [
                "native_presence", "dnd", "status_emoji", "status_expiration_ts",
                "in_huddle", "huddle_channel", "last_activity_channel",
                "mention_count_today", "file_count_today",
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
}
