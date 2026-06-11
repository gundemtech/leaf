// Use-case rebuild Track A5 — capture-coverage report driving honest empty
// states ("Connect Slack" / "Add a repo folder") instead of silently empty
// Search/Brief surfaces.

import XCTest
import GRDB
@testable import LeafCore

final class MemoryCoverageReporterTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-coverage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeDB() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  private func connectProvider(_ db: LeafCore.Database, _ provider: String) throws {
    try db.writeSQL { rawDB in
      try rawDB.execute(sql: """
        INSERT INTO integrations
          (provider, workspace_id, workspace_name, access_token, scope, connected_at_ms, updated_ms)
        VALUES (?, 'ws', 'ws', 'tok', 'read', 1000, 1000)
        """, arguments: [provider])
    }
  }

  private func report(_ db: LeafCore.Database, nowMs: Int64 = 10_000_000) throws -> MemoryCoverageReport {
    try db.readSQL { rawDB in
      try MemoryCoverageReporter.report(lastDays: 30, nowMs: nowMs, in: rawDB)
    }
  }

  private func source(_ r: MemoryCoverageReport, _ name: String) -> MemoryCoverageReport.SourceCoverage? {
    r.sources.first { $0.source == name }
  }

  func testEmptyDatabase_NothingConnected_SuggestsActions() throws {
    let db = try makeDB()
    let r = try report(db)

    XCTAssertEqual(source(r, "slack")?.connected, false)
    XCTAssertEqual(source(r, "slack")?.suggestedAction, .connectProvider("slack"))
    XCTAssertEqual(source(r, "git_local")?.connected, false)
    XCTAssertEqual(source(r, "git_local")?.suggestedAction, .addWatchedRepoFolder)
    XCTAssertEqual(r.totalBodiesIndexed, 0)
  }

  func testConnectedProviderWithIndexedBodies_CountsThem() throws {
    let db = try makeDB()
    try connectProvider(db, "github")
    try db.write(RawEvent(
      timestamp: Date(timeIntervalSince1970: 9_000),
      signalType: .action,
      payload: ["event_kind": "gh_commit_pushed", "body": "fix: relay"]))

    let r = try report(db)
    let github = source(r, "github")
    XCTAssertEqual(github?.connected, true)
    XCTAssertEqual(github?.bodiesIndexed, 1)
    XCTAssertEqual(github?.lastEventTsMs, 9_000_000)
    XCTAssertNil(github?.suggestedAction)
    XCTAssertEqual(r.totalBodiesIndexed, 1)
  }

  func testGitLocal_ConnectedWhenPollingCursorExists() throws {
    let db = try makeDB()
    try db.writeOffset(CollectorOffset(
      collectorID: GitLogCollector.collectorID, sourceID: "/tmp/repo",
      byteOffset: 0, inode: nil, size: 0, lastModifiedMs: 1, updatedMs: 1))
    try db.write(RawEvent(
      timestamp: Date(timeIntervalSince1970: 9_500),
      signalType: .action,
      payload: ["event_kind": "git_commit_authored", "body": "feat: thing", "repo": "a/b", "sha": "x"]))

    let r = try report(db)
    XCTAssertEqual(source(r, "git_local")?.connected, true)
    XCTAssertEqual(source(r, "git_local")?.bodiesIndexed, 1)
    XCTAssertNil(source(r, "git_local")?.suggestedAction)
  }

  func testWindow_ExcludesOldBodies() throws {
    let db = try makeDB()
    try connectProvider(db, "linear")
    // 40 days before "now" (now = 10_000_000s → 10_000_000_000 ms).
    try db.write(RawEvent(
      timestamp: Date(timeIntervalSince1970: 10_000_000 - 40 * 86_400),
      signalType: .action,
      payload: ["event_kind": "issue_updated", "body": "old desc"]))

    let r = try report(db, nowMs: 10_000_000_000)
    XCTAssertEqual(source(r, "linear")?.bodiesIndexed, 0, "30-day window must exclude older bodies")
    XCTAssertNotNil(source(r, "linear")?.lastEventTsMs, "lastEventTs is window-independent")
  }

  func testRepoSuggestions_FromGitHubActivityNotYetPolledLocally() throws {
    let db = try makeDB()
    try db.write(RawEvent(signalType: .action, payload: [
      "event_kind": "gh_commit_pushed", "repo": "acme/widget", "body": "x",
    ]))
    try db.write(RawEvent(signalType: .action, payload: [
      "event_kind": "gh_pr_merged", "repo": "acme/gadget", "body": "y",
    ]))

    let r = try report(db)
    XCTAssertEqual(Set(r.suggestedRepos), ["acme/widget", "acme/gadget"],
                   "repos seen in GitHub activity but not locally polled → suggestions")
  }
}
