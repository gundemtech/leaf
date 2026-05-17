//
//  SlackWarmCollectorTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — Task 12. Integration-flavored tests for the
//  SlackWarmCollector.performTick(now:) flow. Mirrors the GitHubWarmCollector
//  test pattern: spy provider + temp SQLCipher DB + bootstrap discipline +
//  scope gating + per-endpoint diff coverage.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

final class SlackWarmCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-warm")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-warm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fakes

    private struct AlwaysGrantedScopes: SlackScopesChecking {
        func has(_ scope: String) async -> Bool { true }
    }

    private struct ScopesMissing: SlackScopesChecking {
        let missing: Set<String>
        init(_ missing: Set<String>) { self.missing = missing }
        func has(_ scope: String) async -> Bool { !missing.contains(scope) }
    }

    /// Spy SlackAPIProvider — only `fetchWarmState` is exercised by the warm
    /// collector; the other protocol methods are stubbed with `.empty`-like
    /// returns. `nextBatch` is the warm batch the next tick will see; the
    /// spy also records the inbound prior-snapshot arguments so tests can
    /// assert top-10 capping behaviour.
    private actor SpyProvider: SlackAPIProvider {
        var nextBatch: SlackWarmBatch = .empty
        var fetchWarmStateCallCount = 0
        var lastSeenPriorMemberChannels: SlackMemberChannelsTopList?
        var lastSeenPriorPins: [SlackChannelPinsSnapshot] = []
        var lastSeenSince: Int64?
        var shouldThrow: Bool = false

        func setBatch(_ b: SlackWarmBatch) { nextBatch = b }
        func setShouldThrow(_ v: Bool) { shouldThrow = v }

        struct StubError: Error {}

        // Hot-tier no-ops.
        func fetchTick(accessToken: String, userID: String, since: Int64?, now: Date) async throws -> SlackTickResult {
            .empty
        }
        func fetchPresence(accessToken: String, userID: String) async throws -> SlackPresenceState { .unknown }
        func fetchDND(accessToken: String, userID: String) async throws -> SlackDNDState { .empty }
        func fetchMentionsReceived(
            accessToken: String, userID: String, since: Int64
        ) async throws -> [SlackMentionChannelCount] { [] }
        func fetchFilesUploaded(
            accessToken: String, userID: String, since: Int64
        ) async throws -> SlackFileUploadSummary { .empty(periodStartMs: 0, periodEndMs: 0) }
        func fetchThreadReplies(
            accessToken: String, channelID: String, threadTs: String, ownerUserID: String, oldest: String?
        ) async throws -> SlackThreadReplyBatch { .empty }

        // Warm.
        func fetchWarmState(
            accessToken: String,
            userID: String,
            scopes: SlackScopesChecking,
            priorMemberChannels: SlackMemberChannelsTopList?,
            priorPinsPerChannel: [SlackChannelPinsSnapshot],
            priorBookmarksPerChannel: [SlackChannelBookmarksSnapshot],
            priorReminders: SlackRemindersSnapshot,
            priorScheduledMessages: SlackScheduledMessagesSnapshot,
            priorStars: SlackStarsSnapshot,
            since: Int64?,
            now: Int64
        ) async throws -> SlackWarmBatch {
            fetchWarmStateCallCount += 1
            lastSeenPriorMemberChannels = priorMemberChannels
            lastSeenPriorPins = priorPinsPerChannel
            lastSeenSince = since
            if shouldThrow { throw StubError() }
            return nextBatch
        }

        // Cold — no-op.
        func fetchColdState(
            accessToken: String, userID: String, scopes: SlackScopesChecking, topChannels: SlackMemberChannelsTopList,
            now: Int64
        ) async throws -> SlackColdBatch { .empty }
    }

    // MARK: - Helpers

    private func insertSlackIntegration(_ db: Database, teamID: String = "T1", userID: String = "U1") throws {
        try db.upsertIntegration(
            IntegrationRecord(
                provider: .slack,
                workspaceID: "\(teamID):\(userID)",
                workspaceName: "Acme",
                accessToken: "tok",
                refreshToken: nil,
                expiresAt: nil,  // long-lived (no rotation) — refresher no-ops
                scope: "channels:read,pins:read,bookmarks:read,reminders:read,reactions:read,stars:read",
                connectedAt: Date(),
                updatedAt: Date()
            ))
    }

    private func makeCollector(
        _ db: Database,
        _ provider: SpyProvider,
        scopes: any SlackScopesChecking = AlwaysGrantedScopes(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) }
    ) -> SlackWarmCollector {
        SlackWarmCollector(
            database: db,
            provider: provider,
            tokenRefresher: SlackTokenRefresher(database: db, clientID: "cid"),
            scopes: scopes,
            workspaceIDProvider: { "T1" },
            userIDProvider: { "U1" },
            clock: clock,
            logger: logger
        )
    }

    private func seedPriorSnapshot(_ db: Database, kind: String, json: String) throws {
        try db.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(
                ProviderSnapshot(
                    provider: "slack",
                    snapshotKind: kind,
                    snapshotJSON: json,
                    capturedAtMs: 0
                ), in: raw)
        }
    }

    private func eventCount(_ db: Database, eventKind: String) throws -> Int {
        var count = 0
        try db.readSQL { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: """
                    SELECT payload_json FROM events
                    WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [eventKind])
            count = rows.count
        }
        return count
    }

    // MARK: - Tests

    func testSkipWhenNoIntegration() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let p = SpyProvider()
        let c = makeCollector(db, p)
        let r = await c.performTick()
        XCTAssertTrue(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testBootstrapTickEmitsNoEventsAndWritesAllSnapshots() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let p = SpyProvider()
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

        let c = makeCollector(db, p)
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

    func testJoinedChannelEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        // Seed prior member-channels snapshot with one channel.
        let priorJSON = #"{"channels":[{"id":"C1","name":"general","latestTs":100}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: SlackMemberChannelsTopList(channels: [
                    SlackMemberChannel(id: "C1", name: "general", latestTs: 100),
                    SlackMemberChannel(id: "C2", name: "random", latestTs: 200),
                ]),
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackChannelJoined.rawValue), 1)
    }

    func testLeftChannelEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON =
            #"{"channels":[{"id":"C1","name":"general","latestTs":100},{"id":"C2","name":"random","latestTs":200}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: SlackMemberChannelsTopList(channels: [
                    SlackMemberChannel(id: "C1", name: "general", latestTs: 100)
                ]),
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackChannelLeft.rawValue), 1)
    }

    func testReactionAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        // For reactions, the provider determines new vs old (since cursor). Spy returns
        // a single reaction → collector emits one reaction_added event.
        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: SlackReactionsBatch(reactions: [
                    SlackReaction(itemRef: "C1:1.0", emoji: "thumbsup", addedAtMs: 50)
                ]),
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackReactionAdded.rawValue), 1)
    }

    func testPinAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        // Seed prior pins snapshot — channel C1 has zero pins. Then current has one pin.
        let priorJSON = #"[{"channelID":"C1","pinItemRefs":[]}]"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:1.0"])],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackPinAdded.rawValue), 1)
    }

    func testPinRemovedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"[{"channelID":"C1","pinItemRefs":["C1:1.0"]}]"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: [])],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackPinRemoved.rawValue), 1)
    }

    func testBookmarkAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"[{"channelID":"C1","bookmarks":[]}]"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [
                    SlackChannelBookmarksSnapshot(
                        channelID: "C1",
                        bookmarks: [
                            SlackBookmark(
                                channelID: "C1", id: "bm1", title: "Runbook", link: "https://x", lastEditedMs: 50)
                        ])
                ],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackBookmarkAdded.rawValue), 1)
    }

    func testBookmarkRemovedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"""
            [{"channelID":"C1","bookmarks":[{"channelID":"C1","id":"bm1","title":"Old","link":"https://x","lastEditedMs":1}]}]
            """#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [SlackChannelBookmarksSnapshot(channelID: "C1", bookmarks: [])],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackBookmarkRemoved.rawValue), 1)
    }

    func testReminderCreatedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"{"reminders":[{"id":"R0","dueTs":50,"completedTs":null}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackReminders, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: SlackRemindersSnapshot(reminders: [
                    SlackReminder(id: "R0", dueTs: 50, completedTs: nil),
                    SlackReminder(id: "R1", dueTs: 200, completedTs: nil),
                ]),
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackReminderCreated.rawValue), 1)
    }

    func testReminderCompletedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"{"reminders":[{"id":"R1","dueTs":50,"completedTs":null}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackReminders, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: SlackRemindersSnapshot(reminders: [
                    SlackReminder(id: "R1", dueTs: 50, completedTs: 90)
                ]),
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackReminderCompleted.rawValue), 1)
    }

    func testScheduledMessageEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"{"messages":[{"id":"SM0","channelID":"C1","scheduledFor":50,"sent":false}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackScheduledMessages, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: SlackScheduledMessagesSnapshot(messages: [
                    SlackScheduledMessage(id: "SM0", channelID: "C1", scheduledFor: 50, sent: false),
                    SlackScheduledMessage(id: "SM1", channelID: "C1", scheduledFor: 200, sent: false),
                ]),
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackMessageScheduled.rawValue), 1)
    }

    func testScheduledMessageSentEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"{"messages":[{"id":"SM0","channelID":"C1","scheduledFor":50,"sent":false}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackScheduledMessages, json: priorJSON)

        let p = SpyProvider()
        // Two transitions to "sent": SM0 disappears from current (treated as sent);
        // SM1 transitions false→true. Expected = 2 events.
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,  // SM0 disappeared from scheduler list
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackMessageSentScheduled.rawValue), 1)
    }

    func testItemSavedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"{"stars":[{"itemRef":"C1:1.0","savedAtMs":10}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackStars, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: SlackStarsSnapshot(stars: [
                    SlackStarItem(itemRef: "C1:1.0", savedAtMs: 10),
                    SlackStarItem(itemRef: "C1:2.0", savedAtMs: 50),
                ])
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackItemSaved.rawValue), 1)
    }

    func testItemUnsavedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let priorJSON = #"{"stars":[{"itemRef":"C1:1.0","savedAtMs":10}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackStars, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackWarmBatch(
                memberChannelsTopList: .empty,
                reactions: .empty,
                pinsPerChannel: [],
                bookmarksPerChannel: [],
                reminders: .empty,
                scheduledMessages: .empty,
                stars: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackItemUnsaved.rawValue), 1)
    }

    func testEmptyBatchEmitsNoEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        let p = SpyProvider()  // returns .empty by default
        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testScopeMissingSkipsEndpointGracefully() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        // Seed prior pins snapshot — would normally emit slack_pin_added if pin
        // is observed. With scope missing collector must NOT emit pin events.
        let priorJSON = #"[{"channelID":"C1","pinItemRefs":[]}]"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel, json: priorJSON)

        let p = SpyProvider()
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

        let c = makeCollector(db, p, scopes: ScopesMissing(["pins:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0, "pins:read missing → no pin events emitted")
        XCTAssertFalse(r.skipped)
    }

    func testFullMemberSetPersistedNoCap_C3Regression() async throws {
        // C3 review fix (D3 follow-up): persisting a top-N cap of the member
        // channel list caused false-positive `slack_channel_joined/_left`
        // events whenever the user's #11 channel bubbled into the top-10 by
        // activity. The snapshot must hold the FULL member set; top-N capping
        // is the provider's responsibility at fan-out time.
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)

        // Provider returns 20 member channels.
        var channels: [SlackMemberChannel] = []
        for i in 1...20 {
            channels.append(SlackMemberChannel(id: "C\(i)", name: "ch-\(i)", latestTs: Int64(1000 - i)))
        }
        let p = SpyProvider()
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

        let c = makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))

        try db.readSQL { raw in
            let snap = try ProviderSnapshotsStore.read(
                provider: "slack",
                snapshotKind: Schema.ProviderSnapshotKinds.slackMemberChannels,
                in: raw
            )
            XCTAssertNotNil(snap)
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
        try insertSlackIntegration(db)

        // Seed prior FULL set of 15 channels (all members, varied latestTs).
        var priorChannels = ""
        for i in 1...15 {
            if i > 1 { priorChannels += "," }
            priorChannels += #"{"id":"C\#(i)","name":"ch\#(i)","latestTs":\#(i * 100)}"#
        }
        let priorJSON = #"{"channels":[\#(priorChannels)]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: priorJSON)

        // Current batch — same 15 channels, every channel's latestTs flipped
        // (C1 now most recent, C15 least). Massive rank churn, zero membership
        // change.
        var currChannels: [SlackMemberChannel] = []
        for i in 1...15 {
            currChannels.append(SlackMemberChannel(id: "C\(i)", name: "ch\(i)", latestTs: Int64((16 - i) * 100)))
        }
        let p = SpyProvider()
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

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0, "rank churn over identical membership must emit zero join/left events")
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackChannelJoined.rawValue), 0)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackChannelLeft.rawValue), 0)
    }

    func testCursorAdvancedToTickNowOnSuccess() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        let p = SpyProvider()
        let c = makeCollector(db, p)
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
        try insertSlackIntegration(db)
        let p = SpyProvider()
        await p.setShouldThrow(true)
        let c = makeCollector(db, p)
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
// swiftlint:enable force_unwrapping
