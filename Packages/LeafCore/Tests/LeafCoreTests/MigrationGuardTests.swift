import XCTest
import GRDB
@testable import LeafCore

/// Ph C migration-guard — a DB carrying migration identifiers this binary does
/// not know (written by a newer Leaf build) must be detected on open and throw
/// `LeafError.databaseSchemaFromFuture`, NOT silently migrate/serve nor crash.
/// Covers both the writer path (Agent / app) and the reader path (MCP tools).
final class MigrationGuardTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-migration-guard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  /// Migrate a fresh DB to the current schema, then inject a migration identifier
  /// the binary does not register — simulating a DB written by a newer build.
  private func makeFutureSchemaDB() throws -> URL {
    let url = tempDir.appendingPathComponent("events.sqlite")
    do {
      let db = try Database.openForWrite(at: url, config: .weakDefaults, encryption: .deterministicTest)
      try db.pool.write { rawDB in
        try rawDB.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('999_from_future')")
      }
    }  // release the writer pool before reopening
    return url
  }

  func testOpenForWriteThrowsOnFutureSchema() throws {
    let url = try makeFutureSchemaDB()
    XCTAssertThrowsError(
      try Database.openForWrite(at: url, config: .weakDefaults, encryption: .deterministicTest)
    ) { error in
      guard case LeafError.databaseSchemaFromFuture(let unknown) = error else {
        return XCTFail("expected databaseSchemaFromFuture, got \(error)")
      }
      XCTAssertEqual(unknown, ["999_from_future"])
    }
  }

  func testOpenForReadThrowsOnFutureSchema() throws {
    let url = try makeFutureSchemaDB()
    XCTAssertThrowsError(
      try Database.openForRead(at: url, config: .weakDefaults, encryption: .deterministicTest)
    ) { error in
      guard case LeafError.databaseSchemaFromFuture = error else {
        return XCTFail("expected databaseSchemaFromFuture, got \(error)")
      }
    }
  }

  /// No regression: a current-schema DB opens cleanly for both write and read.
  func testCurrentSchemaOpensWithoutError() throws {
    let url = tempDir.appendingPathComponent("events.sqlite")
    _ = try Database.openForWrite(at: url, config: .weakDefaults, encryption: .deterministicTest)
    _ = try Database.openForWrite(at: url, config: .weakDefaults, encryption: .deterministicTest)
    _ = try Database.openForRead(at: url, config: .weakDefaults, encryption: .deterministicTest)
  }
}
