import CryptoKit
import Foundation
import Security

/// Phase Track-5 S2 — multi-workspace domain service (replaces single-org
/// OrgService). One Mac device = N workspaces; each has independent teamKey
/// material. Identity X25519 is device-scoped (shared across workspaces).
///
/// Mirrors OrgService orchestration pattern (5.1.D):
/// - Keystore-first, DB-second ordering (orphan file < orphan row)
/// - Injectable factories (`now` / `randomBytes` / `randomUUID` / `identity`)
///   for deterministic test round-trips
/// - Atomic rows: `workspaces` + `team_members(self admin)` +
///   `team_keys(initial)` written sequentially
///
/// `markLeft` + `rejoin` land in Task 11 (OQ-T5-2 resolution).
public struct WorkspaceService: Sendable {
    private let database: Database
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) throws -> Data
    private let randomUUID: @Sendable () -> String
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) throws -> Data = WorkspaceService.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.randomBytes = randomBytes
        self.randomUUID = randomUUID
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    /// Creates a brand-new workspace. Generates `workspaces` row +
    /// `team_members(self admin)` row + initial `team_keys` row, plus the
    /// keystore file at `<root>/workspaces/<wid>/team-keys/<keyID>.key`.
    /// Identity X25519 is reused across workspaces on the same device.
    ///
    /// Throws:
    /// - `.invalidPayload` if `displayName` empty after trim
    /// - `.keyFileUnavailable` on keystore write failure
    /// - Propagates any `Database` error
    public func createWorkspace(displayName: String) throws -> Workspace {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LeafError.invalidPayload }

        let selfMemberID = randomUUID()
        let workspaceID = randomUUID()
        let teamKeyID = randomUUID()

        let privKey = try identity()
        let teamKeyBytes = try randomBytes(TeamKeystore.teamKeyLength)

        // Keystore-first (orphan file < orphan row).
        try TeamKeystore.writeTeamKey(
            teamKeyBytes,
            workspaceID: workspaceID,
            keyID: teamKeyID,
            at: keystoreRoot
        )

        let pubkeyHex = privKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let nowDate = now()

        let member = TeamMember(
            id: selfMemberID,
            workspaceID: workspaceID,
            role: .admin,
            pubkeyHex: pubkeyHex,
            displayName: trimmed,
            addedAt: nowDate,
            removedAt: nil
        )
        let workspace = Workspace(
            id: workspaceID,
            name: trimmed,
            createdAt: nowDate,
            createdByMemberID: selfMemberID,
            leftAt: nil
        )
        let teamKey = TeamKey(
            id: teamKeyID,
            workspaceID: workspaceID,
            generatedAt: nowDate,
            deprecatedAt: nil,
            generatedByMemberID: selfMemberID
        )

        try database.upsertWorkspace(workspace)
        try database.insertTeamMember(member)
        try database.insertTeamKey(teamKey)

        return workspace
    }

    /// Returns workspace row by id, or nil if not found.
    public func readWorkspace(id: String) throws -> Workspace? {
        try database.readWorkspace(id: id)
    }

    /// Returns all workspaces ordered by `created_at_ms` ASC. `includeLeft`
    /// = false (default) filters out soft-marked rows where
    /// `left_at_ms IS NOT NULL`.
    public func listWorkspaces(includeLeft: Bool = false) throws -> [Workspace] {
        try database.listWorkspaces(includeLeft: includeLeft)
    }

    // MARK: - markLeft / rejoin (OQ-T5-2 resolution)

    /// Soft-marks a workspace as left. Sets `workspaces.left_at_ms = at`.
    /// Idempotent re-call on already-left rows preserves the original
    /// timestamp (silent no-op). Throws `LeafError.invalidPayload` if the
    /// workspace doesn't exist. Data is preserved per OQ-T5-2 resolution;
    /// the team_keys rows stay forever-retained for history decryption.
    /// Hard-wipe ("Wipe workspace data") is an opt-in Settings action
    /// deferred to S8 — separate from this soft-mark.
    public func markLeft(workspaceID: String, at: Date) throws {
        try database.markWorkspaceLeft(workspaceID: workspaceID, at: at)
    }

    /// Clears `workspaces.left_at_ms`. Used by `InviteAcceptService`'s
    /// rejoin path (existing left workspace receives a fresh invite —
    /// re-activate instead of creating a duplicate row). No-op if the
    /// workspace is already active или missing.
    public func rejoin(workspaceID: String) throws {
        try database.clearWorkspaceLeftAt(workspaceID: workspaceID)
    }

    /// Default `randomBytes` factory: `SecRandomCopyBytes` под the hood.
    /// Mirrors `OrgService.secureRandom`.
    public static func secureRandom(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw LeafError.keychainUnavailable(status)
        }
        return bytes
    }
}
