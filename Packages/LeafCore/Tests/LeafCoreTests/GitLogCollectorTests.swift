// Use-case rebuild Track A1 — GitLogCollector tick behavior over a fake reader.
//
// The reader subprocess shape is moat (LeafCorePrivateTests covers
// ProdGitCommitLogReader against fixture repos); these tests cover repo
// discovery in watched folders, per-repo cursors, dedup on re-poll, payload
// shape, and that emitted commits land in FTS (write path = A0-fixed
// writeEventsAndOffset).

import XCTest
import GRDB
@testable import LeafCore

final class GitLogCollectorTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-gitlog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Fixtures

  private actor FakeReader: GitCommitLogReading {
    private(set) var calls: [(repoPath: String, sinceMs: Int64?)] = []
    private var commitsByRepo: [String: [GitCommitRecord]] = [:]

    func setCommits(_ commits: [GitCommitRecord], forRepoSuffix suffix: String) {
      commitsByRepo[suffix] = commits
    }

    func recordedCalls() -> [(repoPath: String, sinceMs: Int64?)] { calls }

    func selfAuthoredCommits(
      repoPath: String, sinceMs: Int64?, limit: Int
    ) async -> [GitCommitRecord] {
      calls.append((repoPath, sinceMs))
      let all = commitsByRepo.first { repoPath.hasSuffix($0.key) }?.value ?? []
      return all.filter { sinceMs == nil || $0.committedAtMs > sinceMs! }
    }
  }

  private func makeDB() throws -> LeafCore.Database {
    try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
  }

  /// Creates a folder (optionally with a `.git` marker dir) and registers it
  /// as an enabled watched folder.
  @discardableResult
  private func addWatchedFolder(
    _ db: LeafCore.Database, name: String, isRepo: Bool, enabled: Bool = true,
    childRepos: [String] = []
  ) throws -> URL {
    let folder = tempDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if isRepo {
      try FileManager.default.createDirectory(
        at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    for child in childRepos {
      let childDir = folder.appendingPathComponent(child).appendingPathComponent(".git")
      try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
    }
    try db.addWatchedFolder(WatchedFolder(
      id: UUID().uuidString, path: folder.path, maxGranularity: .L4,
      enabled: enabled, addedAt: Date(), updatedAt: Date()
    ))
    return folder
  }

  private func commit(
    sha: String, subject: String, body: String? = nil, tsMs: Int64,
    branch: String? = "dev", remote: GitRemoteRef? = GitRemoteRef(host: "github.com", owner: "acme", repo: "widget")
  ) -> GitCommitRecord {
    GitCommitRecord(sha: sha, subject: subject, body: body,
                    committedAtMs: tsMs, branch: branch, remote: remote)
  }

  private func makeCollector(_ db: LeafCore.Database, reader: FakeReader) -> GitLogCollector {
    GitLogCollector(database: db, reader: reader, pollIntervalSec: 9999)
  }

  private func commitEventPayloads(_ db: LeafCore.Database) throws -> [[String: String]] {
    try db.readSQL { rawDB in
      let rows = try String.fetchAll(rawDB, sql: """
        SELECT payload_json FROM events
         WHERE json_extract(payload_json, '$.event_kind') = 'git_commit_authored'
         ORDER BY ts ASC
        """)
      return rows.compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String]
      }
    }
  }

  // MARK: - Tests

  func testTick_EmitsCommitEventsWithPayloadAndCursor() async throws {
    let db = try makeDB()
    try addWatchedFolder(db, name: "widget", isRepo: true)
    let reader = FakeReader()
    await reader.setCommits([
      commit(sha: "aaa1111", subject: "feat: relay reconnect", body: "Long body", tsMs: 2_000),
      commit(sha: "bbb2222", subject: "fix: WAL checkpoint", tsMs: 5_000),
    ], forRepoSuffix: "widget")

    await makeCollector(db, reader: reader).tick()

    let payloads = try commitEventPayloads(db)
    XCTAssertEqual(payloads.count, 2)
    XCTAssertEqual(payloads[0]["repo"], "acme/widget")
    XCTAssertEqual(payloads[0]["branch"], "dev")
    XCTAssertEqual(payloads[0]["sha"], "aaa1111")
    XCTAssertEqual(payloads[0]["body"], "feat: relay reconnect\n\nLong body")
    XCTAssertEqual(payloads[0]["source"], "git_local")
    XCTAssertEqual(payloads[1]["body"], "fix: WAL checkpoint")

    let offsets = try db.listOffsets(collectorID: "git_log_polling")
    XCTAssertEqual(offsets.count, 1)
    XCTAssertEqual(offsets[0].lastModifiedMs, 5_000)
    XCTAssertTrue(offsets[0].sourceID.hasSuffix("widget"))
  }

  func testSecondTick_PassesCursorAndSkipsKnownCommits() async throws {
    let db = try makeDB()
    try addWatchedFolder(db, name: "widget", isRepo: true)
    let reader = FakeReader()
    await reader.setCommits([commit(sha: "aaa", subject: "one", tsMs: 2_000)], forRepoSuffix: "widget")
    let collector = makeCollector(db, reader: reader)

    await collector.tick()
    await collector.tick()

    XCTAssertEqual(try commitEventPayloads(db).count, 1, "re-poll must not duplicate")
    let calls = await reader.recordedCalls()
    XCTAssertEqual(calls.count, 2)
    XCTAssertNil(calls[0].sinceMs)
    XCTAssertEqual(calls[1].sinceMs, 2_000)
  }

  func testDiscovery_FindsOneLevelChildReposAndSkipsDisabled() async throws {
    let db = try makeDB()
    try addWatchedFolder(db, name: "projects", isRepo: false, childRepos: ["alpha", "beta"])
    try addWatchedFolder(db, name: "off", isRepo: true, enabled: false)
    let reader = FakeReader()

    await makeCollector(db, reader: reader).tick()

    let called = Set(await reader.recordedCalls().map { ($0.repoPath as NSString).lastPathComponent })
    XCTAssertEqual(called, ["alpha", "beta"], "child repos discovered; disabled folder skipped")
  }

  func testEmittedCommits_AreFTSSearchable() async throws {
    let db = try makeDB()
    try addWatchedFolder(db, name: "widget", isRepo: true)
    let reader = FakeReader()
    await reader.setCommits(
      [commit(sha: "ccc", subject: "decide: switch to SQLCipher for storage", tsMs: 3_000)],
      forRepoSuffix: "widget")

    await makeCollector(db, reader: reader).tick()

    let matches = try db.readSQL { rawDB in
      try EventsFullTextStore.search(query: "SQLCipher", period: 0...10_000, limit: 10, in: rawDB)
    }
    XCTAssertEqual(matches.count, 1, "git_commit_authored bodies must land in FTS")
  }

  func testRepoWithoutRemote_FallsBackToFolderName() async throws {
    let db = try makeDB()
    try addWatchedFolder(db, name: "scratchpad", isRepo: true)
    let reader = FakeReader()
    await reader.setCommits(
      [commit(sha: "ddd", subject: "wip", tsMs: 1_000, remote: nil)],
      forRepoSuffix: "scratchpad")

    await makeCollector(db, reader: reader).tick()

    XCTAssertEqual(try commitEventPayloads(db).first?["repo"], "scratchpad")
  }
}
