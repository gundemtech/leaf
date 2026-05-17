//
//  SlackWarmCollectorTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — SlackWarmCollector lifecycle tests:
//    - Integration / bootstrap discipline
//    - Empty batch / per-endpoint scope gating
//    - C3 regression fences (full member set persistence + rank churn)
//    - Cursor advance/no-advance on success/failure
//
//  Per-endpoint diff emission tests (channels / reactions / pins / bookmarks /
//  reminders / scheduled / stars) live in SlackWarmCollectorEventEmissionTests.swift.
//  Shared SpyProvider + fixture helpers live in SlackWarmCollectorTestHelpers.swift.
//

import XCTest

@testable import LeafCore

final class SlackWarmCollectorTests: XCTestCase {
    private typealias Support = SlackWarmCollectorTestSupport

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-warm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Integration / bootstrap

    func testSkipWhenNoIntegration() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let p = Support.SpyProvider()
        let c = Support.makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertTrue(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testBootstrapTickEmitsNoEventsAndWritesAllSnapshots() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let p = Support.SpyProvider()
        // Provider returns a non-empty batch — bootstrap should still suppress emits.
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: SlackMemberChannelsTopList(channels: [
                    SlackMemberChannel(id: "C1", name: "general", latestTs: 100)
                ]),
                reactions: .empty,
                pinsPerChannel: [SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:1"])],
                bookmarksPerChannel: [
                    SlackChannelBookmarksSnapshot(
                        channelID: "C1",
                        bookmarks: [
                            SlackBookmark(
                                channelID: "C1", id: "bm1", title: "Docs", link: "https://example.com", lastEditedMs: 5)
                        ])
                ],
                reminders: SlackRemindersSnapshot(reminders: [
                    SlackReminder(id: "R1", dueTs: 200, completedTs: nil)
                ]),
                scheduledMessages: SlackScheduledMessagesSnapshot(messages: [
                    SlackScheduledMessage(id: "SM1", channelID: "C1", scheduledFor: 300, sent: false)
                ]),
                stars: SlackStarsSnapshot(stars: [
                    SlackStarItem(itemRef: "C1:1", savedAtMs: 50)
                ])
            ))

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0, "Bootstrap discipline: first tick writes snapshots, emits zero events")

        // All six warm snapshots written (C3 fix consolidated the redundant
        // `slackUserConversations` mirror into the single `slackMemberChannels`
        // full-set snapshot — cold reads the same row warm writes).
        try db.readSQL { raw in
            for kind in [
                Schema.ProviderSnapshotKinds.slackMemberChannels,
                Schema.ProviderSnapshotKinds.slackPinsPerChannel,
                Schema.ProviderSnapshotKinds.slackBookmarksPerChannel,
                Schema.ProviderSnapshotKinds.slackReminders,
                Schema.ProviderSnapshotKinds.slackScheduledMessages,
                Schema.ProviderSnapshotKinds.slackStars,
            ] {
                XCTAssertNotNil(
                    try ProviderSnapshotsStore.read(provider: "slack", snapshotKind: kind, in: raw),
                    "snapshot \(kind) must be written on bootstrap"
                )
            }
        }
    }

    // MARK: - Empty batch + scope gating

    func testEmptyBatchEmitsNoEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let p = Support.SpyProvider()  // returns .empty by default
        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testScopeMissingSkipsEndpointGracefully() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        // Seed prior pins snapshot — would normally emit slack_pin_added if pin
        // is observed. With scope missing collector must NOT emit pin events.
        let priorJSON = #"[{"channelID":"C1","pinItemRefs":[]}]"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:1"])],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = Support.makeCollector(db, p, scopes: Support.ScopesMissing(["pins:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0, "pins:read missing → no pin events emitted")
        XCTAssertFalse(r.skipped)
    }

    // MARK: - C3 regression fences

    func testFullMemberSetPersistedNoCap_C3Regression() async throws {
        // C3 review fix (D3 follow-up): persisting a top-N cap of the member
        // channel list caused false-positive `slack_channel_joined/_left`
        // events whenever the user's #11 channel bubbled into the top-10 by
        // activity. The snapshot must hold the FULL member set; top-N capping
        // is the provider's responsibility at fan-out time.
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        // Provider returns 20 member channels.
        var channels: [SlackMemberChannel] = []
        for i in 1...20 {
            channels.append(SlackMemberChannel(id: "C\(i)", name: "ch-\(i)", latestTs: Int64(1000 - i)))
        }
        let p = Support.SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: SlackMemberChannelsTopList(channels: channels),
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = Support.makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))

        try db.readSQL { raw in
            let snap = try ProviderSnapshotsStore.read(
                provider: "slack",
                snapshotKind: Schema.ProviderSnapshotKinds.slackMemberChannels,
                in: raw
            )
            XCTAssertNotNil(snap)
            // swiftlint:disable:next force_unwrapping
            let occurrences = snap!.snapshotJSON.components(separatedBy: "\"id\":").count - 1
            XCTAssertEqual(occurrences, 20, "Full member set must persist — no cap at snapshot layer")
        }
    }

    func testRankChurnDoesNotEmitFalseJoinLeft_C3Regression() async throws {
        // C3 review fix: when user has >10 active channels, the prior snapshot
        // captured the full membership. Even if recency-ranking churn moves
        // channel #11 into top-10 on the next tick (and #1 drops to #11),
        // the FULL-set diff must emit zero events because membership itself
        // is unchanged.
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        // Seed prior FULL set of 15 channels (all members, varied latestTs).
        var priorChannels = ""
        for i in 1...15 {
            if i > 1 { priorChannels += "," }
            priorChannels += #"{"id":"C\#(i)","name":"ch\#(i)","latestTs":\#(i * 100)}"#
        }
        let priorJSON = #"{"channels":[\#(priorChannels)]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: priorJSON)

        // Current batch — same 15 channels, every channel's latestTs flipped
        // (C1 now most recent, C15 least). Massive rank churn, zero membership
        // change.
        var currChannels: [SlackMemberChannel] = []
        for i in 1...15 {
            currChannels.append(SlackMemberChannel(id: "C\(i)", name: "ch\(i)", latestTs: Int64((16 - i) * 100)))
        }
        let p = Support.SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: SlackMemberChannelsTopList(channels: currChannels),
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0, "rank churn over identical membership must emit zero join/left events")
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackChannelJoined.rawValue), 0)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackChannelLeft.rawValue), 0)
    }

    // MARK: - Cursor lifecycle

    func testCursorAdvancedToTickNowOnSuccess() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        let p = Support.SpyProvider()
        let c = Support.makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))
        let off = try db.readOffset(
            collectorID: CollectorID.slackWarmPolling,
            sourceID: "slack:warm:T1:U1"
        )
        XCTAssertNotNil(off)
        XCTAssertEqual(off?.lastModifiedMs, 100_000)
    }

    func testProviderFailureDoesNotAdvanceCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        let p = Support.SpyProvider()
        await p.setShouldThrow(true)
        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
        // No offset row written → cursor not advanced.
        let off = try db.readOffset(
            collectorID: CollectorID.slackWarmPolling,
            sourceID: "slack:warm:T1:U1"
        )
        XCTAssertNil(off)
    }
}
