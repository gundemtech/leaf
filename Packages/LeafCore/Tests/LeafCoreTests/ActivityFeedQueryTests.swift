// AI-UI-2 — ActivityFeedQuery: period fetch → ActivityFeedMapper → coalesce.
// Живой источник Activity Raw events + кандидатов escalation-модалки.

import GRDB
import XCTest

@testable import LeafCore

final class ActivityFeedQueryTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!
  private let period = DateInterval(
    start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10_000))

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-feedq-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func openWriter() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  private func writeEvent(
    _ db: LeafCore.Database, tsMs: Int64, signalType: SignalType = .action,
    bundleID: String? = nil, payload: [String: String]
  ) throws {
    try db.write(
      RawEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0),
        signalType: signalType, bundleID: bundleID, payload: payload))
  }

  private func makeQuery() -> ActivityFeedQuery {
    ActivityFeedQuery(dbURL: dbURL, dbConfig: .weakDefaults, dbEncryption: .deterministicTest)
  }

  /// Валидный github-пуш для ActivityFeedMapper.mapGitHub (source+repo обязательны;
  /// branch различает primaryText, чтобы строки не коалесцировались).
  private func ghPush(branch: String) -> [String: String] {
    ["source": "github", "event_kind": "gh_commit_pushed", "repo": "leaf", "branch": branch]
  }

  // 1. Маппится через ActivityFeedMapper, newest-first.
  func testFetch_mapsRows_newestFirst() throws {
    let db = try openWriter()
    try writeEvent(db, tsMs: 1_000, payload: ghPush(branch: "older"))
    try writeEvent(db, tsMs: 2_000, payload: ghPush(branch: "newer"))
    let entries = try makeQuery().fetch(period: period)
    XCTAssertEqual(entries.count, 2)
    XCTAssertGreaterThan(entries[0].timestamp, entries[1].timestamp)
  }

  // 2. Границы периода: вне периода не попадает.
  func testFetch_respectsPeriodBounds() throws {
    let db = try openWriter()
    try writeEvent(db, tsMs: 5_000, payload: ghPush(branch: "in"))
    try writeEvent(db, tsMs: 20_000_000, payload: ghPush(branch: "out"))
    let entries = try makeQuery().fetch(period: period)
    XCTAssertEqual(entries.count, 1)
  }

  // 3. Skip-kinds (state pulses) дропаются маппером, в выдаче их нет.
  func testFetch_skipsPulseKinds() throws {
    let db = try openWriter()
    try writeEvent(db, tsMs: 1_000, payload: ghPush(branch: "real"))
    try writeEvent(
      db, tsMs: 2_000, signalType: .aiCollaboration, payload: ["event_kind": "claude_turn_ended"])
    let entries = try makeQuery().fetch(period: period)
    XCTAssertEqual(entries.count, 1)
  }

  // 4. Row cap: при rowCap+10 строках возвращается ≤ rowCap, newest сохранены.
  func testFetch_capsRows_keepsNewest() throws {
    let db = try openWriter()
    for i in 0..<(ActivityFeedQuery.rowCap + 10) {
      try writeEvent(db, tsMs: Int64(i + 1) * 1000, payload: ghPush(branch: "b\(i)"))
    }
    let entries = try makeQuery().fetch(period: period)
    XCTAssertLessThanOrEqual(entries.count, ActivityFeedQuery.rowCap)
    XCTAssertEqual(
      entries.first?.timestamp,
      Date(timeIntervalSince1970: TimeInterval(ActivityFeedQuery.rowCap + 10)))
  }

  // 5. Coalescing: подряд-дубликаты схлопываются (mergedCount).
  func testFetch_coalescesConsecutiveDuplicates() throws {
    let db = try openWriter()
    for i in 0..<3 {
      try writeEvent(db, tsMs: Int64(1_000 + i), payload: ghPush(branch: "same"))
    }
    let entries = try makeQuery().fetch(period: period)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.mergedCount, 3)
  }
}
