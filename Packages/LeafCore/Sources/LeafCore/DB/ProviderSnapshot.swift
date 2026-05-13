import Foundation

/// Phase Track-3 D1 — single row of `provider_snapshots`. snapshot_json is a
/// freeform UTF-8 string (caller owns the JSON shape per snapshot_kind);
/// `ProviderSnapshotsStore` does NOT validate JSON structure.
public struct ProviderSnapshot: Codable, Sendable, Hashable {
    public let provider: String
    public let snapshotKind: String
    public let snapshotJSON: String
    public let capturedAtMs: Int64

    public init(provider: String, snapshotKind: String, snapshotJSON: String, capturedAtMs: Int64) {
        self.provider = provider
        self.snapshotKind = snapshotKind
        self.snapshotJSON = snapshotJSON
        self.capturedAtMs = capturedAtMs
    }
}
