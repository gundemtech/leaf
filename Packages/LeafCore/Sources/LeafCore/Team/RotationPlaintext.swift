import Foundation

/// JSON-encoded plaintext sealed внутри `RotationBlob` (Phase 5.3.B).
///
/// Wire shape — spec §3.3 (snake_case keys). Single struct с `kind` discriminator
/// (`.rotation` | `.tombstone`) — keeps blob shape uniform; cross-field invariants
/// validated post-decrypt by `ProdRotationBlobCodec.decode`.
///
/// `newTeamKeyBase64` carries raw 32B AES-256 team_key as base64 string for
/// `.rotation`; empty string для `.tombstone`. Caller decodes на boundary.
public struct RotationPlaintext: Sendable, Hashable, Codable {
    public let kind: RotationKind
    public let newTeamKeyBase64: String
    public let newKeyID: String
    public let priorKeyID: String
    public let generatedAtMs: Int64
    public let removedMemberID: String?

    public init(
        kind: RotationKind,
        newTeamKeyBase64: String,
        newKeyID: String,
        priorKeyID: String,
        generatedAtMs: Int64,
        removedMemberID: String?
    ) {
        self.kind = kind
        self.newTeamKeyBase64 = newTeamKeyBase64
        self.newKeyID = newKeyID
        self.priorKeyID = priorKeyID
        self.generatedAtMs = generatedAtMs
        self.removedMemberID = removedMemberID
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case newTeamKeyBase64 = "new_team_key"
        case newKeyID = "new_key_id"
        case priorKeyID = "prior_key_id"
        case generatedAtMs = "generated_at_ms"
        case removedMemberID = "removed_member_id"
    }
}

public enum RotationKind: String, Sendable, Hashable, Codable {
    case rotation
    case tombstone
}
