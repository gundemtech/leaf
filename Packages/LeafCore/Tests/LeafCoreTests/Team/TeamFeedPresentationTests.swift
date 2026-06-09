//
//  TeamFeedPresentationTests.swift
//  LeafCoreTests
//
//  Team UI polish — pure presentation transforms for the Team feed:
//  name resolution, timestamp style, day sections, DM run flags.
//  No DB required — pure value-type tests (fixtures mirror TeamFeedItemTests).
//

import XCTest

@testable import LeafCore

final class TeamFeedPresentationTests: XCTestCase {

  // MARK: - Fixtures

  private func makeMember(
    pubkeyHex: String = "aabb",
    displayName: String = "Alice"
  ) -> TeamMember {
    TeamMember(
      id: "m-\(pubkeyHex)",
      workspaceID: "w1",
      role: .member,
      pubkeyHex: pubkeyHex,
      displayName: displayName,
      addedAt: Date(timeIntervalSince1970: 0),
      removedAt: nil
    )
  }

  private func makeDM(
    messageID: String,
    senderPubkeyHex: String = "shex",
    recipientPubkeyHex: String = "rhex",
    direction: DirectMessageMirrorRow.Direction = .inbound,
    serverCreatedAtMs: Int64,
    readAtMs: Int64? = nil
  ) -> FeedItem {
    .directMessage(
      DirectMessageMirrorRow(
        messageID: messageID,
        workspaceID: "w1",
        senderPubkeyHex: senderPubkeyHex,
        senderMemberID: "m1",
        senderDisplayName: "Alice",
        recipientPubkeyHex: recipientPubkeyHex,
        kind: .ping,
        body: "hello",
        sentAtMs: serverCreatedAtMs - 50,
        serverCreatedAtMs: serverCreatedAtMs,
        readAtMs: readAtMs,
        direction: direction,
        lastSyncedAtMs: serverCreatedAtMs
      ))
  }

  private func makeEvent(eventID: String, serverCreatedAtMs: Int64) -> FeedItem {
    .teamEvent(
      RenderedTeamEvent(
        row: TeamEventMirrorRow(
          eventID: eventID,
          workspaceID: "w1",
          senderPubkeyHex: "shex",
          source: .gitCommits,
          kind: "gh_commit_pushed",
          plaintextPayloadJSON: #"{"fields":{}}"#,
          serverCreatedAtMs: serverCreatedAtMs,
          eventTsMs: serverCreatedAtMs - 10,
          receivedAtMs: serverCreatedAtMs + 5
        )))
  }

