import CryptoKit
import Foundation
import Security

/// Phase 5.1.D — domain service для создания personal-org (single-org-per-device,
/// contract §4). Оркестрирует random ID/key generation + keystore writes +
/// DB writes; idempotency guard через `Database.readOrg()` first
/// (throws `LeafError.orgAlreadyExists` если уже создана).
///
/// На успехе `createPersonalOrg`:
/// - 3 новых row'а в DB: `org` / `team_members.self admin` / `team_keys.initial`
/// - 2 keystore файла: `<root>/x25519.priv` (X25519 privkey 32B) +
///   `<root>/team-keys/<teamKey.id>.key` (teamKey 32B)
///
/// **Keystore-first, DB-second** ordering — orphan-файл при DB-fail < orphan-row
/// при keystore-fail (decrypt impossible на orphan-row при presence broadcast).
/// Recovery от orphan-файла = noop при следующем `createPersonalOrg`
/// (idempotency guard видит `readOrg() == nil` → atomic write поверх).
///
/// Inject'абельные factories `now` / `randomBytes` / `randomUUID` /
/// `identity` — deterministic test round-trip (см. OrgServiceTests
/// test 12). Default `identity` делегирует X25519 bootstrap в
/// `IdentityService.ensureLocalIdentity` (idempotent read-or-generate);
/// caller path остаётся behaviorally identical с предыдущей inline-генерацией,
/// но второй `createPersonalOrg` после wipe-DB-but-not-keystore теперь
/// preserves identity вместо overwrite (см. spec §4 tradeoffs).
public struct OrgService: Sendable {
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
        randomBytes: @escaping @Sendable (Int) throws -> Data = Self.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.randomBytes = randomBytes
        self.randomUUID = randomUUID
        // Default factory captures `keystoreRoot` by value at init time — Swift
        // не позволяет referring другим init params в default-arg expression,
        // отсюда Optional-resolved-in-body pattern. Если `OrgService` когда-нибудь
        // станет class, replacing `keystoreRoot` после init НЕ обновит captured
        // closure (assumption: `OrgService` остаётся value type).
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    /// Throws:
    /// - `LeafError.invalidPayload` if `displayName` пустой / whitespace-only.
    /// - `LeafError.orgAlreadyExists` если row в `org` таблице уже есть.
    /// - Любая ошибка из `TeamKeystore` (`.keyFileUnavailable`) или `Database` —
    ///   propagates.
    public func createPersonalOrg(displayName: String) throws -> Org {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LeafError.invalidPayload
        }

        guard try database.readOrg() == nil else {
            throw LeafError.orgAlreadyExists
        }

        // Step 3 — IDs. Order pinned in spec: selfMemberID → orgID → teamKeyID.
        let selfMemberID = randomUUID()
        let orgID = randomUUID()
        let teamKeyID = randomUUID()

        // Step 4 — keys. `identity()` reads existing X25519 priv ИЛИ
        // generates+atomically writes (per IdentityService). On read path
        // файл уже на диске; на gen path IdentityService persisted его сам.
        // OrgService больше не пишет X25519 (ownership moved to IdentityService).
        let privKey = try identity()
        let teamKeyBytes = try randomBytes(TeamKeystore.teamKeyLength)

        // Step 5 — keystore write для teamKey (X25519 уже на диске после step 4).
        try TeamKeystore.writeTeamKey(teamKeyBytes, id: teamKeyID, at: keystoreRoot)

        // Step 6 — value types.
        let pubkeyHex = privKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }
            .joined()
        let nowDate = now()
        let member = TeamMember(
            id: selfMemberID,
            orgID: orgID,
            role: .admin,
            pubkeyHex: pubkeyHex,
            displayName: trimmed,
            addedAt: nowDate,
            removedAt: nil
        )
        let org = Org(
            id: orgID,
            name: trimmed,
            createdAt: nowDate,
            createdByMemberID: selfMemberID
        )
        let teamKey = TeamKey(
            id: teamKeyID,
            generatedAt: nowDate,
            deprecatedAt: nil,
            generatedByMemberID: selfMemberID
        )

        // Step 7 — DB writes (org → member → team_keys per contract §9 list).
        try database.upsertOrg(org)
        try database.insertTeamMember(member)
        try database.insertTeamKey(teamKey)

        return org
    }

    /// Pass-through через `database.readOrg()` — UI 5.1.E использует для
    /// "show CTA only if nil" логики (UI не должен знать про Database напрямую).
    public func currentOrg() throws -> Org? {
        try database.readOrg()
    }

    /// Track-10 T6 — active member count for the org. Returns `1` when no
    /// `org` row exists (brand-new install, solo personal user); otherwise
    /// counts `team_members.removed_at_ms IS NULL` via existing
    /// `Database.readTeamMembers(orgID:, includeRemoved: false)`. Drives the
    /// Home Zone-3 solo-vs-team gate in `InsightsReader.refresh()`.
    public func activeMemberCount() throws -> Int {
        guard let org = try database.readOrg() else { return 1 }
        return try database.readTeamMembers(orgID: org.id, includeRemoved: false).count
    }

    /// Default `randomBytes` factory: `SecRandomCopyBytes` под the hood
    /// (mirrors `FileKeyStore.generateRandomKey()` discipline). Public потому
    /// что используется в default arg `init`'а; внешние callers не должны
    /// вызывать напрямую — пусть конструируют `OrgService(database:)` с
    /// default-ным `randomBytes`.
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
