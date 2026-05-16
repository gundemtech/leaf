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

    private func loadMap() async -> [String: Int64] {
        let snapshot: ProviderSnapshot? = (try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: Self.provider,
                snapshotKind: Self.snapshotKind,
                in: raw
            )
        }) ?? nil
        guard let snapshot,
              let data = snapshot.snapshotJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hashes = obj["hashes"] as? [String: Any] else {
            return [:]
        }
        return hashes.compactMapValues { value -> Int64? in
            if let i = value as? Int64 { return i }
            if let i = value as? Int { return Int64(i) }
            if let d = value as? Double { return Int64(d) }
            return nil
        }
    }

    private func persist(_ map: [String: Int64]) async {
        let envelope: [String: Any] = [
            "hashes": map.mapValues { Int($0) }
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let snapshot = ProviderSnapshot(
            provider: Self.provider,
            snapshotKind: Self.snapshotKind,
            snapshotJSON: json,
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try? database.writeSQL { raw in
            try ProviderSnapshotsStore.upsert(snapshot, in: raw)
        }
    }

    public func lastSeenMtimeMs(forHash hash: String) async -> Int64? {
        await loadMap()[hash]
    }

    public func setLastSeenMtimeMs(_ ms: Int64, forHash hash: String) async {
        var map = await loadMap()
        map[hash] = ms
        await persist(map)
    }

    public func allKnownHashes() async -> [String] {
        Array(await loadMap().keys)
    }
}

