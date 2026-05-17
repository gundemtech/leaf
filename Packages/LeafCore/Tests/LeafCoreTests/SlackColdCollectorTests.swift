//
//  SlackColdCollectorTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — SlackColdCollector lifecycle tests:
//    - Integration / bootstrap skip discipline
//    - Per-endpoint scope gating
//    - Cursor advance/no-advance on success/failure
//    - Provider hand-off of prior top channels
//    - FTS body-kind dispatch fence for canvas titles
//
//  Per-endpoint diff emission tests live in SlackColdCollectorEventEmissionTests.swift.
//  Shared SpyProvider + fixture helpers live in SlackColdCollectorTestHelpers.swift.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

final class SlackColdCollectorTests: XCTestCase {
    private typealias Support = SlackColdCollectorTestSupport

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-cold-\(UUID().uuidString)", isDirectory: true)
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
        try Support.seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
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

    // MARK: - Scope gating

    func testCanvasScopeMissingSkipsCanvasEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        let priorJSON = #"{"canvases":[{"channelID":"C1","canvasID":"K0","title":"Old","lastEditedMs":1}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: SlackCanvasesSnapshot(canvases: [
                    SlackCanvas(channelID: "C1", canvasID: "K0", title: "Old", lastEditedMs: 1),
                    SlackCanvas(channelID: "C1", canvasID: "K1", title: "New", lastEditedMs: 50),
                ]),
                emoji: .empty, usergroups: .empty, channelsInfo: .empty
            ))

        let c = Support.makeCollector(db, p, scopes: Support.ScopesMissing(["canvases:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackCanvasCreated.rawValue), 0)
    }

    func testEmojiScopeMissingSkipsEmojiEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        let priorJSON = #"{"emojiNames":["party"]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackEmojiList, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: SlackEmojiSnapshot(emojiNames: ["party", "tada"]),
                usergroups: .empty, channelsInfo: .empty
            ))

        let c = Support.makeCollector(db, p, scopes: Support.ScopesMissing(["emoji:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    func testUsergroupsScopeMissingSkipsUsergroupEvents() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        let priorJSON = #"{"groups":[{"id":"G1","name":"team","userIDs":["U1"]}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackUsergroups, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: SlackUsergroupsSnapshot(groups: [
                    SlackUsergroup(id: "G1", name: "team", userIDs: ["U1", "U2"])
                ]),
                channelsInfo: .empty
            ))

        let c = Support.makeCollector(db, p, scopes: Support.ScopesMissing(["usergroups:read"]))
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 0)
    }

    // MARK: - Cursor lifecycle

    func testCursorAdvancesOnSuccess() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        let p = Support.SpyProvider()
        let now = Date(timeIntervalSince1970: 12_345)
        let c = Support.makeCollector(db, p, clock: { now })
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
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        let p = Support.SpyProvider()
        await p.setShouldThrow(true)
        let c = Support.makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))

        let offset = try db.readOffset(
            collectorID: CollectorID.slackColdPolling,
            sourceID: "slack:cold:T1"
        )
        XCTAssertNil(offset, "Provider failure must NOT advance cursor")
    }

    func testProviderReceivesPriorTopChannels() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(
            db,
            [
                SlackMemberChannel(id: "C1", name: "general", latestTs: 100),
                SlackMemberChannel(id: "C2", name: "random", latestTs: 200),
            ])

        let p = Support.SpyProvider()
        let c = Support.makeCollector(db, p)
        _ = await c.performTick(now: Date(timeIntervalSince1970: 100))

        let received = await p.lastSeenTopChannels
        XCTAssertEqual(received?.channels.count, 2)
        XCTAssertEqual(Set(received?.channels.map(\.id) ?? []), ["C1", "C2"])
    }

    // MARK: - FTS dispatch fence

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
