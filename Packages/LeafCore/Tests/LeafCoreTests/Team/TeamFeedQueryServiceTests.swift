//
//  TeamFeedQueryServiceTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 C.3 — TeamFeedQueryService: UNION merge + filter dispatch tests.
//  DB-backed; uses temp SQLCipher DB with real migrations.
//

import XCTest
import GRDB
@testable import LeafCore

final class TeamFeedQueryServiceTests: XCTestCase {

    private var tempDir: URL!
    private var db: LeafCore.Database!
    private var service: TeamFeedQueryService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-feed-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        service = TeamFeedQueryService(database: db)
    }

    override func tearDown() async throws {
        service = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture helpers

    private func insertDM(
        messageID: String,
        workspaceID: String = "w1",
        kind: DirectMessageKind = .ping,
        recipientPubkeyHex: String = "rhex",
        serverCreatedAtMs: Int64,
        doneAtMs: Int64? = nil
    ) throws {
        let row = DirectMessageMirrorRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: "shex",
            senderMemberID: "m1",
            senderDisplayName: "Alice",
            recipientPubkeyHex: recipientPubkeyHex,
            kind: kind,
            body: "test body",
            attachment: nil,
            replyTo: nil,
            sentAtMs: serverCreatedAtMs - 50,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: nil,
            doneAtMs: doneAtMs,
            doneByPubkeyHex: nil,
            direction: .inbound,
            lastSyncedAtMs: serverCreatedAtMs
        )
        try db.writeSQL { rawDB in try MessagesMirrorStore.upsert(row, in: rawDB) }
    }

    private func insertEvent(
        eventID: String,
        workspaceID: String = "w1",
        source: ShareSource,
        serverCreatedAtMs: Int64
    ) throws {
        let row = TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: "shex",
            source: source,
            kind: "gh_commit_pushed",
            plaintextPayloadJSON: #"{"fields":{}}"#,
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: serverCreatedAtMs - 10,
            receivedAtMs: serverCreatedAtMs + 5
        )
        try db.writeSQL { rawDB in try TeamEventMirrorStore.upsert(row, in: rawDB) }
    }

    // MARK: - Chronological merge

    func testMergeChronologicalDESC() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertEvent(eventID: "evt1", source: .gitCommits, serverCreatedAtMs: 300)
        try insertDM(messageID: "dm2", serverCreatedAtMs: 200)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.all],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].timestamp, 300)
        XCTAssertEqual(items[1].timestamp, 200)
        XCTAssertEqual(items[2].timestamp, 100)
    }

    // MARK: - Filter: .all

    func testFilterAllReturnsBothDMsAndEvents() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertEvent(eventID: "evt1", source: .gitCommits, serverCreatedAtMs: 200)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.all],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 2)
        let hasDM = items.contains { if case .directMessage = $0 { return true }; return false }
        let hasEvt = items.contains { if case .teamEvent = $0 { return true }; return false }
        XCTAssertTrue(hasDM, "Expected directMessage item")
        XCTAssertTrue(hasEvt, "Expected teamEvent item")
    }

    // MARK: - Filter: .directMessages only

    func testFilterDirectMessagesOnly_ExcludesEvents() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertEvent(eventID: "evt1", source: .gitCommits, serverCreatedAtMs: 200)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.directMessages],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .directMessage(let row) = items[0] {
            XCTAssertEqual(row.messageID, "dm1")
        } else {
            XCTFail("Expected directMessage")
        }
    }

    // MARK: - Filter: .openTasks

    func testFilterOpenTasks_RequiresTaskKindUndoneAndRecipientMatch() async throws {
        let me = "me-pubkey"
        // Task for me, undone → should appear
        try insertDM(messageID: "task-open", kind: .task, recipientPubkeyHex: me, serverCreatedAtMs: 100, doneAtMs: nil)
        // Task for me, done → excluded
        try insertDM(messageID: "task-done", kind: .task, recipientPubkeyHex: me, serverCreatedAtMs: 200, doneAtMs: 999)
        // Task for other, undone → excluded (recipient mismatch)
        try insertDM(messageID: "task-other", kind: .task, recipientPubkeyHex: "other", serverCreatedAtMs: 300, doneAtMs: nil)
        // Ping for me → excluded (wrong kind)
        try insertDM(messageID: "ping-for-me", kind: .ping, recipientPubkeyHex: me, serverCreatedAtMs: 400)
        // An event → excluded
        try insertEvent(eventID: "evt1", source: .gitCommits, serverCreatedAtMs: 500)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.openTasks],
            limit: 50,
            before: nil,
            selfPubkeyHex: me
        )

        XCTAssertEqual(items.count, 1)
        if case .directMessage(let row) = items[0] {
            XCTAssertEqual(row.messageID, "task-open")
        } else {
            XCTFail("Expected directMessage task-open")
        }
    }

    // MARK: - Filter: .decisions

    func testFilterDecisionsOnly_ExcludesOtherSourcesAndDMs() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertEvent(eventID: "dec1", source: .detectedDecisions, serverCreatedAtMs: 200)
        try insertEvent(eventID: "block1", source: .detectedBlockers, serverCreatedAtMs: 300)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.decisions],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .teamEvent(let row) = items[0] {
            XCTAssertEqual(row.eventID, "dec1")
            XCTAssertEqual(row.source, .detectedDecisions)
        } else {
            XCTFail("Expected teamEvent dec1")
        }
    }

    // MARK: - Filter: .blockers

    func testFilterBlockersOnly() async throws {
        try insertEvent(eventID: "b1", source: .detectedBlockers, serverCreatedAtMs: 100)
        try insertEvent(eventID: "d1", source: .detectedDecisions, serverCreatedAtMs: 200)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.blockers],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .teamEvent(let row) = items[0] {
            XCTAssertEqual(row.source, .detectedBlockers)
        } else {
            XCTFail("Expected teamEvent blocker")
        }
    }

    // MARK: - Filter: .shareSource(X)

    func testFilterShareSourceSpecific_OnlyMatchingSourceReturned() async throws {
        try insertEvent(eventID: "git1", source: .gitCommits, serverCreatedAtMs: 100)
        try insertEvent(eventID: "lin1", source: .linearIssues, serverCreatedAtMs: 200)
        try insertEvent(eventID: "slk1", source: .slackMentions, serverCreatedAtMs: 300)
        try insertDM(messageID: "dm1", serverCreatedAtMs: 400)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.shareSource(.linearIssues)],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .teamEvent(let row) = items[0] {
            XCTAssertEqual(row.eventID, "lin1")
        } else {
            XCTFail("Expected linearIssues event")
        }
    }

    // MARK: - Filter: multi-select union

    func testFilterMultiSelect_DMsPlusDecisionsUnion() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertEvent(eventID: "dec1", source: .detectedDecisions, serverCreatedAtMs: 200)
        try insertEvent(eventID: "git1", source: .gitCommits, serverCreatedAtMs: 300)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.directMessages, .decisions],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        // Should include dm1 + dec1, but NOT git1
        XCTAssertEqual(items.count, 2)
        let ids = items.flatMap { item -> [String] in
            switch item {
            case .directMessage(let r): return [r.messageID]
            case .teamEvent(let r): return [r.eventID]
            case .grouped: return []
            }
        }
        XCTAssertTrue(ids.contains("dm1"))
        XCTAssertTrue(ids.contains("dec1"))
        XCTAssertFalse(ids.contains("git1"))
    }

    func testFilterMultiSelectShareSources_BothIncluded() async throws {
        try insertEvent(eventID: "git1", source: .gitCommits, serverCreatedAtMs: 100)
        try insertEvent(eventID: "lin1", source: .linearIssues, serverCreatedAtMs: 200)
        try insertEvent(eventID: "slk1", source: .slackMentions, serverCreatedAtMs: 300)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.shareSource(.gitCommits), .shareSource(.linearIssues)],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 2)
        let ids = items.map { item -> String in
            if case .teamEvent(let r) = item { return r.eventID }
            return ""
        }
        XCTAssertTrue(ids.contains("git1"))
        XCTAssertTrue(ids.contains("lin1"))
        XCTAssertFalse(ids.contains("slk1"))
    }

    // MARK: - Pagination cursor (before)

    func testBeforeCursorPagination_StrictLessThan() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertDM(messageID: "dm2", serverCreatedAtMs: 200)
        try insertDM(messageID: "dm3", serverCreatedAtMs: 300)

        // before=200 → should return only items with timestamp < 200 (i.e., dm1)
        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.all],
            limit: 50,
            before: 200,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .directMessage(let r) = items[0] {
            XCTAssertEqual(r.messageID, "dm1")
        } else {
            XCTFail("Expected dm1")
        }
    }

    func testBeforeCursorIsStrictLessThan_BoundaryRowExcluded() async throws {
        try insertDM(messageID: "boundary", serverCreatedAtMs: 500)
        try insertDM(messageID: "earlier", serverCreatedAtMs: 499)

        // before=500 → boundary row (=500) excluded; earlier (499) included
        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.all],
            limit: 50,
            before: 500,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .directMessage(let r) = items[0] {
            XCTAssertEqual(r.messageID, "earlier")
        } else {
            XCTFail("Expected earlier row")
        }
    }

    // MARK: - Limit

    func testLimitRespected() async throws {
        for i in 1...10 {
            try insertDM(messageID: "dm\(i)", serverCreatedAtMs: Int64(i * 100))
        }

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.all],
            limit: 5,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 5)
        // Should be the 5 most recent (DESC order)
        XCTAssertEqual(items[0].timestamp, 1000)
        XCTAssertEqual(items[4].timestamp, 600)
    }

    // MARK: - Empty workspace

    func testEmptyWorkspaceReturnsEmpty() async throws {
        let items = try await service.fetch(
            workspaceID: "nonexistent-workspace",
            filters: [.all],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Cross-workspace isolation

    func testWorkspaceIsolation_OtherWorkspaceEventsNotReturned() async throws {
        try insertDM(messageID: "dm-w1", workspaceID: "w1", serverCreatedAtMs: 100)
        try insertDM(messageID: "dm-w2", workspaceID: "w2", serverCreatedAtMs: 200)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.all],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .directMessage(let r) = items[0] {
            XCTAssertEqual(r.messageID, "dm-w1")
        } else {
            XCTFail("Expected w1 message")
        }
    }

    // MARK: - No DMs when only shareSource filter active

    func testOnlyShareSourceFilter_NoDMs() async throws {
        try insertDM(messageID: "dm1", serverCreatedAtMs: 100)
        try insertEvent(eventID: "git1", source: .gitCommits, serverCreatedAtMs: 200)

        let items = try await service.fetch(
            workspaceID: "w1",
            filters: [.shareSource(.gitCommits)],
            limit: 50,
            before: nil,
            selfPubkeyHex: "rhex"
        )

        XCTAssertEqual(items.count, 1)
        if case .teamEvent(let r) = items[0] {
            XCTAssertEqual(r.eventID, "git1")
        } else {
            XCTFail("Expected teamEvent only")
        }
    }
}
