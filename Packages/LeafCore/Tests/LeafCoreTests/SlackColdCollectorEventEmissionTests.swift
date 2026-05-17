//
//  SlackColdCollectorEventEmissionTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — per-endpoint diff event emission (canvas, emoji, usergroup,
//  channels:info). Split from SlackColdCollectorTests.swift for type_body_length.
//

import XCTest
import os

import class GRDB.Row

@testable import LeafCore

final class SlackColdCollectorEventEmissionTests: XCTestCase {
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

    func testCanvasCreatedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        // Seed prior canvases — empty for the channel but non-empty overall so
        // bootstrap discipline does not suppress.
        let priorJSON = #"{"canvases":[{"channelID":"C1","canvasID":"K0","title":"Old","lastEditedMs":1}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackCanvasCreated.rawValue), 1)

        let payload = try Support.eventPayload(db, eventKind: SlackEventKindKey.slackCanvasCreated.rawValue)
        XCTAssertEqual(payload?["canvas_id"] as? String, "K1")
        XCTAssertEqual(payload?["body"] as? String, "Onboarding", "title routed via body for FTS dispatch")
    }

    func testCanvasEditedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [SlackMemberChannel(id: "C1", name: "general", latestTs: 100)])

        let priorJSON = #"{"canvases":[{"channelID":"C1","canvasID":"K1","title":"Old","lastEditedMs":10}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: SlackCanvasesSnapshot(canvases: [
                    SlackCanvas(channelID: "C1", canvasID: "K1", title: "New", lastEditedMs: 50)
                ]),
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: .empty
            ))

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackCanvasEdited.rawValue), 1)
    }

    func testCustomEmojiAddedEmitsEvent() async throws {
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
                usergroups: .empty,
                channelsInfo: .empty
            ))

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackCustomEmojiAdded.rawValue), 1)

        let payload = try Support.eventPayload(db, eventKind: SlackEventKindKey.slackCustomEmojiAdded.rawValue)
        XCTAssertEqual(payload?["emoji_name"] as? String, "tada")
    }

    func testUsergroupMembershipDeltaEmitsPerGroup() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        // Prior: G1 has [U1]; current: G1 has [U1, U2]; expect one event with added=[U2], removed=[]
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(
            try Support.eventCount(db, eventKind: SlackEventKindKey.slackUsergroupMembershipChanged.rawValue), 1)

        let payload = try Support.eventPayload(
            db, eventKind: SlackEventKindKey.slackUsergroupMembershipChanged.rawValue)
        XCTAssertEqual(payload?["group_id"] as? String, "G1")
        let addedJSON = payload?["added_user_ids_json"] as? String ?? ""
        let added = try? JSONDecoder().decode([String].self, from: Data(addedJSON.utf8))
        XCTAssertEqual(added, ["U2"])
    }

    func testChannelRenamedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        let priorJSON = #"{"channels":[{"channelID":"C1","name":"old","isArchived":false}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackChannelsInfo, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: SlackChannelsInfoSnapshot(channels: [
                    SlackChannelInfo(channelID: "C1", name: "new", isArchived: false)
                ])
            ))

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackChannelRenamed.rawValue), 1)

        let payload = try Support.eventPayload(db, eventKind: SlackEventKindKey.slackChannelRenamed.rawValue)
        XCTAssertEqual(payload?["old_name"] as? String, "old")
        XCTAssertEqual(payload?["new_name"] as? String, "new")
    }

    func testChannelArchivedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)
        try Support.seedTopChannels(db, [])

        let priorJSON = #"{"channels":[{"channelID":"C1","name":"general","isArchived":false}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackChannelsInfo, json: priorJSON)

        let p = Support.SpyProvider()
        await p.setBatch(
            SlackColdBatch(
                canvases: .empty,
                emoji: .empty,
                usergroups: .empty,
                channelsInfo: SlackChannelsInfoSnapshot(channels: [
                    SlackChannelInfo(channelID: "C1", name: "general", isArchived: true)
                ])
            ))

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackChannelArchived.rawValue), 1)
    }
}
