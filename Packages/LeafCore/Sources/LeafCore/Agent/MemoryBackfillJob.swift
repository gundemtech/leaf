import Foundation
import GRDB
import os

/// Use-case rebuild Track A2 — one-shot, resumable repair sweep over historical
/// events: FTS indexing + link derivation for every row written before the D2
/// wiring existed (or through the since-fixed `writeEventsAndOffset` bypass).
///
/// A JOB, not a migration: months of JSON decoding inside `migrate()` would
/// block Agent startup AND the reader processes' schema guard. Instead the
/// Agent fires `runToCompletion()` after collectors start; the sweep walks
/// `events` in id order in small batches, yielding between batches so the
/// writer stays responsive.
///
/// Cursor: `collector_offsets(collectorID: "memory_backfill", sourceID:
/// <sweepVersion>)`, `byteOffset` = last processed event id. Versioned
/// sourceID — bumping `sweepVersion` (when dispatch tables learn new kinds)
/// starts a fresh sweep; the per-event guards below make any re-scan safe:
///   - FTS: `EventsFullTextStore.hasIndexedRows` (contentless FTS5 is
///     append-only — the meta-table guard is the only dedup);
///   - links: composite-PK `INSERT OR IGNORE` inside `deriveLinks`.
public actor MemoryBackfillJob {

  public static let collectorID = "memory_backfill"
  /// Bump when FTS/link dispatch tables learn new event kinds and historical
  /// rows should be re-swept (per-event guards keep re-sweeps idempotent).
  public static let sweepVersion = "events_v1"

  /// Track A3 — detector kinds replayed over history (phase B). Blockers are
  /// deliberately NOT replayed: re-detecting an old "blocked on X" body would
  /// resurrect an already-resolved blocker (uniqueness only covers OPEN rows).
  private static let replayedDetectorKinds = [
    Schema.DetectorKinds.decision,
    Schema.DetectorKinds.openQuestion,
  ]

  private let database: Database
  private let batchSize: Int
  private let interBatchDelaySec: TimeInterval
  private let linearPrefixes: @Sendable () -> Set<String>
  private let derivers: LinkDerivers
  private let detectorMoat: DetectorMoat
  private let logger: Logger

  public init(
    database: Database,
    batchSize: Int = 500,
    interBatchDelaySec: TimeInterval = 0.25,
    linearPrefixes: @escaping @Sendable () -> Set<String>,
    derivers: LinkDerivers,
    detectorMoat: DetectorMoat = .publicSubstrate,
    logger: Logger = Logger(subsystem: "tech.gundem.leaf.core", category: "backfill")
  ) {
    self.database = database
    self.batchSize = max(1, batchSize)
    self.interBatchDelaySec = interBatchDelaySec
    self.linearPrefixes = linearPrefixes
    self.derivers = derivers
    self.detectorMoat = detectorMoat
    self.logger = logger
  }

  /// Phase A walks `[cursor+1, maxIDAtStart]` (FTS + links), phase B replays
  /// the decision / open-question detectors over already-scanned history.
  /// Safe to call on every Agent launch — finished sweeps are cursor-read
  /// no-ops.
  public func runToCompletion() async {
    await runIndexSweep()
    await runDetectorReplay()
  }

  // MARK: - Phase A — FTS + links

  private func runIndexSweep() async {
    let startCursor = readCursor(sourceID: Self.sweepVersion)
    guard let maxID = currentMaxEventID() else { return }
    if startCursor >= maxID { return }

    logger.info("MemoryBackfillJob sweep \(Self.sweepVersion, privacy: .public): events \(startCursor + 1)...\(maxID)")
    var cursor = startCursor
    var processed = 0

    while cursor < maxID, !Task.isCancelled {
      let batchEnd = min(cursor + Int64(batchSize), maxID)
      do {
        processed += try processBatch(afterID: cursor, throughID: batchEnd)
        cursor = batchEnd
        try persistCursor(cursor, sourceID: Self.sweepVersion)
      } catch {
        // Cursor not advanced — next launch retries this batch.
        logger.error("MemoryBackfillJob batch failed at id \(cursor): \(String(describing: error), privacy: .public)")
        return
      }
      if interBatchDelaySec > 0 {
        try? await Task.sleep(nanoseconds: UInt64(interBatchDelaySec * 1_000_000_000))
      }
    }

    logger.info("MemoryBackfillJob sweep complete: \(processed, privacy: .public) events repaired")
  }

  // MARK: - Phase B — detector replay (Track A3)

  private func runDetectorReplay() async {
    for kind in Self.replayedDetectorKinds {
      guard !Task.isCancelled else { return }
      await replayDetector(kind: kind)
    }
  }

  private func replayDetector(kind: String) async {
    // Replay covers [0, live cursor at start] — everything above the live
    // cursor is the periodic incremental pass's territory.
    guard let liveCursor = try? database.readSQL({ rawDB in
      try DetectorOffsetsStore.cursor(detectorKind: kind, in: rawDB)
    }), liveCursor > 0 else { return }

    let sourceID = "\(Self.sweepVersion)_det_\(kind)"
    var cursor = readCursor(sourceID: sourceID)
    if cursor >= liveCursor { return }

    logger.info("MemoryBackfillJob detector replay \(kind, privacy: .public): events \(cursor + 1)...\(liveCursor)")
    let prefixes = linearPrefixes()
    let moat = detectorMoat
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    while cursor < liveCursor, !Task.isCancelled {
      let batchEnd = min(cursor + Int64(batchSize), liveCursor)
      do {
        try database.writeSQL { rawDB in
          _ = try DetectorPipeline.runRange(
            kind: kind, moat: moat, nowMs: nowMs,
            linearPrefixes: prefixes,
            fromID: cursor, toID: batchEnd, in: rawDB)
        }
        cursor = batchEnd
        try persistCursor(cursor, sourceID: sourceID)
      } catch {
        logger.error("MemoryBackfillJob detector replay \(kind, privacy: .public) failed at id \(cursor): \(String(describing: error), privacy: .public)")
        return
      }
      if interBatchDelaySec > 0 {
        try? await Task.sleep(nanoseconds: UInt64(interBatchDelaySec * 1_000_000_000))
      }
    }
  }

  // MARK: - Batch

  /// One transaction: index + derive for every event in `(afterID, throughID]`
  /// that has no FTS rows yet. Returns the number of repaired events.
  private func processBatch(afterID: Int64, throughID: Int64) throws -> Int {
    let prefixes = linearPrefixes()
    let derivers = self.derivers
    return try database.writeSQL { rawDB -> Int in
      let rows = try Row.fetchAll(rawDB, sql: """
        SELECT id, ts, signal_type, bundle_id, payload_json
          FROM events WHERE id > ? AND id <= ? ORDER BY id ASC
        """, arguments: [afterID, throughID])

      var repaired = 0
      for row in rows {
        let eventID: Int64 = row["id"]
        guard !(try EventsFullTextStore.hasIndexedRows(eventID: eventID, in: rawDB)) else {
          continue
        }
        let payloadJSON: String = (row["payload_json"] as String?) ?? "{}"
        guard let data = payloadJSON.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { continue }

        try EventsFullTextStore.indexEvent(
          eventID: eventID,
          signalType: row["signal_type"],
          bundleID: row["bundle_id"],
          payload: payload,
          in: rawDB
        )
        try EventLinksStore.deriveLinks(
          eventID: eventID,
          ts: row["ts"],
          payload: payload,
          knownLinearPrefixes: prefixes,
          derivers: derivers,
          in: rawDB
        )
        repaired += 1
      }
      return repaired
    }
  }

  // MARK: - Cursor

  private func readCursor(sourceID: String) -> Int64 {
    (try? database.readOffset(collectorID: Self.collectorID, sourceID: sourceID))?
      .map(\.byteOffset) ?? 0
  }

  private func persistCursor(_ eventID: Int64, sourceID: String) throws {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    try database.writeOffset(CollectorOffset(
      collectorID: Self.collectorID,
      sourceID: sourceID,
      byteOffset: eventID,
      inode: nil,
      size: 0,
      lastModifiedMs: nowMs,
      updatedMs: nowMs
    ))
  }

  private func currentMaxEventID() -> Int64? {
    try? database.readSQL { rawDB in
      try Int64.fetchOne(rawDB, sql: "SELECT MAX(id) FROM events")
    }
  }
}
