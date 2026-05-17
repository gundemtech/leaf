//
//  SlackColdCollectorTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — Task 14. Integration-flavored tests for the
//  SlackColdCollector.performTick(now:) flow. Mirrors the GitHubColdCollector
//  test pattern: spy provider + temp SQLCipher DB + bootstrap discipline +
//  scope gating + per-endpoint diff coverage.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

final class SlackColdCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private let logger = Logger(subsystem: "tech.gundem.leaf.tests", category: "slack-cold")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-cold-\(UUID().uuidString)", isDirectory: true)
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

    /// Spy SlackAPIProvider — only `fetchColdState` is exercised. Other
    /// protocol methods are stubbed.
    private actor SpyProvider: SlackAPIProvider {
        var nextBatch: SlackColdBatch = .empty
        var fetchColdStateCallCount = 0
        var lastSeenTopChannels: SlackMemberChannelsTopList?
        var shouldThrow: Bool = false

        func setBatch(_ b: SlackColdBatch) { nextBatch = b }
        func setShouldThrow(_ v: Bool) { shouldThrow = v }

        struct StubError: Error {}

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
            .empty
        }

        func fetchColdState(
            accessToken: String,
            userID: String,
            scopes: SlackScopesChecking,
            topChannels: SlackMemberChannelsTopList,
            now: Int64
        ) async throws -> SlackColdBatch {
            fetchColdStateCallCount += 1
            lastSeenTopChannels = topChannels
            if shouldThrow { throw StubError() }
            return nextBatch
        }
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
                expiresAt: nil,
                scope: "canvases:read,emoji:read,usergroups:read,channels:read",
                connectedAt: Date(),
                updatedAt: Date()
            ))
    }

    private func makeCollector(
        _ db: Database,
        _ provider: SpyProvider,
        scopes: any SlackScopesChecking = AlwaysGrantedScopes(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) }
    ) -> SlackColdCollector {
        SlackColdCollector(
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

    private func eventPayload(_ db: Database, eventKind: String) throws -> [String: Any]? {
        var payload: [String: Any]?
        try db.readSQL { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: """
                    SELECT payload_json FROM events
                    WHERE json_extract(payload_json, '$.event_kind') = ?
                    """, arguments: [eventKind])
            guard let row = rows.first, let json: String = row["payload_json"] else { return }
            let data = Data(json.utf8)
            payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return payload
    }

    private func seedTopChannels(_ db: Database, _ channels: [SlackMemberChannel]) throws {
        let list = SlackMemberChannelsTopList(channels: channels)
        let data = try JSONEncoder().encode(list)
        let json = String(data: data, encoding: .utf8)!
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: json)
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
        try seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: SlackCanvasesSnapshot(canvases: [
                    SlackCanvas(channelID: "C1", canvasID: "K1", title: "Onboarding", lastEditedMs: 50)
                ]),
                emoji: SlackEmojiSnapshot(emojiNames: ["party", "tada"]),
                usergroups: SlackUsergroupsSnapshot(groups: [
                    SlackUsergroup(id: "G1", name: "team", userIDs: ["U1", "U2"])
                ]),
                channelsInfo: SlackChannelsInfoSnapshot(channels: [
                    SlackChannelInfo(channelID: "C1", name: "general", isArchived: false)
                ])
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(r.skipped)
        XCTAssertEqual(r.eventsEmitted, 0, "Bootstrap: first tick writes snapshots, emits zero events")

        try db.readSQL { raw in
            for kind in [
                Schema.ProviderSnapshotKinds.slackCanvasesPerChannel,
                Schema.ProviderSnapshotKinds.slackEmojiList,
                Schema.ProviderSnapshotKinds.slackUsergroups,
                Schema.ProviderSnapshotKinds.slackChannelsInfo,
            ] {
                XCTAssertNotNil(
                    try ProviderSnapshotsStore.read(provider: "slack", snapshotKind: kind, in: raw),
                    "snapshot \(kind) must be written on bootstrap"
                )
            }
        }
    }

    func testCanvasCreatedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        // Seed prior canvases — empty for the channel but non-empty overall so
        // bootstrap discipline does not suppress.
        let priorJSON = #"{"canvases":[{"channelID":"C1","canvasID":"K0","title":"Old","lastEditedMs":1}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: SlackCanvasesSnapshot(canvases: [
                    SlackCanvas(channelID: "C1", canvasID: "K0", title: "Old", lastEditedMs: 1),
                    SlackCanvas(channelID: "C1", canvasID: "K1", title: "Onboarding", lastEditedMs: 50),
                ]),
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackCanvasCreated.rawValue), 1)

        let payload = try eventPayload(db, eventKind: SlackEventKindKey.slackCanvasCreated.rawValue)
        XCTAssertEqual(payload?["canvas_id"] as? String, "K1")
        XCTAssertEqual(payload?["body"] as? String, "Onboarding", "title routed via body for FTS dispatch")
    }

    func testCanvasEditedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        let priorJSON = #"{"canvases":[{"channelID":"C1","canvasID":"K1","title":"Old","lastEditedMs":10}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: SlackCanvasesSnapshot(canvases: [
                    SlackCanvas(channelID: "C1", canvasID: "K1", title: "New", lastEditedMs: 50)
                ]),
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackCanvasEdited.rawValue), 1)
    }

    func testCustomEmojiAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let priorJSON = #"{"emojiNames":["party"]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackEmojiList, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: SlackEmojiSnapshot(emojiNames: ["party", "tada"]),
                usergroups: .empty,
                channelsInfo: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackCustomEmojiAdded.rawValue), 1)

        let payload = try eventPayload(db, eventKind: SlackEventKindKey.slackCustomEmojiAdded.rawValue)
        XCTAssertEqual(payload?["emoji_name"] as? String, "tada")
    }

    func testUsergroupMembershipDeltaEmitsPerGroup() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        // Prior: G1 has [U1]; current: G1 has [U1, U2]; expect one event with added=[U2], removed=[]
        let priorJSON = #"{"groups":[{"id":"G1","name":"team","userIDs":["U1"]}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackUsergroups, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: SlackUsergroupsSnapshot(groups: [
                    SlackUsergroup(id: "G1", name: "team", userIDs: ["U1", "U2"])
                ]),
                channelsInfo: .empty
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackUsergroupMembershipChanged.rawValue), 1)

        let payload = try eventPayload(db, eventKind: SlackEventKindKey.slackUsergroupMembershipChanged.rawValue)
        XCTAssertEqual(payload?["group_id"] as? String, "G1")
        let addedJSON = payload?["added_user_ids_json"] as? String ?? ""
        let added = try? JSONDecoder().decode([String].self, from: Data(addedJSON.utf8))
        XCTAssertEqual(added, ["U2"])
    }

    func testChannelRenamedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let priorJSON = #"{"channels":[{"channelID":"C1","name":"old","isArchived":false}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackChannelsInfo, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: SlackChannelsInfoSnapshot(channels: [
                    SlackChannelInfo(channelID: "C1", name: "new", isArchived: false)
                ])
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackChannelRenamed.rawValue), 1)

        let payload = try eventPayload(db, eventKind: SlackEventKindKey.slackChannelRenamed.rawValue)
        XCTAssertEqual(payload?["old_name"] as? String, "old")
        XCTAssertEqual(payload?["new_name"] as? String, "new")
    }

    func testChannelArchivedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let priorJSON = #"{"channels":[{"channelID":"C1","name":"general","isArchived":false}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackChannelsInfo, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: SlackChannelsInfoSnapshot(channels: [
                    SlackChannelInfo(channelID: "C1", name: "general", isArchived: true)
                ])
            ))

        let c = makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackChannelArchived.rawValue), 1)
    }

    func testCanvasScopeMissingSkipsCanvasEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        let priorJSON = #"{"canvases":[{"channelID":"C1","canvasID":"K0","title":"Old","lastEditedMs":1}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: SlackCanvasesSnapshot(canvases: [
                    SlackCanvas(channelID: "C1", canvasID: "K0", title: "Old", lastEditedMs: 1),
                    SlackCanvas(channelID: "C1", canvasID: "K1", title: "New", lastEditedMs: 50),
                ]),
                emoji: .empty, usergroups: .empty, channelsInfo: .empty
            ))

        let c = makeCollector(db, p, scopes: ScopesMissing(["canvases:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
        XCTAssertEqual(try eventCount(db, eventKind: SlackEventKindKey.slackCanvasCreated.rawValue), 0)
    }

    func testEmojiScopeMissingSkipsEmojiEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let priorJSON = #"{"emojiNames":["party"]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackEmojiList, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: SlackEmojiSnapshot(emojiNames: ["party", "tada"]),
                usergroups: .empty, channelsInfo: .empty
            ))

        let c = makeCollector(db, p, scopes: ScopesMissing(["emoji:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testUsergroupsScopeMissingSkipsUsergroupEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let priorJSON = #"{"groups":[{"id":"G1","name":"team","userIDs":["U1"]}]}"#
        try seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackUsergroups, json: priorJSON)

        let p = SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: SlackUsergroupsSnapshot(groups: [
                    SlackUsergroup(id: "G1", name: "team", userIDs: ["U1", "U2"])
                ]),
                channelsInfo: .empty
            ))

        let c = makeCollector(db, p, scopes: ScopesMissing(["usergroups:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testCursorAdvancesOnSuccess() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let p = SpyProvider()
        let now = Date(timeIntervalSince1970: 12_345)
        let c = makeCollector(db, p, clock: { now })
        _ = await c.performTick(now: now)

        let offset = try db.readOffset(
            collectorID: CollectorID.slackColdPolling,
            sourceID: "slack:cold:T1"
        )
        XCTAssertNotNil(offset)
        XCTAssertEqual(offset?.lastModifiedMs, Int64(now.timeIntervalSince1970 * 1000))
    }

    func testFailureDoesNotAdvanceCursor() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(db, [])

        let p = SpyProvider()
        await p.setShouldThrow(true)
        let c = makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))

        let offset = try db.readOffset(
            collectorID: CollectorID.slackColdPolling,
            sourceID: "slack:cold:T1"
        )
        XCTAssertNil(offset, "Provider failure must NOT advance cursor")
    }

    func testProviderReceivesPriorTopChannels() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSlackIntegration(db)
        try seedTopChannels(
            db,
            [
                SlackMemberChannel(id: "C1", name: "general", latestTs: 100),
                SlackMemberChannel(id: "C2", name: "random", latestTs: 200),
            ])

        let p = SpyProvider()
        let c = makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))

        let received = await p.lastSeenTopChannels
        XCTAssertEqual(received?.channels.count, 2)
        XCTAssertEqual(Set(received?.channels.map(\.id) ?? []), ["C1", "C2"])
    }

    func testCanvasTitleRoutesToFTSBodyKindSlackCanvasTitle() async throws {
        // Verifies the dispatch entry added in Task 14: canvas event_kinds map
        // to body_kind = "slack_canvas_title" via EventsFullTextStore.
        XCTAssertEqual(
            EventsFullTextStore.bodyKindForTesting(eventKind: SlackEventKindKey.slackCanvasCreated.rawValue),
            Schema.BodyKinds.slackCanvasTitle
        )
        XCTAssertEqual(
            EventsFullTextStore.bodyKindForTesting(eventKind: SlackEventKindKey.slackCanvasEdited.rawValue),
            Schema.BodyKinds.slackCanvasTitle
        )
    }
}
