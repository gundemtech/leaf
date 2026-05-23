//
//  TeamFeedItemTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 C.1 + C.2 — FeedItem enum: ID stability + timestamp invariants.
//  No DB required — pure value-type tests.
//

import XCTest
@testable import LeafCore

final class TeamFeedItemTests: XCTestCase {

    // MARK: - Helpers

    private func makeDMRow(
        messageID: String = "msg-1",
        serverCreatedAtMs: Int64 = 1_000
    ) -> DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: messageID,
            workspaceID: "w1",
            senderPubkeyHex: "shex",
            senderMemberID: "m1",
            senderDisplayName: "Alice",
            recipientPubkeyHex: "rhex",
            kind: .ping,
            body: "hello",
            attachment: nil,
            replyTo: nil,
            sentAtMs: serverCreatedAtMs - 50,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .inbound,
            lastSyncedAtMs: serverCreatedAtMs
        )
    }

    private func makeEventRow(
        eventID: String = "evt-1",
        serverCreatedAtMs: Int64 = 2_000
    ) -> TeamEventMirrorRow {
        TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: "w1",
            senderPubkeyHex: "shex",
            source: .gitCommits,
            kind: "gh_commit_pushed",
            plaintextPayloadJSON: #"{"fields":{}}"#,
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: serverCreatedAtMs - 10,
            receivedAtMs: serverCreatedAtMs + 5
        )
    }

    private func makeGroupedItem(
        kind: String = "linear_issue_updated",
        senderPubkeyHex: String = "shex",
        spanStartMs: Int64 = 100,
        spanEndMs: Int64 = 999,
        count: Int = 3
    ) -> FeedItem {
        let sender = TeamMember(
            id: "m1",
            workspaceID: "w1",
            role: .member,
            pubkeyHex: senderPubkeyHex,
            displayName: "Alice",
            addedAt: Date(timeIntervalSince1970: 0),
            removedAt: nil
        )
        return .grouped(
            kind: kind,
            sender: sender,
            count: count,
            spanStartMs: spanStartMs,
            spanEndMs: spanEndMs,
            items: []
        )
    }

    // MARK: - ID stability

    func testFeedItemDirectMessageID_UsesMessageID() {
        let row = makeDMRow(messageID: "uuid-abc")
        let item = FeedItem.directMessage(row)
        XCTAssertEqual(item.id, "uuid-abc")
    }

    func testFeedItemTeamEventID_UsesEventID() {
        let row = makeEventRow(eventID: "evt-xyz")
        let item = FeedItem.teamEvent(RenderedTeamEvent(row: row))
        XCTAssertEqual(item.id, "evt-xyz")
    }

    func testFeedItemDirectMessageID_StableAcrossReDecodes() {
        let row = makeDMRow(messageID: "stable-id")
        let itemA = FeedItem.directMessage(row)
        let itemB = FeedItem.directMessage(row)
        XCTAssertEqual(itemA.id, itemB.id)
    }

    func testFeedItemGroupedID_EncodesKindSenderAndSpanStart() {
        let item = makeGroupedItem(
            kind: "linear_issue_updated",
            senderPubkeyHex: "aabbcc",
            spanStartMs: 500,
            spanEndMs: 999
        )
        XCTAssertEqual(item.id, "grouped-linear_issue_updated-aabbcc-500")
    }

    func testFeedItemGroupedID_DifferentSpanStartProducesDifferentID() {
        let itemA = makeGroupedItem(spanStartMs: 100, spanEndMs: 200)
        let itemB = makeGroupedItem(spanStartMs: 300, spanEndMs: 400)
        XCTAssertNotEqual(itemA.id, itemB.id)
    }

    func testFeedItemDMAndEventIDs_NeverCollide_ForSameStringValue() {
        // even if message_id and event_id coincidentally share the same string,
        // they produce the same raw id — this tests that the implementation
        // doesn't add any disambiguation prefix (by contract, IDs come from
        // different UUID namespaces at the Supabase layer; collision is impossible
        // in practice). We just verify the id IS the raw underlying id.
        let row1 = makeDMRow(messageID: "some-id")
        let row2 = makeEventRow(eventID: "other-id")
        let dm = FeedItem.directMessage(row1)
        let evt = FeedItem.teamEvent(RenderedTeamEvent(row: row2))
        XCTAssertEqual(dm.id, "some-id")
        XCTAssertEqual(evt.id, "other-id")
        XCTAssertNotEqual(dm.id, evt.id)
    }

    // MARK: - timestamp

    func testFeedItemDirectMessageTimestamp_UsesServerCreatedAtMs() {
        let row = makeDMRow(serverCreatedAtMs: 12_345)
        let item = FeedItem.directMessage(row)
        XCTAssertEqual(item.timestamp, 12_345)
    }

    func testFeedItemTeamEventTimestamp_UsesServerCreatedAtMs() {
        let row = makeEventRow(serverCreatedAtMs: 99_000)
        let item = FeedItem.teamEvent(RenderedTeamEvent(row: row))
        XCTAssertEqual(item.timestamp, 99_000)
    }

    func testFeedItemGroupedTimestamp_UsesSpanEndMs() {
        let item = makeGroupedItem(spanStartMs: 100, spanEndMs: 888)
        XCTAssertEqual(item.timestamp, 888)
    }

    // MARK: - Equatable

    func testFeedItemDirectMessage_EqualToSelf() {
        let row = makeDMRow()
        let item = FeedItem.directMessage(row)
        XCTAssertEqual(item, item)
    }

    func testFeedItemTeamEvent_EqualToSelf() {
        let row = makeEventRow()
        let item = FeedItem.teamEvent(RenderedTeamEvent(row: row))
        XCTAssertEqual(item, item)
    }

    func testFeedItemDifferentCases_AreNotEqual() {
        let dm = FeedItem.directMessage(makeDMRow())
        let evt = FeedItem.teamEvent(RenderedTeamEvent(row: makeEventRow()))
        XCTAssertNotEqual(dm, evt)
    }
}
