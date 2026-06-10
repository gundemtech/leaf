import Foundation
import GRDB

/// AI-UI-2 — единственный DB-read для Activity Raw events + кандидатов
/// escalation-модалки. Reader-safe; строки идут через ActivityFeedMapper
/// (ADR-010 allowlist) и coalesceConsecutive. Newest-first, cap rowCap.
public struct ActivityFeedQuery: Sendable {
  public static let rowCap = 500

  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?

  public init(dbURL: URL, dbConfig: DatabaseConfig, dbEncryption: EncryptionOptions?) {
    self.dbURL = dbURL
    self.dbConfig = dbConfig
    self.dbEncryption = dbEncryption
  }

  public func fetch(period: DateInterval) throws -> [ActivityFeedEntry] {
    let startMs = Int64(period.start.timeIntervalSince1970 * 1000)
    let endMs = Int64(period.end.timeIntervalSince1970 * 1000)
    let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
    let mapped: [ActivityFeedEntry] = try db.readSQL { rawDB in
      let rows = try Row.fetchAll(
        rawDB,
        sql: """
          SELECT id, ts, signal_type, bundle_id, payload_json
            FROM events
           WHERE ts BETWEEN ? AND ?
           ORDER BY ts DESC
           LIMIT ?
          """,
        arguments: [startMs, endMs, Self.rowCap])
      return rows.compactMap { row in
        ActivityFeedMapper.map(
          id: row["id"] ?? 0,
          timestampMs: row["ts"] ?? 0,
          signalType: (row["signal_type"] as String?) ?? "",
          bundleID: row["bundle_id"],
          payloadJSON: (row["payload_json"] as String?) ?? "{}")
      }
    }
    return ActivityFeedEntry.coalesceConsecutive(mapped)
  }
}
