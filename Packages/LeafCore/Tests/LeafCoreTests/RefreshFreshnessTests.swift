//
//  RefreshFreshnessTests.swift
//  LeafCoreTests
//
//  Phase M-XI (optimization-tier-m.md). Pure freshness predicate coverage:
//  nil timestamp, within window, boundary (strict <), beyond window, zero
//  window, negative delta.
//

import XCTest

@testable import LeafCore

final class RefreshFreshnessTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000_000)

  func testNilTimestampNotFresh() {
    // No prior successful load — first refresh always proceeds.
    XCTAssertFalse(RefreshFreshness.isFresh(lastRefreshedAt: nil, now: base, window: 5))
  }

  func testWithinWindowIsFresh() {
    let last = base.addingTimeInterval(-2)
    XCTAssertTrue(RefreshFreshness.isFresh(lastRefreshedAt: last, now: base, window: 5))
  }

  func testBoundaryNotFresh() {
    // now - last == window → strict < is false → not fresh.
    let last = base.addingTimeInterval(-5)
    XCTAssertFalse(RefreshFreshness.isFresh(lastRefreshedAt: last, now: base, window: 5))
  }

  func testBeyondWindowNotFresh() {
    let last = base.addingTimeInterval(-7)
    XCTAssertFalse(RefreshFreshness.isFresh(lastRefreshedAt: last, now: base, window: 5))
  }

  func testZeroWindowNeverFresh() {
    XCTAssertFalse(RefreshFreshness.isFresh(lastRefreshedAt: base, now: base, window: 0))
  }

  func testZeroDeltaWithNonzeroWindowIsFresh() {
    // now == last, window > 0 → delta 0 < window → fresh.
    XCTAssertTrue(RefreshFreshness.isFresh(lastRefreshedAt: base, now: base, window: 5))
  }

  func testNegativeDeltaIsFresh() {
    // Clock moved backwards / last is in the future relative to now → delta < window.
    let last = base.addingTimeInterval(3)
    XCTAssertTrue(RefreshFreshness.isFresh(lastRefreshedAt: last, now: base, window: 5))
  }
}
