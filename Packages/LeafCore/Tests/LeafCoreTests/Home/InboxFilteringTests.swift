//
//  InboxFilteringTests.swift
//  Home redesign — replaces the NeedsYouBlock IV.A.1 stub where every chip
//  showed `items.count` and the selected filter was never applied. Locks the
//  filter/count contract the SwiftUI body consumes.
//

import XCTest

@testable import LeafCore

final class InboxFilteringTests: XCTestCase {

  private func item(
    _ id: String, kind: InboxKind, severity: InboxSeverity = .muted,
    title: String = "title", ts: Int64 = 0
  ) -> InboxItem {
    InboxItem(
      id: id, kind: kind, severity: severity, title: title,
      sourceMeta: "meta-\(id)", sourceURL: nil, aggregatedCount: 1, createdAtMs: ts)
  }

  private var fixture: [InboxItem] {
    [
      item("1", kind: .ciFailed, severity: .danger, title: "CI failed: leaf"),
      item("2", kind: .openQuestion, severity: .warn, title: "Which KDF?"),
      item("3", kind: .reviewRequest, title: "leaf#12"),
      item("4", kind: .commentOnMyWork, title: "leaf#9"),
      item("5", kind: .mention, title: "@you in #general"),
    ]
  }

  // MARK: - filtered

  func testFiltered_appliesFilterKind() {
    let reviews = InboxFiltering.filtered(fixture, filter: .reviews, query: "")
    XCTAssertEqual(reviews.map(\.id), ["3"])
  }

  func testFiltered_actionableExcludesComments() {
    let actionable = InboxFiltering.filtered(fixture, filter: .actionable, query: "")
    XCTAssertEqual(Set(actionable.map(\.id)), ["1", "2", "3", "5"])
  }

  func testFiltered_queryMatchesTitleCaseInsensitive() {
    let hits = InboxFiltering.filtered(fixture, filter: .all, query: "ci FAILED")
    XCTAssertEqual(hits.map(\.id), ["1"])
  }

  func testFiltered_queryMatchesSourceMeta() {
    let hits = InboxFiltering.filtered(fixture, filter: .all, query: "meta-4")
    XCTAssertEqual(hits.map(\.id), ["4"])
  }

  func testFiltered_filterAndQueryCompose() {
    let hits = InboxFiltering.filtered(fixture, filter: .reviews, query: "general")
    XCTAssertTrue(hits.isEmpty)
  }

  // MARK: - counts

  func testCounts_perFilter() {
    let counts = InboxFiltering.counts(fixture)
    XCTAssertEqual(counts[.all], 5)
    XCTAssertEqual(counts[.actionable], 4)
    XCTAssertEqual(counts[.reviews], 1)
    XCTAssertEqual(counts[.questions], 1)
    XCTAssertEqual(counts[.mentions], 1)
    XCTAssertEqual(counts[.alerts], 1)
  }

  func testCounts_emptyItems_allZero() {
    let counts = InboxFiltering.counts([])
    for filter in InboxFilter.allCases {
      XCTAssertEqual(counts[filter], 0)
    }
  }
}