  /// Fixed "now": 2026-06-10 12:00:00 UTC, UTC calendar for determinism.
  private let now = Date(timeIntervalSince1970: 1_781_092_800)
  private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }
  private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

  // MARK: - TeamMemberNameResolver

  func testResolverReturnsMemberDisplayName() {
    let members = [makeMember(pubkeyHex: "aabb", displayName: "Anna D")]
    XCTAssertEqual(
      TeamMemberNameResolver.displayName(pubkeyHex: "aabb", members: members),
      "Anna D")
  }

  func testResolverFallsBackForUnknownPubkey() {
    XCTAssertEqual(
      TeamMemberNameResolver.displayName(pubkeyHex: "46f6e87b00", members: []),
      "Former teammate")
  }

  func testResolverPrefersEmbeddedNameOverFallback() {
    XCTAssertEqual(
      TeamMemberNameResolver.displayName(
        pubkeyHex: "dead", members: [], embeddedDisplayName: "Bob"),
      "Bob")
  }

  func testResolverIgnoresEmptyEmbeddedName() {
    XCTAssertEqual(
      TeamMemberNameResolver.displayName(
        pubkeyHex: "dead", members: [], embeddedDisplayName: ""),
      "Former teammate")
  }

  // MARK: - FeedTimestampStyle

  func testTimestampStyleRelativeForToday() {
    XCTAssertEqual(
      TeamFeedPresentation.timestampStyle(forMs: nowMs - 60_000, now: now, calendar: cal),
      .relative)
  }

  func testTimestampStyleClockForOlderDay() {
    let yesterdayMs = nowMs - 24 * 3_600_000
    XCTAssertEqual(
      TeamFeedPresentation.timestampStyle(forMs: yesterdayMs, now: now, calendar: cal),
      .clock)
  }

  // MARK: - daySections

  func testDaySectionsSplitsTodayAndYesterday() {
    let items = [
      makeDM(messageID: "m1", serverCreatedAtMs: nowMs - 60_000),  // today
      makeDM(messageID: "m2", serverCreatedAtMs: nowMs - 25 * 3_600_000),  // yesterday
    ]
    let sections = TeamFeedPresentation.daySections(items: items, now: now, calendar: cal)
    XCTAssertEqual(sections.count, 2)
    XCTAssertEqual(sections[0].label, "Today")
    XCTAssertEqual(sections[0].items.map(\.id), ["m1"])
    XCTAssertEqual(sections[1].label, "Yesterday")
    XCTAssertEqual(sections[1].items.map(\.id), ["m2"])
  }

  func testDaySectionsOlderSameYearUsesMonthDay() {
    let items = [makeDM(messageID: "m1", serverCreatedAtMs: nowMs - 21 * 24 * 3_600_000)]
    let sections = TeamFeedPresentation.daySections(items: items, now: now, calendar: cal)
    XCTAssertEqual(sections[0].label, "May 20")
  }

  func testDaySectionsDifferentYearAppendsYear() {
    let items = [makeDM(messageID: "m1", serverCreatedAtMs: nowMs - 400 * 24 * 3_600_000)]
    let sections = TeamFeedPresentation.daySections(items: items, now: now, calendar: cal)
    XCTAssertTrue(sections[0].label.hasSuffix(", 2025"), "got: \(sections[0].label)")
  }

  func testDaySectionsPreservesNewestFirstOrderAndStableIDs() {
    let items = [
      makeDM(messageID: "m1", serverCreatedAtMs: nowMs - 1_000),
      makeEvent(eventID: "e1", serverCreatedAtMs: nowMs - 2_000),
      makeDM(messageID: "m2", serverCreatedAtMs: nowMs - 26 * 3_600_000),
    ]
    let sections = TeamFeedPresentation.daySections(items: items, now: now, calendar: cal)
    XCTAssertEqual(sections.count, 2)
    XCTAssertEqual(sections[0].items.map(\.id), ["m1", "e1"])
    XCTAssertEqual(sections[0].id, "day-2026-06-10")
    XCTAssertEqual(sections[1].id, "day-2026-06-09")
  }

  func testDaySectionsEmptyInput() {
    XCTAssertTrue(
      TeamFeedPresentation.daySections(items: [], now: now, calendar: cal).isEmpty)
  }

  // MARK: - dmRenderFlags
  // Items arrive in display order (newest-first), one day section at a time.

  func testRunHeaderOnNewestOfConsecutiveSameSenderInbound() {
    let items = [
      makeDM(messageID: "m1", senderPubkeyHex: "anton", serverCreatedAtMs: nowMs - 60_000),
      makeDM(messageID: "m2", senderPubkeyHex: "anton", serverCreatedAtMs: nowMs - 120_000),
    ]
    let flags = TeamFeedPresentation.dmRenderFlags(items: items)
    XCTAssertEqual(flags["m1"]?.showsHeader, true)  // topmost (newest) of run
    XCTAssertEqual(flags["m2"]?.showsHeader, false)
  }

  func testRunBreaksOnDifferentRecipientOutbound() {
    // CTO-review CRITICAL-1: outbound runs key on the recipient — messages to
    // different people must NOT collapse under one header.
    let items = [
      makeDM(
        messageID: "m1", recipientPubkeyHex: "anton", direction: .outbound,
        serverCreatedAtMs: nowMs - 60_000),
      makeDM(
        messageID: "m2", recipientPubkeyHex: "anna", direction: .outbound,
        serverCreatedAtMs: nowMs - 90_000),
    ]
    let flags = TeamFeedPresentation.dmRenderFlags(items: items)
    XCTAssertEqual(flags["m1"]?.showsHeader, true)
    XCTAssertEqual(flags["m2"]?.showsHeader, true)
  }

  func testRunBreaksOnDirectionFlip() {
    let items = [
      makeDM(
        messageID: "m1", senderPubkeyHex: "anton", direction: .inbound,
        serverCreatedAtMs: nowMs - 60_000),
      makeDM(
        messageID: "m2", recipientPubkeyHex: "anton", direction: .outbound,
        serverCreatedAtMs: nowMs - 90_000),
    ]
    let flags = TeamFeedPresentation.dmRenderFlags(items: items)
    XCTAssertEqual(flags["m1"]?.showsHeader, true)
    XCTAssertEqual(flags["m2"]?.showsHeader, true)
  }

  func testRunBreaksOnWindowExceeded() {
    let items = [
      makeDM(messageID: "m1", senderPubkeyHex: "anton", serverCreatedAtMs: nowMs - 60_000),
      makeDM(
        messageID: "m2", senderPubkeyHex: "anton",
        serverCreatedAtMs: nowMs - 60_000 - TeamFeedPresentation.runWindowMs - 1),
    ]
    let flags = TeamFeedPresentation.dmRenderFlags(items: items)
    XCTAssertEqual(flags["m2"]?.showsHeader, true)
  }

  func testRunBreaksOnInterleavedEvent() {
    let items = [
      makeDM(messageID: "m1", senderPubkeyHex: "anton", serverCreatedAtMs: nowMs - 60_000),
      makeEvent(eventID: "e1", serverCreatedAtMs: nowMs - 70_000),
      makeDM(messageID: "m2", senderPubkeyHex: "anton", serverCreatedAtMs: nowMs - 80_000),
    ]
    let flags = TeamFeedPresentation.dmRenderFlags(items: items)
    XCTAssertEqual(flags["m2"]?.showsHeader, true)
  }

  func testReceiptOnlyOnNewestReadOutboundOfRun() {
    let items = [
      makeDM(
        messageID: "m1", recipientPubkeyHex: "anton", direction: .outbound,
        serverCreatedAtMs: nowMs - 60_000, readAtMs: nil),  // unread, newest
      makeDM(
        messageID: "m2", recipientPubkeyHex: "anton", direction: .outbound,
        serverCreatedAtMs: nowMs - 90_000, readAtMs: nowMs - 30_000),  // read → receipt
      makeDM(
        messageID: "m3", recipientPubkeyHex: "anton", direction: .outbound,
        serverCreatedAtMs: nowMs - 120_000, readAtMs: nowMs - 40_000),  // older read → none
    ]
    let flags = TeamFeedPresentation.dmRenderFlags(items: items)
    XCTAssertEqual(flags["m1"]?.showsReceipt, false)
    XCTAssertEqual(flags["m2"]?.showsReceipt, true)
    XCTAssertEqual(flags["m3"]?.showsReceipt, false)
  }

  func testInboundNeverShowsReceipt() {
    let items = [makeDM(messageID: "m1", serverCreatedAtMs: nowMs, readAtMs: nowMs)]
    XCTAssertEqual(TeamFeedPresentation.dmRenderFlags(items: items)["m1"]?.showsReceipt, false)
  }
}
