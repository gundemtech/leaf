import Foundation
import GRDB
import os

/// Use-case rebuild Track A0 — discovers the workspace's Linear team prefixes
/// ("GUN", "LEA", …) from payload values already captured in `events`, so that
/// `LinearIDExtractor` / branch-name derivation get a real whitelist instead of
/// the historical hardcoded empty set.
///
/// Sources scanned: `issue_key` (LinearCollector self-authored labels) and
/// `linked_linear_id` (cross-provider attributions). Values must match the
/// extractor's ref shape (`[A-Z][A-Z0-9]{1,4}-\d+`); the prefix is the part
/// before the dash.
///
/// Results are cached for `ttlSeconds` — collectors call `prefixes()` on every
/// write tick. Query failures degrade to the last known set (never throw into
/// the write path).
public final class LinearPrefixSource: @unchecked Sendable {
  private let database: Database
  private let ttlSeconds: TimeInterval
  private let now: @Sendable () -> Date
  private let log = Logger(subsystem: "tech.gundem.leaf.core", category: "linear-prefixes")

  private struct Cache {
    var prefixes: Set<String>
    var fetchedAt: Date
  }

  private let cache = OSAllocatedUnfairLock<Cache?>(initialState: nil)

  public init(
    database: Database,
    ttlSeconds: TimeInterval = 600,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.database = database
    self.ttlSeconds = ttlSeconds
    self.now = now
  }

  public func prefixes() -> Set<String> {
    let current = now()
    if let cached = cache.withLock({ $0 }),
       current.timeIntervalSince(cached.fetchedAt) < ttlSeconds {
      return cached.prefixes
    }

    do {
      let fresh = try fetchPrefixes()
      cache.withLock { $0 = Cache(prefixes: fresh, fetchedAt: current) }
      return fresh
    } catch {
      log.error("prefix refresh failed: \(String(describing: error), privacy: .public)")
      return cache.withLock { $0 }?.prefixes ?? []
    }
  }

  private func fetchPrefixes() throws -> Set<String> {
    let refs: [String] = try database.readSQL { rawDB in
      var out: [String] = []
      for key in ["issue_key", "linked_linear_id"] {
        out += try String.fetchAll(rawDB, sql: """
          SELECT DISTINCT json_extract(payload_json, '$.\(key)')
            FROM events
           WHERE json_extract(payload_json, '$.\(key)') IS NOT NULL
           ORDER BY id DESC LIMIT 5000
          """)
      }
      return out
    }
    return Set(refs.compactMap(Self.prefix(fromRef:)))
  }

  /// "GUN-12" → "GUN"; rejects anything not matching the extractor ref shape.
  static func prefix(fromRef ref: String) -> String? {
    guard let dash = ref.firstIndex(of: "-") else { return nil }
    let head = String(ref[ref.startIndex..<dash])
    let tail = String(ref[ref.index(after: dash)...])
    guard (2...5).contains(head.count),
          let first = head.first, first.isUppercase, first.isLetter,
          head.allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber }),
          !tail.isEmpty, tail.allSatisfy(\.isNumber)
    else { return nil }
    return head
  }
}
