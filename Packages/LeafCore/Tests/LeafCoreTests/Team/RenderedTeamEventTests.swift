//
//  RenderedTeamEventTests.swift
//  LeafCoreTests
//
//  M-IX — the presentation carrier precomputes actionText and exposes a
//  stable id.
//

import XCTest
@testable import LeafCore

final class RenderedTeamEventTests: XCTestCase {

    private func makeRow(eventID: String = "e1", source: ShareSource, payloadJSON: String) -> TeamEventMirrorRow {
        TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: "w1",
            senderPubkeyHex: "shex",
            source: source,
            kind: "k",
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: 10,
            eventTsMs: 10,
            receivedAtMs: 10
        )
    }

    func testInitPrecomputesActionText() {
        let row = makeRow(source: .gitCommits, payloadJSON: #"{"title":"Fix"}"#)
        let rendered = RenderedTeamEvent(row: row)
        XCTAssertEqual(rendered.actionText, TeamEventActionText.make(for: row))
        XCTAssertEqual(rendered.actionText, #"pushed "Fix""#)
    }

    func testIDIsEventID() {
        let row = makeRow(eventID: "abc-123", source: .slackMentions, payloadJSON: "{}")
        XCTAssertEqual(RenderedTeamEvent(row: row).id, "abc-123")
    }

    func testRowIsCarriedUnchanged() {
        let row = makeRow(source: .linearIssues, payloadJSON: #"{"title":"X"}"#)
        XCTAssertEqual(RenderedTeamEvent(row: row).row, row)
    }

    func testEquatable() {
        let row = makeRow(source: .gitCommits, payloadJSON: #"{"title":"Fix"}"#)
        XCTAssertEqual(RenderedTeamEvent(row: row), RenderedTeamEvent(row: row))
    }
}
