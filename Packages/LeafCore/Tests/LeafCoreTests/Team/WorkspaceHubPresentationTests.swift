//
//  WorkspaceHubPresentationTests.swift
//  LeafCoreTests
//
//  Team → Workspace Hub — pure presentation logic for the hub page:
//  tab enum raw-value contract, header subtitle, roster ordering,
//  viewer-admin detection. No DB — pure value-type tests.
//

import XCTest

@testable import LeafCore

final class WorkspaceHubPresentationTests: XCTestCase {

  // MARK: - Fixtures

  private func makeMember(
    id: String = "m-1",
    role: TeamMemberRole = .member,
    pubkeyHex: String = "aabb",
    displayName: String = "Alice"
  ) -> TeamMember {
    TeamMember(
      id: id,
      workspaceID: "w1",
      role: role,
      pubkeyHex: pubkeyHex,
      displayName: displayName,
      addedAt: Date(timeIntervalSince1970: 0),
      removedAt: nil
    )
  }

  // MARK: - TeamHubTab

  func testTabRawValueRoundTrip() {
    for tab in TeamHubTab.allCases {
      XCTAssertEqual(TeamHubTab(rawValue: tab.rawValue), tab)
    }
  }

  /// Documents the @AppStorage / persisted-raw-value fallback contract:
  /// unknown raw strings must decode to nil (caller falls back to default).
  func testTabUnknownRawValueDecodesToNil() {
    XCTAssertNil(TeamHubTab(rawValue: "bogus"))
    XCTAssertNil(TeamHubTab(rawValue: ""))
  }

  func testTabTitles() {
    XCTAssertEqual(TeamHubTab.feed.title, "Feed")
    XCTAssertEqual(TeamHubTab.members.title, "Members")
    XCTAssertEqual(TeamHubTab.settings.title, "Settings")
  }

  // MARK: - Subtitle

  func testSubtitleSingularMember() {
    let s = WorkspaceHubPresentation.subtitle(
      memberCount: 1,
      createdAt: Date(timeIntervalSince1970: 1_777_000_000),  // 2026-04-24 UTC
      locale: Locale(identifier: "en_US"),
      timeZone: TimeZone(identifier: "UTC")!
    )
    XCTAssertEqual(s, "1 member · created Apr 24, 2026")
  }

  func testSubtitlePluralMembers() {
    let s = WorkspaceHubPresentation.subtitle(
      memberCount: 3,
      createdAt: Date(timeIntervalSince1970: 1_777_000_000),
      locale: Locale(identifier: "en_US"),
      timeZone: TimeZone(identifier: "UTC")!
    )
    XCTAssertEqual(s, "3 members · created Apr 24, 2026")
  }

  func testSubtitleZeroMembersUsesPlural() {
    let s = WorkspaceHubPresentation.subtitle(
      memberCount: 0,
      createdAt: Date(timeIntervalSince1970: 1_777_000_000),
      locale: Locale(identifier: "en_US"),
      timeZone: TimeZone(identifier: "UTC")!
    )
    XCTAssertTrue(s.hasPrefix("0 members"))
  }

  // MARK: - Roster ordering

  func testSortedRosterAdminsFirstThenAlphabetical() {
    let members = [
      makeMember(id: "m-1", role: .member, pubkeyHex: "01", displayName: "zoe"),
      makeMember(id: "m-2", role: .admin, pubkeyHex: "02", displayName: "Eve"),
      makeMember(id: "m-3", role: .member, pubkeyHex: "03", displayName: "Alice"),
      makeMember(id: "m-4", role: .admin, pubkeyHex: "04", displayName: "alex"),
    ]
    let sorted = WorkspaceHubPresentation.sortedRoster(members)
    XCTAssertEqual(sorted.map(\.id), ["m-4", "m-2", "m-3", "m-1"])
  }

  func testSortedRosterStableTiebreakByID() {
    let members = [
      makeMember(id: "m-b", role: .member, pubkeyHex: "01", displayName: "Same"),
      makeMember(id: "m-a", role: .member, pubkeyHex: "02", displayName: "same"),
    ]
    let sorted = WorkspaceHubPresentation.sortedRoster(members)
    XCTAssertEqual(sorted.map(\.id), ["m-a", "m-b"])
  }

  // MARK: - Viewer admin detection

  func testIsViewerAdminMatchesAdminPubkey() {
    let members = [
      makeMember(id: "m-1", role: .admin, pubkeyHex: "feed01"),
      makeMember(id: "m-2", role: .member, pubkeyHex: "feed02"),
    ]
    XCTAssertTrue(
      WorkspaceHubPresentation.isViewerAdmin(pubkeyHex: "feed01", members: members))
  }

  func testIsViewerAdminFalseForMemberRole() {
    let members = [makeMember(role: .member, pubkeyHex: "feed02")]
    XCTAssertFalse(
      WorkspaceHubPresentation.isViewerAdmin(pubkeyHex: "feed02", members: members))
  }

  func testIsViewerAdminFalseForEmptyHexOrUnknown() {
    let members = [makeMember(role: .admin, pubkeyHex: "feed01")]
    XCTAssertFalse(WorkspaceHubPresentation.isViewerAdmin(pubkeyHex: "", members: members))
    XCTAssertFalse(
      WorkspaceHubPresentation.isViewerAdmin(pubkeyHex: "dead", members: members))
    XCTAssertFalse(WorkspaceHubPresentation.isViewerAdmin(pubkeyHex: "feed01", members: []))
  }
}
