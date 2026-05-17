//
//  SlackWarmCollectorEventEmissionTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 — per-endpoint warm diff emission (channels / reactions /
//  pins / bookmarks / reminders / scheduled / stars). Split from
//  SlackWarmCollectorTests.swift for type_body_length.
//

import XCTest

@testable import LeafCore

final class SlackWarmCollectorEventEmissionTests: XCTestCase {
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

    func testJoinedChannelEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        // Seed prior member-channels snapshot with one channel.
        let priorJSON = #"{"channels":[{"id":"C1","name":"general","latestTs":100}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackChannelJoined.rawValue), 1)
    }

    func testLeftChannelEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON =
            #"{"channels":[{"id":"C1","name":"general","latestTs":100},{"id":"C2","name":"random","latestTs":200}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackMemberChannels, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackChannelLeft.rawValue), 1)
    }

    func testReactionAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        // For reactions, the provider determines new vs old (since cursor). Spy returns
        // a single reaction → collector emits one reaction_added event.
        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackReactionAdded.rawValue), 1)
    }

    func testPinAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        // Seed prior pins snapshot — channel C1 has zero pins. Then current has one pin.
        let priorJSON = #"[{"channelID":"C1","pinItemRefs":[]}]"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackPinAdded.rawValue), 1)
    }

    func testPinRemovedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"[{"channelID":"C1","pinItemRefs":["C1:1.0"]}]"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackPinsPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackPinRemoved.rawValue), 1)
    }

    func testBookmarkAddedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"[{"channelID":"C1","bookmarks":[]}]"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackBookmarkAdded.rawValue), 1)
    }

    func testBookmarkRemovedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"""
            [{"channelID":"C1","bookmarks":[{"channelID":"C1","id":"bm1","title":"Old","link":"https://x","lastEditedMs":1}]}]
            """#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackBookmarksPerChannel, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackBookmarkRemoved.rawValue), 1)
    }

    func testReminderCreatedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"{"reminders":[{"id":"R0","dueTs":50,"completedTs":null}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackReminders, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackReminderCreated.rawValue), 1)
    }

    func testReminderCompletedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"{"reminders":[{"id":"R1","dueTs":50,"completedTs":null}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackReminders, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackReminderCompleted.rawValue), 1)
    }

    func testScheduledMessageEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"{"messages":[{"id":"SM0","channelID":"C1","scheduledFor":50,"sent":false}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackScheduledMessages, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackMessageScheduled.rawValue), 1)
    }

    func testScheduledMessageSentEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"{"messages":[{"id":"SM0","channelID":"C1","scheduledFor":50,"sent":false}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackScheduledMessages, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackMessageSentScheduled.rawValue), 1)
    }

    func testItemSavedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"{"stars":[{"itemRef":"C1:1.0","savedAtMs":10}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackStars, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackItemSaved.rawValue), 1)
    }

    func testItemUnsavedEmitsEvent() async throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try Support.insertSlackIntegration(db)

        let priorJSON = #"{"stars":[{"itemRef":"C1:1.0","savedAtMs":10}]}"#
        try Support.seedPriorSnapshot(db, kind: Schema.ProviderSnapshotKinds.slackStars, json: priorJSON)

        let p = Support.SpyProvider()
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

        let c = Support.makeCollector(db, p)
        let r = await c.performTick(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(r.eventsEmitted, 1)
        XCTAssertEqual(try Support.eventCount(db, eventKind: SlackEventKindKey.slackItemUnsaved.rawValue), 1)
    }
}
