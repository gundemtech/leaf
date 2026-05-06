import Foundation

/// Phase 5.3.D — pending rotation blob row in `rotation_outbox`. Composite
/// identity `(peerPubkeyHex, newKeyID)` matches relay's idempotency key (5.3.C).
/// `postedAtMs == nil` means the blob has not yet been successfully POSTed to
/// the relay; `KeyRotationService.resumePendingPosts()` retries on next launch.
public struct RotationOutboxRow: Sendable, Hashable {
    public let peerPubkeyHex: String
    public let newKeyID: String
    public let priorKeyID: String
    public let kind: RotationKind
    public let peerMemberID: String
    public let blob: Data
    public let expiresAtMs: Int64
    public let createdAtMs: Int64
    public let postedAtMs: Int64?

    public init(
        peerPubkeyHex: String,
        newKeyID: String,
        priorKeyID: String,
        kind: RotationKind,
        peerMemberID: String,
        blob: Data,
        expiresAtMs: Int64,
        createdAtMs: Int64,
        postedAtMs: Int64?
    ) {
        self.peerPubkeyHex = peerPubkeyHex
        self.newKeyID = newKeyID
        self.priorKeyID = priorKeyID
        self.kind = kind
        self.peerMemberID = peerMemberID
        self.blob = blob
        self.expiresAtMs = expiresAtMs
        self.createdAtMs = createdAtMs
        self.postedAtMs = postedAtMs
    }
}
