import Foundation
import GRDB

/// Phase Track-6 P2 — per-DerivedData-hash mtime cursor. Spec §4.5.
///
/// One entry per Xcode-mint DerivedData directory hash (e.g.
/// `Leaf-dqqvphprbvvfkxabaugkymigacwk`). The cursor tracks the maximum mtime
/// of any xcresult bundle in that hash's `Logs/{Test,Launch}/` subtree that
/// the watcher has already seen. Used to suppress historical bundle replay on
/// Agent cold start.
public protocol DerivedDataCursor: Sendable {
    func lastSeenMtimeMs(forHash hash: String) async -> Int64?
    func setLastSeenMtimeMs(_ ms: Int64, forHash hash: String) async
    func allKnownHashes() async -> [String]
}

/// Single-row backed cursor stored in `provider_snapshots` table (M015).
/// Provider key: `xcode_derived_data`; snapshot_kind: `cursor`.
/// JSON shape: `{"hashes": {"<hash>": <mtimeMs>, ...}}`.
///
/// All hashes' cursors live in ONE row — atomic update on every advance.
/// No new migration is required; the row is upserted on first write.
public actor ProviderSnapshotsDerivedDataCursor: DerivedDataCursor {
    private static let provider = "xcode_derived_data"
    private static let snapshotKind = "cursor"

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Decode `{"hashes": {hash: mtimeMs, ...}}` from the snapshot JSON. The
    /// envelope decoder is tolerant of Int64 / Int / Double representations
    /// (GRDB → JSONSerialization may pick any depending on the round-trip).
    private static func decode(_ snapshot: ProviderSnapshot?) -> [String: Int64] {
        guard let snapshot,
            let data = snapshot.snapshotJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hashes = obj["hashes"] as? [String: Any]
        else {
            return [:]
        }
        return hashes.compactMapValues { value -> Int64? in
            if let i = value as? Int64 { return i }
            if let i = value as? Int { return Int64(i) }
            if let d = value as? Double { return Int64(d) }
            return nil
        }
    }

    private static func encode(_ map: [String: Int64], nowMs: Int64) -> ProviderSnapshot? {
        let envelope: [String: Any] = [
            "hashes": map.mapValues { Int($0) }
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return ProviderSnapshot(
            provider: provider,
            snapshotKind: snapshotKind,
            snapshotJSON: json,
            capturedAtMs: nowMs
        )
    }

    public func lastSeenMtimeMs(forHash hash: String) async -> Int64? {
        let snapshot =
            (try? database.readSQL { raw in
                try ProviderSnapshotsStore.read(
                    provider: Self.provider,
                    snapshotKind: Self.snapshotKind,
                    in: raw
                )
            })
        return Self.decode(snapshot)[hash]
    }

    /// Atomic read-modify-write inside a single `writeSQL { }` transaction.
    /// If a concurrent writer (e.g. another component) upserted between our
    /// load and write, this would clobber theirs — but the transaction here
    /// merges OUR new value into THEIR latest state read inside the same
    /// transaction, so the only loss is if their write races us within the
    /// same transaction (impossible under GRDB's write-serialized pool).
    public func setLastSeenMtimeMs(_ ms: Int64, forHash hash: String) async {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try? database.writeSQL { raw in
            // Re-read the current envelope INSIDE the write transaction so
            // we merge against the latest persisted state — not a stale
            // cached load that may have raced with another writer.
            let current = try ProviderSnapshotsStore.read(
                provider: Self.provider,
                snapshotKind: Self.snapshotKind,
                in: raw
            )
            var map = Self.decode(current)
            map[hash] = ms
            guard let snapshot = Self.encode(map, nowMs: nowMs) else { return }
            try ProviderSnapshotsStore.upsert(snapshot, in: raw)
        }
    }

    public func allKnownHashes() async -> [String] {
        let snapshot =
            (try? database.readSQL { raw in
                try ProviderSnapshotsStore.read(
                    provider: Self.provider,
                    snapshotKind: Self.snapshotKind,
                    in: raw
                )
            })
        return Array(Self.decode(snapshot).keys)
    }
}
