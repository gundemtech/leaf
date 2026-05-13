# Track 5 / S2 — Multi-Workspace Substrate

**Sub-phase of:** Track 5 — Collaboration Redesign ([contract](2026-05-13-track-5-collaboration-contract.md))
**Status:** Draft (2026-05-14)
**Branch:** `feature/track-5-S2-multiworkspace-substrate` (off `origin/main`)
**Owner-side:** Local Claude (Mac) — pure on-device Swift refactor + GRDB migration. ZERO network code. ZERO Supabase wire-up (that's S3).
**Workflow:** 8 stages per `conventions.md` "Одна phase = одна сессия"

---

## 1. Purpose

S2 ships the **on-device multi-workspace substrate** for Track 5: rewrites the single-org SQLCipher schema into a multi-tenant `workspaces` model, refactors the LeafCore service layer (`OrgService → WorkspaceService`, `OrgReader → WorkspaceReader`), adds a Keychain-equivalent file-based per-workspace teamKey layout, introduces an observable active-workspace state for UI, and resolves OQ-T5-2 (workspace leave flow). After S2 merges:

- Subsequent Track 5 sub-phases (S3 magic-link invite, S4 direct messages, S5 auto-share, S6 cross-post, S7 UI redesign) have a **stable on-device data model** to wire against
- Multiple workspaces can coexist on a single Mac with independent teamKey material, separate member rosters, and per-workspace artifacts (rotation outbox, pending invites)
- UI / Agent / MCPServer all consume workspace-scoped data via injected `ActiveWorkspaceStore` and `workspaceID:` parameters on Database APIs

S2 is **substrate only** — no end-user feature ships from S2 alone. Real multi-workspace UI (Sidebar switcher, workspace picker) lands in S7. Magic-link invite wire-up to live workspaces lands in S3.

---

## 2. Goal — fitness function

S2 is **done** when locally (on author's Mac) all of the following hold:

| # | Check | How to verify |
|---|---|---|
| **G1** | M019 applies clean on fresh DB | Test `M019_FreshDBMigrationTest` passes |
| **G2** | M019 backfills existing single-org alpha.x-shape DB | Test `M019_BackfillFromOrgTest` passes; existing org row + team_members + team_keys all become workspace #1's rows |
| **G3** | M019 idempotent re-run | Test `M019_IdempotencyTest` passes (matches Track 1/3/4 discipline) |
| **G4** | 2 workspaces with same display_name allowed | Test `WorkspaceServiceTests.testCreateTwoWorkspacesSameName_OK` passes |
| **G5** | team_members correctly scoped per workspace_id | Test `DatabaseTeamMembersScopingTests` passes |
| **G6** | TeamKeystore per-workspace isolation | Test `TeamKeystorePerWorkspaceTests` — cross-workspace read fails, isolated wipe works |
| **G7** | ActiveWorkspaceStore default-zero backfill | Test `ActiveWorkspaceStoreTests.testDefaultBackfillsToOldestWorkspace` passes |
| **G8** | All existing SPM tests retrofitted + green | `swift test --package-path Packages/LeafCore` exits 0 with no regressions. Baseline 2012; Task 12 deletes 18 OrgService/OrgPersistenceIntegration tests, Tasks 1-11 add ~31 new — actual final count: **2025 pass + 1 skip**. |
| **G9** | xcodebuild 5/5 schemes green | `xcodebuild -list` + `xcodebuild -scheme {Leaf,LeafAgent,LeafMCP,LeafCore,LeafCorePrivate}` all exit 0 |
| **G10** | Independent code review APPROVED | superpowers:code-reviewer subagent emits APPROVED verdict (0 Critical / 0 Important) |
| **G11** | Manual smoke — 2 workspaces created via dev harness | Dev build: create workspace "W1" via onboarding → debug menu / test seed creates workspace "W2" → `WorkspaceReader.state` reports both → `find ~/Library/Application\ Support/Leaf/keystore/workspaces -type d -maxdepth 1` shows 2 sub-directories |
| **G12** | Contract §14.1 amendment landed | `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md` §14.1 updated inline with file-based amendment annotation per §18 (living document) |

Track 5 acceptance gate (UC-T5-1 through UC-T5-7) is **not** an S2 acceptance criterion — S2 is substrate.

---

## 3. Out of S2 scope

Explicitly **not** in this sub-phase:

- Supabase client wiring (Swift `SupabaseClient.swift` or similar) — S3 magic-link invite + auth bootstrap
- `register_pubkey` Edge Function invocation — S3
- `pubkey_registry` write to Supabase — S3
- Direct messages tables (`messages_mirror`, `team_events_mirror`, `apns_token_local`) — S4 / S5
- `share_rules` table + Share Controls UI — S5
- Workspace switcher UI (Sidebar bottom) — S7
- Workspace "+ Add" picker / member admin UI — S7
- Magic-link `leaf://invite/<token>` deep-link handler updates — S3
- APNs registration — S4
- Cross-post outbound (Slack / Linear) — S6
- Tier-gating logic — S8
- Stripe billing — separate post-launch track
- Right-to-deletion hard-wipe action ("Wipe workspace data") — S8 Settings restructure
- Forever-history retention sweeper — Phase 5.4 + Track 6
- Multi-device sync of active_workspace_id across user's Macs — out of MVP

---

## 4. Architecture

### 4.1 Data model end-state (after M019)

```
SQLCipher events.sqlite (single file, all workspaces share the DB; per-workspace isolation enforced by workspace_id FK + Swift API discipline)

  workspaces                                           (renamed from org)
    id TEXT PK
    name TEXT NOT NULL
    created_at_ms INTEGER NOT NULL
    created_by_member_id TEXT NOT NULL
    left_at_ms INTEGER  ← NEW (NULL = active membership; non-NULL = soft-mark left)

  team_members
    id TEXT PK
    workspace_id TEXT NOT NULL          ← renamed from org_id
    role TEXT NOT NULL
    pubkey_hex TEXT NOT NULL
    display_name TEXT NOT NULL
    added_at_ms INTEGER NOT NULL
    removed_at_ms INTEGER

  team_keys
    id TEXT PK
    workspace_id TEXT NOT NULL          ← NEW (NOT NULL via M019 backfill)
    generated_at_ms INTEGER NOT NULL
    deprecated_at_ms INTEGER
    generated_by_member_id TEXT NOT NULL

  rotation_outbox
    peer_pubkey_hex TEXT NOT NULL
    new_key_id TEXT NOT NULL
    workspace_id TEXT NOT NULL          ← NEW
    prior_key_id TEXT NOT NULL
    kind TEXT NOT NULL CHECK (kind IN ('rotation','tombstone'))
    peer_member_id TEXT NOT NULL
    blob BLOB NOT NULL
    expires_at_ms INTEGER NOT NULL
    created_at_ms INTEGER NOT NULL
    posted_at_ms INTEGER
    PRIMARY KEY (peer_pubkey_hex, new_key_id)

  pending_invites
    token TEXT PK
    workspace_id TEXT NOT NULL          ← NEW
    otp TEXT NOT NULL
    invitee_pubkey_hex TEXT NOT NULL
    invitee_display_name_hint TEXT
    created_at_ms INTEGER NOT NULL
    expires_at_ms INTEGER NOT NULL
    status TEXT NOT NULL DEFAULT 'pending'
    last_polled_at_ms INTEGER
```

Indexes:
- `team_members_workspace_active` (renamed from `team_members_org_active`) — partial `(workspace_id) WHERE removed_at_ms IS NULL`
- `team_keys_active` — preserved unchanged (workspace-aware queries add WHERE clause)
- `rotation_outbox_unposted` — preserved unchanged
- `idx_pending_invites_status` — preserved unchanged

### 4.2 Keystore layout end-state

```
~/Library/Application Support/Leaf/keystore/
├── x25519.priv                                        (device-scoped; unchanged)
└── workspaces/
    ├── <workspace-1-uuid>/
    │   └── team-keys/
    │       └── <key-1-uuid>.key                       (32 bytes raw, 0o600)
    │       └── <key-2-uuid>.key                       (after first rotation)
    └── <workspace-2-uuid>/
        └── team-keys/
            └── <key-3-uuid>.key
```

X25519 priv stays at root (device identity unchanged per D8). Each workspace gets its own `workspaces/<uuid>/team-keys/` directory containing its teamKey rotation history.

**Migration of existing alpha.x users:** S2 includes one-time file relocation on first launch post-M019: `<root>/team-keys/<id>.key` → `<root>/workspaces/<workspace-uuid>/team-keys/<id>.key`. Implemented in `TeamKeystore.relocateLegacyFilesIfNeeded(workspaceID:at:)` called once during M019 application path. Failsafe: if relocation fails mid-way (partial state), subsequent runs retry idempotently (move only files still at legacy location).

### 4.3 Swift module layout end-state

```
Packages/LeafCore/Sources/LeafCore/
├── Team/
│   ├── WorkspaceService.swift              (renamed + extended from OrgService)
│   ├── InviteService.swift                 (+workspaceID parameter)
│   ├── InviteAcceptService.swift           (workspaceID extracted from invite blob)
│   ├── KeyRotationService.swift            (+workspaceID parameter)
│   └── RotationFetchService.swift          (+workspaceID parameter)
├── Crypto/
│   ├── TeamKeystore.swift                  (workspaceID-aware sub-folder API)
│   └── IdentityService.swift               (unchanged — device-scoped X25519)
├── DB/
│   ├── Schema.swift                        (Org → Workspaces; orgID → workspaceID)
│   ├── Database.swift                      (org methods → workspace methods)
│   └── Migrations/
│       └── M019_Workspaces.swift           (NEW)
└── Models/
    ├── Org.swift                            → Workspace.swift (renamed)
    └── TeamMember.swift                    (workspaceID field renamed)

Packages/LeafCore/Sources/LeafCore/State/
└── ActiveWorkspaceStore.swift               (NEW — placed in LeafCore for SPM testability;
                                              Leaf-app, Agent, MCPServer all import LeafCore)

Leaf/Models/
└── OrgReader.swift                          → WorkspaceReader.swift (renamed)

Leaf/Views/                                  9 UI files: @Environment(WorkspaceReader.self) swap
```

---

## 5. Schema migration M019

### 5.1 Migration identifier

- File: `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M019_Workspaces.swift`
- Identifier: `"019_workspaces"`
- Registered in `Database.swift` after `registerMigration018IntensityAggregates()`

### 5.2 Migration body (atomic GRDB block)

Migration runs inside a single GRDB `registerMigration("019_workspaces") { db in ... }` block. GRDB wraps the body in an implicit transaction; partial application yields rollback. The block performs the following operations in order:

```swift
// Step 1 — Rename `org` table → `workspaces`.
// SQLite 3.25+ ALTER TABLE RENAME TO supported (macOS 10.14+ system SQLite).
try db.execute(sql: "ALTER TABLE org RENAME TO workspaces")

// Step 2 — Add `left_at_ms INTEGER` to workspaces (nullable; NULL = active).
try db.alter(table: Schema.Workspaces.tableName) { t in
    t.add(column: Schema.Workspaces.leftAtMs, .integer)
}

// Step 3 — Rename `team_members.org_id` → `workspace_id`.
// SQLite 3.25+ ALTER TABLE RENAME COLUMN supported. Auto-updates referenced indexes.
try db.execute(sql:
    "ALTER TABLE team_members RENAME COLUMN org_id TO workspace_id"
)

// Step 4 — Pre-fetch first workspace's id for backfill of newly-added columns.
// On fresh DB (no existing org row), firstWorkspaceID = nil → defer sentinel.
let firstWorkspaceID = try Row.fetchOne(
    db,
    sql: "SELECT \(Schema.Workspaces.id) FROM \(Schema.Workspaces.tableName) ORDER BY \(Schema.Workspaces.createdAtMs) ASC LIMIT 1"
)?.string(at: 0)

// Step 5 — Add `workspace_id TEXT NOT NULL DEFAULT '<firstWorkspaceID>'` to team_keys.
// On fresh DB, firstWorkspaceID = nil → use sentinel "" which never matches any real workspace;
// no existing rows means no backfill happens (DEFAULT only fires on existing rows when ALTER ADD COLUMN).
// New code-side INSERTs always set workspace_id explicitly.
let backfillValue = firstWorkspaceID ?? ""
try db.execute(sql: """
    ALTER TABLE team_keys ADD COLUMN workspace_id TEXT NOT NULL DEFAULT \(SQLValue(backfillValue))
""")

// Step 6 — Same for rotation_outbox.
try db.execute(sql: """
    ALTER TABLE rotation_outbox ADD COLUMN workspace_id TEXT NOT NULL DEFAULT \(SQLValue(backfillValue))
""")

// Step 7 — Same for pending_invites.
try db.execute(sql: """
    ALTER TABLE pending_invites ADD COLUMN workspace_id TEXT NOT NULL DEFAULT \(SQLValue(backfillValue))
""")

// Step 8 — Drop old `team_members_org_active` index, create `team_members_workspace_active`.
// (SQLite auto-renames index column references via ALTER RENAME COLUMN in step 3, but the
// index NAME does not auto-update. We drop + recreate explicitly for clarity.)
try db.execute(sql: "DROP INDEX IF EXISTS team_members_org_active")
try db.create(
    index: Schema.TeamMembers.indexWorkspaceActive,
    on: Schema.TeamMembers.tableName,
    columns: [Schema.TeamMembers.workspaceID],
    condition: Column(Schema.TeamMembers.removedAtMs) == nil
)
```

Note: SQLite does **not** support parameter binding in `ALTER TABLE ADD COLUMN DEFAULT ?` clauses (DDL statements require literal defaults). M019 therefore interpolates the workspace UUID literal — safe because the UUID is generated server-side via `UUID().uuidString` (no user-controlled input crosses this boundary). For per-row backfill outside DDL, parameter binding via `db.execute(sql:..., arguments:[...])` is used as usual.

### 5.3 Schema.swift constant changes

```swift
public enum Workspaces {                                      // renamed from Org
    public static let tableName = "workspaces"                // was "org"
    public static let id = "id"
    public static let name = "name"
    public static let createdAtMs = "created_at_ms"
    public static let createdByMemberID = "created_by_member_id"
    public static let leftAtMs = "left_at_ms"                 // NEW
}

public enum TeamMembers {
    public static let tableName = "team_members"
    public static let id = "id"
    public static let workspaceID = "workspace_id"            // renamed from orgID
    // ... rest unchanged ...
    public static let indexWorkspaceActive = "team_members_workspace_active"  // renamed
}

public enum TeamKeys {
    public static let tableName = "team_keys"
    public static let id = "id"
    public static let workspaceID = "workspace_id"            // NEW
    public static let generatedAtMs = "generated_at_ms"
    public static let deprecatedAtMs = "deprecated_at_ms"
    public static let generatedByMemberID = "generated_by_member_id"
    public static let indexActive = "team_keys_active"        // unchanged
}

public enum RotationOutbox {
    // ... existing ...
    public static let workspaceID = "workspace_id"            // NEW
}

public enum PendingInvites {
    // ... existing ...
    public static let workspaceID = "workspace_id"            // NEW
}
```

### 5.4 Edge cases & failure modes

| Scenario | M019 Behavior |
|---|---|
| Fresh DB (no `org` table contents) | All ALTER steps succeed against empty tables; no backfill needed; new code-side INSERTs always set `workspace_id` explicitly |
| alpha.x DB with 1 org + N team_members + 1 team_keys row | Rename row + columns; backfill all child workspace_ids = the single org id; existing functionality preserved |
| alpha.x DB with rotation_outbox rows mid-rotation (e.g. crashed admin) | rotation_outbox rows get workspace_id = first workspace id (their owning workspace); idempotent retry on next launch still works because composite PK unchanged |
| alpha.x DB with pending_invites rows | Same — pending invites get workspace_id = first workspace id |
| Defensive: 2 `org` rows ever existed (bug, not supposed to happen) | First row by created_at_ms becomes "first workspace"; child rows all backfill to that ID; second org row also becomes a workspace but its child rows would be ambiguous — this is detectable via assertion in S2 test `M019_MultiOrgBackfillTest` |
| Migration crashes mid-way | GRDB implicit transaction rolls back; DB stays at M018 state; next launch retries M019 atomically |

### 5.5 Rollback strategy

**Forward-only migrations** per existing GRDB convention (no `down` SQL). If M019 ever needs revert in production, the path is: ship M020 that inverses the changes (rename back, drop columns). Rolling back the SQLite file itself is unsafe (events.sqlite contains user data captured post-M019). In practice: M019 is reviewed thoroughly, ships in alpha builds first, then production.

---

## 6. WorkspaceService API

### 6.1 Public surface

```swift
public struct WorkspaceService: Sendable {
    public init(
        database: Database,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) throws -> Data = WorkspaceService.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    )

    /// Creates a brand-new workspace (admin = self). Generates: workspace UUID,
    /// self team_members row (role=admin), first team_key, identity X25519 (if
    /// first workspace on device).
    /// Returns: created Workspace.
    /// Throws: `LeafError.invalidPayload` (empty/whitespace name), errors from
    /// TeamKeystore / Database.
    /// Does NOT throw on duplicate name — multi-workspace allows same display
    /// (per-admin uniqueness from S1 OQ-T5-5; on this device the admin is one
    /// human, so client-side uniqueness check is a smell — defer to user's UX
    /// preference to rename if confusing).
    public func createWorkspace(displayName: String) throws -> Workspace

    /// Read single workspace by id. Returns nil if not found.
    public func readWorkspace(id: String) throws -> Workspace?

    /// Read all workspaces. `includeLeft = false` (default) hides left workspaces
    /// (left_at_ms IS NOT NULL). For Settings → "Workspaces history" use
    /// `includeLeft = true`.
    public func listWorkspaces(includeLeft: Bool = false) throws -> [Workspace]

    /// Soft-mark workspace as left. Sets `left_at_ms = at`. Idempotent re-call
    /// on already-left workspace preserves original timestamp.
    /// Throws `LeafError.invalidPayload` if workspace doesn't exist.
    /// Does NOT delete data (per OQ-T5-2 resolution; hard-wipe deferred to S8).
    public func markLeft(workspaceID: String, at: Date) throws

    /// Reverse of markLeft. Clears `left_at_ms`. Used by S3 invite-acceptance
    /// path when re-joining a workspace (admin re-invited the user).
    public func rejoin(workspaceID: String) throws

    public static func secureRandom(_ count: Int) throws -> Data
}
```

### 6.2 createWorkspace orchestration (mirrors OrgService.createPersonalOrg)

1. Validate `displayName` (non-empty after trim)
2. Generate 3 UUIDs: `selfMemberID`, `workspaceID`, `teamKeyID`
3. Resolve identity X25519 via injected `identity()` (reads existing or generates+atomically writes via `IdentityService.ensureLocalIdentity`)
4. Generate 32B random `teamKey` bytes
5. **Keystore-first write:** `TeamKeystore.writeTeamKey(_, workspaceID:, keyID:, at:)` → creates `<root>/workspaces/<workspaceID>/team-keys/<teamKeyID>.key`
6. Build value types: `Workspace`, `TeamMember(role=admin)`, `TeamKey(workspaceID:)`
7. DB writes in order: `upsertWorkspace(workspace)` → `insertTeamMember(member)` → `insertTeamKey(teamKey)`
8. Return `Workspace`

**Idempotency:** unlike single-org `createPersonalOrg`, `createWorkspace` does NOT throw on existing workspace — it appends. Multi-workspace is the design intent. The "already exists" semantics from old API are gone.

### 6.3 markLeft / rejoin behavior

- **markLeft:** Soft-mark. UI hides from active list. team_keys preserved (rationale per D7). All child data preserved.
- **rejoin:** Clears `left_at_ms`. Used by `InviteAcceptService` when invite arrives for workspace user previously left. Existing team_keys / member rows reattach naturally (FK by `workspace_id` unchanged).

---

## 7. WorkspaceReader (UI adapter) + ActiveWorkspaceStore

### 7.1 ActiveWorkspaceStore

Lives in `Packages/LeafCore/Sources/LeafCore/State/ActiveWorkspaceStore.swift` (LeafCore, not Leaf app target) so that SPM tests can exercise it directly. Agent + MCPServer also import LeafCore and can read `activeWorkspaceID` without binding to SwiftUI observation — they consult the raw UserDefaults value via the same key constant.

```swift
@MainActor
@Observable
public final class ActiveWorkspaceStore {
    public private(set) var activeWorkspaceID: String?

    private let userDefaults: UserDefaults
    private static let key = "leaf.active_workspace_id"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.activeWorkspaceID = userDefaults.string(forKey: Self.key)
    }

    /// Set active workspace. Persists to UserDefaults; observation triggers
    /// re-renders in WorkspaceReader-bound views.
    public func setActive(_ id: String?) {
        activeWorkspaceID = id
        if let id { userDefaults.set(id, forKey: Self.key) }
        else { userDefaults.removeObject(forKey: Self.key) }
    }

    /// Called post-M019 backfill if no active is set: resolve to oldest workspace.
    /// Idempotent — no-op if already set.
    public func backfillIfNeeded(database: Database) throws {
        guard activeWorkspaceID == nil else { return }
        let oldest = try database.listWorkspaces(includeLeft: false)
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first
        if let oldest { setActive(oldest.id) }
    }
}
```

### 7.2 WorkspaceReader (replaces OrgReader)

```swift
@MainActor
@Observable
final class WorkspaceReader {
    enum State: Equatable {
        case loading
        case empty                                          // no workspaces yet — onboarding flow
        case loaded(workspaces: [Workspace], active: Workspace, members: [TeamMember])
        case removedFromActiveWorkspace(workspaceName: String)
        case error(message: String)
    }

    private(set) var state: State = .loading
    private var database: LeafCore.Database?
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let activeStore: ActiveWorkspaceStore

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = WorkspaceReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = WorkspaceReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        activeStore: ActiveWorkspaceStore
    )

    /// Reads workspaces + active members from DB into state. Idempotent. Sync.
    func refresh()

    /// Creates a new workspace + auto-switches active to it.
    func createWorkspace(displayName: String)

    /// Soft-mark current active as left. Auto-switches active to oldest remaining
    /// (or .empty if last).
    func leaveActiveWorkspace()

    /// Switches active workspace. Idempotent.
    func switchActive(to workspaceID: String)
}
```

**State machine transitions:**

- `.loading` → `.empty` (fresh DB, no workspaces) → `.loaded` (after createWorkspace)
- `.loaded` → `.removedFromActiveWorkspace(name)` (Phase 5.3.E self-pubkey tombstone detection — same as OrgReader; scoped per active workspace)
- `.loaded` → `.loaded` (switchActive → re-fetch members for new active)
- `.loaded` → `.empty` (leaveActiveWorkspace when last workspace left)

`switchActive` calls `activeStore.setActive(id)` → mutation triggers observation → `refresh()` reads new active members.

### 7.3 UI consumer migration

9 SwiftUI views currently using `@Environment(OrgReader.self)`:

```
Leaf/Views/Window/RootView.swift                          @Environment(OrgReader.self) → @Environment(WorkspaceReader.self)
Leaf/Views/OnboardingView.swift                           same
Leaf/Views/Onboarding/CreateTeamStepView.swift            same; rename CTA "Create team" preserved
Leaf/Views/Window/Organization/OrganizationView.swift     same; reader.state pattern preserved
Leaf/Views/Window/Organization/AcceptInviteSheet.swift    same
Leaf/Views/Window/Team/TeamView.swift                     same
Leaf/Views/Window/Team/RemoveMemberSheet.swift            same
Leaf/Views/Window/Team/GenerateInviteSheet.swift          same
Leaf/LeafApp.swift                                        @State private var workspaceReader = WorkspaceReader(activeStore: ActiveWorkspaceStore())
```

Pattern: state shape change is transparent to most views (they pattern-match on `state.loaded(_, _, members)` similar to old `.loaded(org, members)`). Views referencing `org` rename to `active` semantic. Verbatim diff size: ~50 lines across 9 files (mostly identifier renames).

### 7.4 Composition root wiring

In `LeafApp.swift`:

```swift
@main
struct LeafApp: App {
    @State private var activeWorkspaceStore = ActiveWorkspaceStore()
    @State private var workspaceReader: WorkspaceReader

    init() {
        let active = ActiveWorkspaceStore()
        self._activeWorkspaceStore = State(initialValue: active)
        self._workspaceReader = State(
            initialValue: WorkspaceReader(activeStore: active)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(workspaceReader)
                .environment(activeWorkspaceStore)
        }
    }
}
```

ActiveWorkspaceStore is also injected as `@Environment(ActiveWorkspaceStore.self)` so future S7 Sidebar switcher view can read/write directly without going through WorkspaceReader.

---

## 8. TeamKeystore multi-workspace API

### 8.1 Public surface

```swift
public enum TeamKeystore {
    public static let x25519PrivateFilename = "x25519.priv"   // unchanged
    public static let workspacesSubdir = "workspaces"          // NEW
    public static let teamKeysSubdir = "team-keys"             // unchanged subdir name within workspace
    public static let teamKeyExtension = "key"                 // unchanged

    public static let x25519PrivateLength = 32
    public static let teamKeyLength = 32

    public static func defaultRoot() -> URL                    // unchanged

    // MARK: - X25519 private (device-scoped, unchanged)
    public static func writeX25519Private(_ bytes: Data, at root: URL = defaultRoot()) throws
    public static func readX25519Private(at root: URL = defaultRoot()) throws -> Data

    // MARK: - TeamKey (workspace-scoped, NEW shape)
    public static func writeTeamKey(
        _ bytes: Data,
        workspaceID: String,
        keyID: String,
        at root: URL = defaultRoot()
    ) throws
    public static func readTeamKey(
        workspaceID: String,
        keyID: String,
        at root: URL = defaultRoot()
    ) throws -> Data

    /// Delete entire workspace directory. Used by hard-wipe action (S8) and
    /// test cleanup. NOT used by markLeft (which preserves data).
    public static func deleteWorkspace(workspaceID: String, at root: URL = defaultRoot()) throws

    // MARK: - Migration helper (one-time, called from M019 application path)
    /// Relocates legacy `<root>/team-keys/<id>.key` files into
    /// `<root>/workspaces/<workspaceID>/team-keys/<id>.key`. Idempotent.
    /// Called once during M019 application if any legacy files exist.
    public static func relocateLegacyTeamKeys(toWorkspaceID workspaceID: String, at root: URL = defaultRoot()) throws

    /// Test/dev only — recursive removeItem на `<root>/`.
    public static func deleteAll(at root: URL = defaultRoot()) throws
}
```

### 8.2 Internal helpers

```swift
private static func workspaceDirectoryURL(workspaceID: String, root: URL) -> URL {
    root
        .appendingPathComponent(workspacesSubdir, isDirectory: true)
        .appendingPathComponent(workspaceID, isDirectory: true)
}

private static func teamKeyURL(workspaceID: String, keyID: String, root: URL) -> URL {
    workspaceDirectoryURL(workspaceID: workspaceID, root: root)
        .appendingPathComponent(teamKeysSubdir, isDirectory: true)
        .appendingPathComponent("\(keyID).\(teamKeyExtension)", isDirectory: false)
}
```

### 8.3 Track 5 contract §14.1 amendment

Per contract §18 (living document), S2 amends §14.1 inline in `2026-05-13-track-5-collaboration-contract.md`:

> **Amendment 2026-05-14 (S2 spec):** §14.1 — corrected workspace teamKey storage from "Keychain `leaf_team_key_<workspace_uuid>`" to file-based `<root>/workspaces/<workspace_uuid>/team-keys/<key_id>.key` (0o600 + FileVault discipline). This preserves the Phase 5.1.D TeamKeystore design (file-based, not Keychain — same sensitivity tier as the SQLCipher DB key per FileKeyStore). X25519 device identity remains at `<root>/x25519.priv`. Rationale: consistency with existing TeamKeystore pattern, isolation of test fixtures from system Keychain, atomic workspace-level wipe via recursive directory remove. No security regression — file permissions + FileVault = Keychain access group for sensitivity equivalence.

---

## 9. Database method renames

All `Database` methods touching org/team_members/team_keys/rotation_outbox/pending_invites are renamed for clarity + workspace-scoping. Mapping:

| Old API | New API | Notes |
|---|---|---|
| `upsertOrg(_ org: Org)` | `upsertWorkspace(_ workspace: Workspace)` | column rename only |
| `readOrg() -> Org?` | `readWorkspace(id: String) -> Workspace?` | now takes id parameter |
| (n/a) | `listWorkspaces(includeLeft: Bool) -> [Workspace]` | NEW |
| (n/a) | `markWorkspaceLeft(id: String, at: Date) throws` | NEW |
| (n/a) | `clearWorkspaceLeftAt(id: String) throws` | NEW (for rejoin) |
| `insertTeamMember(_ member: TeamMember)` | unchanged signature | `TeamMember.orgID` field renamed to `workspaceID` |
| `readTeamMembers(orgID: String, includeRemoved: Bool)` | `readTeamMembers(workspaceID: String, includeRemoved: Bool)` | parameter rename |
| `markTeamMemberRemoved(memberID:, at:)` | unchanged | no scoping needed (memberID is globally unique UUID) |
| `insertTeamKey(_ key: TeamKey)` | unchanged signature | TeamKey gains `workspaceID` field |
| `insertTeamKeyIfAbsent(_ key: TeamKey)` | unchanged | same |
| `readActiveTeamKey() -> TeamKey?` | `readActiveTeamKey(workspaceID: String) -> TeamKey?` | **mandatory parameter** |
| `deprecateTeamKey(keyID:, at:)` | unchanged signature | scoping via team_keys.id UUID uniqueness |

**Sole-active invariant** (from old `deprecateTeamKey` guard): "Cannot deprecate the only active key" — invariant now scoped per workspace. Guard becomes "Cannot deprecate the only active key **for this workspace**." Implementation: WHERE clause adds `workspace_id = ?`.

### 9.1 Schema reads — new "by workspace" filter clause

Example transformation:

```swift
// OLD
public func readActiveTeamKey() throws -> TeamKey? {
    try pool.read { db in
        let row = try Row.fetchOne(db, sql: """
            SELECT \(Schema.TeamKeys.id), ...
            FROM \(Schema.TeamKeys.tableName)
            WHERE \(Schema.TeamKeys.deprecatedAtMs) IS NULL
            ORDER BY \(Schema.TeamKeys.generatedAtMs) DESC
            LIMIT 1
            """)
        return row.flatMap(Self.mapTeamKeyRow)
    }
}

// NEW
public func readActiveTeamKey(workspaceID: String) throws -> TeamKey? {
    try pool.read { db in
        let row = try Row.fetchOne(db, sql: """
            SELECT \(Schema.TeamKeys.id), \(Schema.TeamKeys.workspaceID), ...
            FROM \(Schema.TeamKeys.tableName)
            WHERE \(Schema.TeamKeys.workspaceID) = ?
              AND \(Schema.TeamKeys.deprecatedAtMs) IS NULL
            ORDER BY \(Schema.TeamKeys.generatedAtMs) DESC
            LIMIT 1
            """,
            arguments: [workspaceID])
        return row.flatMap(Self.mapTeamKeyRow)
    }
}
```

### 9.2 mapTeamKeyRow signature change

```swift
private static func mapTeamKeyRow(_ row: Row) -> TeamKey? {
    guard
        let id: String = row[Schema.TeamKeys.id],
        let workspaceID: String = row[Schema.TeamKeys.workspaceID],
        // ... rest ...
    else { return nil }
    return TeamKey(
        id: id,
        workspaceID: workspaceID,
        generatedAt: ...,
        deprecatedAt: ...,
        generatedByMemberID: ...
    )
}
```

---

## 10. Consumer refactors

### 10.1 InviteService

Old: `issueInvite(displayName: String) -> InviteBlob`. Implicitly used the device's single teamKey.

New: `issueInvite(workspaceID: String, displayName: String) -> InviteBlob`. Reads active teamKey via `database.readActiveTeamKey(workspaceID: workspaceID)`. Reads teamKey bytes via `TeamKeystore.readTeamKey(workspaceID: keyID:)`. InviteBlob shape gains `workspaceID` field so invitee knows which workspace they're joining (used by InviteAcceptService).

**InviteBlob version bump.** InviteBlobCodec (Phase 5.2 implementation moat in LeafCorePrivate) carries a 1-byte version prefix. S2 ships codec v2 — adds 16-byte `workspaceID` field. Decoder support:

- **v2 blob decoded by v2 codec:** workspaceID extracted, used directly
- **v1 blob decoded by v2 codec:** legacy path — workspaceID defaults to first workspace post-M019. Practically zero impact: Phase 5.5 invites are 24h-expiry per spec; alpha.11 ships before S2 alpha.12, so by S2 ship date no in-flight v1 blobs remain. The legacy decoder branch exists for paranoid safety, not active migration
- **v2 blob decoded by v1 codec (downgrade):** unsupported — user already upgraded to S2, no rollback path

InviteBlobCodec.swift implementation lives in `LeafCorePrivate` (moat). Spec records intent; exact byte layout details remain private.

### 10.2 InviteAcceptService

Old: `acceptInvite(blob: InviteBlob, displayName: String)`. Wrote into single-org schema.

New: `acceptInvite(blob: InviteBlob, displayName: String)`. Reads `workspaceID` from blob, writes into workspaces / team_members / team_keys tables with that workspace_id. If workspace already exists locally with `left_at_ms IS NOT NULL` → calls `clearWorkspaceLeftAt(id:)` to rejoin (avoids duplicate workspace row).

### 10.3 KeyRotationService

Old: `rotateTeamKey(newKeyBytes: Data, at: Date)`. Rotated the device's single teamKey.

New: `rotateTeamKey(workspaceID: String, newKeyBytes: Data, at: Date)`. Scoped to one workspace. `RotationOutbox` rows generated also carry `workspaceID`. Sole-active invariant guard scoped per workspace.

### 10.4 RotationFetchService

Old: peer fetch loop polled relay for rotation blobs for self.

New: peer fetch loop polled for rotation blobs **per workspace**. The loop must iterate over all active workspaces (those where self is a member, `left_at_ms IS NULL`). Each blob installed via `database.insertTeamKeyIfAbsent` + `TeamKeystore.writeTeamKey(workspaceID:keyID:)`. Phase S3 will further refactor this for Supabase relay; S2 just adds workspace_id awareness to the existing leaf-relay polling.

---

## 11. OQ-T5-2 resolution (workspace leave)

**Track 5 contract §16 — OQ-T5-2:** "Workspace leave flow — does data wipe locally or remain read-only?"

**S2 resolution:** **Soft-mark `workspaces.left_at_ms` (data preserved).** Reasoning:

- team_keys forever-retained per M008 design comment (needed for future presence_history decrypt — Phase 5.4)
- UX: re-join via fresh invite preserves contextual history rather than starting clean
- Right-to-deletion is a separate user-initiated action ("Wipe workspace data") — deferred to S8 Settings restructure
- Schema-level support is single nullable column `workspaces.left_at_ms` — minimal cost
- WorkspaceService.markLeft is the API; reverse is rejoin
- Active list filter `WHERE left_at_ms IS NULL` hides left workspaces by default
- Rejoin (via new invite for a previously-left workspace) clears `left_at_ms` instead of creating duplicate workspace row

**Future hard-wipe scope (NOT in S2):**

- "Wipe workspace data" action in Settings → confirm dialog → calls `database.deleteWorkspaceCascade(workspaceID:)` + `TeamKeystore.deleteWorkspace(workspaceID:)` (the latter already in S2's TeamKeystore API for testability, but no UI calls it)
- Cascade delete sequence: rotation_outbox → pending_invites → team_keys → team_members → workspace row → keystore directory
- Defer until S8 — not blocking on S2 substrate

---

## 12. Test approach

### 12.1 Test file organization

```
Packages/LeafCore/Tests/LeafCoreTests/
├── M019_FreshDBMigrationTests.swift                  NEW
├── M019_BackfillTests.swift                          NEW (covers single-org backfill + multi-org defensive)
├── M019_IdempotencyTests.swift                       NEW
├── WorkspaceServiceTests.swift                       renamed from OrgServiceTests; retrofitted
├── WorkspacePersistenceIntegrationTests.swift        renamed from OrgPersistenceIntegrationTests
├── TeamKeystorePerWorkspaceTests.swift               NEW (sub-folder isolation + relocateLegacy)
├── ActiveWorkspaceStoreTests.swift                   NEW
├── DatabaseTeamMembersScopingTests.swift             NEW (2-workspace scoping)
├── DatabaseRotationOutboxTests.swift                 retrofitted (workspaceID parameter)
├── DatabaseInsertTeamKeyIfAbsentTests.swift          retrofitted
├── DatabaseTeamTests.swift                           retrofitted
├── InviteServiceTests.swift                          retrofitted (workspaceID parameter)
├── InviteAcceptServiceTests.swift                    retrofitted (workspaceID from blob)
├── KeyRotationServiceTests.swift                     retrofitted
├── RotationFetchServiceTests.swift                   retrofitted
└── TeamKeystoreTests.swift                           retrofitted (old single-key API → workspace-scoped)
```

**WorkspaceReader test coverage gap (acknowledged):** Verified during Discovery that the `Leaf` app target has no test directory and no existing `OrgReaderTests.swift`. WorkspaceReader thus has no automated unit-test coverage in S2 — same as OrgReader today. Coverage approach:

1. **Substrate tests** — every method WorkspaceReader calls (WorkspaceService, Database scoping reads, ActiveWorkspaceStore, TeamKeystore per-workspace) IS covered at LeafCore level
2. **Manual smoke (G11)** — exercise WorkspaceReader state transitions via dev build (create workspace → switch active → leave active)
3. **Future** — establishing a `Leaf` app test target is out of S2 scope (boilerplate-heavy Xcode project change). Tracked as carry-over for whoever extends Leaf-app testability (Track 6 candidate)

### 12.2 Test patterns

Mirror existing OrgServiceTests / TeamKeystoreTests patterns. Key adaptations:

**M019 fresh DB migration:**
```swift
func testM019_FreshDB_AllSchemaPresent() throws {
    // setup: fresh tempDir DB
    let db = try makeFreshDB()
    // act: open + migrate up to M019
    // assert: workspaces, team_members.workspace_id, team_keys.workspace_id,
    //   rotation_outbox.workspace_id, pending_invites.workspace_id all exist;
    //   team_members_workspace_active index exists; team_members_org_active does not
}
```

**M019 backfill:**
```swift
func testM019_AlphaXBackfill_PreservesData() throws {
    // setup: open DB at M018, insert org row "Existing Team" + team_members(self)
    //   + team_keys(initial) at pre-M019 schema
    // act: migrate to M019
    // assert: workspaces table has 1 row preserving original UUID + name + created_at;
    //   team_members has workspace_id = that UUID; team_keys has workspace_id = that UUID;
    //   left_at_ms is NULL on workspace
}
```

**TeamKeystore per-workspace isolation:**
```swift
func testTeamKeystore_TwoWorkspaces_SeparateFiles() throws {
    let w1 = "workspace-1-uuid"
    let w2 = "workspace-2-uuid"
    let k1 = "key-1-uuid"
    let k2 = "key-2-uuid"
    try TeamKeystore.writeTeamKey(Data(repeating: 0xAA, count: 32), workspaceID: w1, keyID: k1, at: tempRoot)
    try TeamKeystore.writeTeamKey(Data(repeating: 0xBB, count: 32), workspaceID: w2, keyID: k2, at: tempRoot)
    // assert: reading w1/k1 returns 0xAA bytes; w2/k2 returns 0xBB
    // assert: reading w1/k2 throws keyFileUnavailable (no cross-workspace leak)
    // assert: two separate directories under <tempRoot>/workspaces/
}
```

**TeamKeystore.relocateLegacyTeamKeys idempotency:**
```swift
func testTeamKeystore_LegacyRelocation_Idempotent() throws {
    // setup: write file at legacy path <tempRoot>/team-keys/<keyID>.key
    // act: call relocateLegacyTeamKeys(toWorkspaceID: w1) twice
    // assert: file at <tempRoot>/workspaces/<w1>/team-keys/<keyID>.key
    // assert: legacy <tempRoot>/team-keys/ directory empty or removed
    // assert: second call no-op (file already at new location)
}
```

**ActiveWorkspaceStore backfill:**
```swift
func testActiveWorkspaceStore_BackfillIfNeeded_ResolvesToOldest() throws {
    // setup: DB with 2 workspaces, w1 created earlier than w2; UserDefaults empty
    let store = ActiveWorkspaceStore(userDefaults: testUD)
    XCTAssertNil(store.activeWorkspaceID)
    try store.backfillIfNeeded(database: db)
    XCTAssertEqual(store.activeWorkspaceID, w1.id)
}
```

**WorkspaceService.createWorkspace 2× same name:**
```swift
func testWorkspaceService_CreateTwoWithSameName_BothExist() throws {
    let svc = makeService()
    let w1 = try svc.createWorkspace(displayName: "Acme Corp")
    let w2 = try svc.createWorkspace(displayName: "Acme Corp")
    XCTAssertNotEqual(w1.id, w2.id)
    XCTAssertEqual(try svc.listWorkspaces(), [w1, w2])
}
```

### 12.3 Existing test retrofit pattern

For tests like `OrgServiceTests.testCreatePersonalOrg_WritesAllThreeRows`:

```swift
// OLD
let org = try svc.createPersonalOrg(displayName: "Team A")
let teamKey = try db.readActiveTeamKey()

// NEW
let workspace = try svc.createWorkspace(displayName: "Team A")
let teamKey = try db.readActiveTeamKey(workspaceID: workspace.id)
```

Mechanical. Compile errors guide the retrofit — switch IDE to "fix on save" or process via `swift build` cycle.

### 12.4 Test count expectations

- Baseline: 2012 tests (per current-state.md Track 4 S4)
- S2 retrofit: 0 net change to existing test count (renames only)
- S2 new tests: ~30-50 net new (multi-workspace scoping, M019 variants, ActiveWorkspaceStore, TeamKeystore per-workspace isolation, WorkspaceService new methods)
- Expected after S2: ~2042-2062 SPM tests

---

## 13. Refactor sequence (TDD discipline)

S2 lands as a sequence of atomic commits, each compiling + tests green at the commit boundary (per `superpowers:test-driven-development`). Detailed per-commit decomposition lives in the plan doc (Stage 4); this section sketches the phasing:

**Phase A — Schema migration + Workspace model + legacy relocation (1 commit):**
- New file `M019_Workspaces.swift` registered in `Database.swift` migrator chain
- `Schema.swift`: `Schema.Org → Schema.Workspaces`, `team_members.orgID → workspaceID`, add `team_keys.workspaceID` / `rotation_outbox.workspaceID` / `pending_invites.workspaceID` / `workspaces.leftAtMs` constants, rename `team_members_org_active` index to `team_members_workspace_active`
- `Database.swift`: retrofit all team/org methods to new signatures (workspaceID parameter + new SQL column names)
- Introduce `Workspace.swift` struct (formerly `Org`); existing `Org.swift` becomes `typealias Org = Workspace` shim
- `TeamMember.workspaceID` / `TeamKey.workspaceID` field renames
- `TeamKeystore.relocateLegacyTeamKeys` helper added (no callers in this commit; sits idle)
- M019 application path calls `TeamKeystore.relocateLegacyTeamKeys(toWorkspaceID:)` for the single existing org's first workspace UUID (one-time file move)
- Track 5 contract §14.1 inline amendment annotation
- Existing DB tests retrofitted (mechanical rename)
- New tests: `M019_FreshDBMigrationTests`, `M019_BackfillTests`, `M019_IdempotencyTests`
- Build green; `OrgService` / `OrgReader` continue to compile against `Workspace` via typealias

**Phase B — New services in parallel (4 commits, each independent):**
1. TeamKeystore multi-workspace API + TeamKeystorePerWorkspaceTests; old single-key shims remain
2. WorkspaceService + WorkspaceServiceTests (parallel to OrgService)
3. ActiveWorkspaceStore + ActiveWorkspaceStoreTests in LeafCore/State/
4. WorkspaceReader in Leaf/Models/ (no automated tests — manual smoke gate per §12.1)

Old `OrgService` / `OrgReader` untouched throughout Phase B — still compile, still functional. New types coexist.

**Phase C — Consumer retrofit (4 commits, each TDD per step):**
1. InviteService — `workspaceID:` parameter, InviteBlob v2 (LeafCorePrivate moat update)
2. InviteAcceptService — workspaceID extracted from v2 blob; rejoin path on existing-but-left workspace
3. KeyRotationService — `workspaceID:` parameter, sole-active guard scoped per workspace
4. RotationFetchService — workspaceID-aware fetch loop

Each consumer retrofit ships with its updated tests.

**Phase D — UI consumer swap (1 commit):**
- 9 SwiftUI views: `@Environment(OrgReader.self)` → `@Environment(WorkspaceReader.self)`
- `LeafApp.swift` composition root injects `WorkspaceReader` + `ActiveWorkspaceStore`
- Manual smoke executed: dev build → create workspace #1 via onboarding → debug seed creates workspace #2 → verify both in state, `find <root>/workspaces -type d -maxdepth 1` shows 2 sub-dirs

**Phase E — Leave/rejoin + final cleanup (2 commits):**
1. WorkspaceService.markLeft + rejoin API + tests (OQ-T5-2 resolution code lands)
2. Delete `OrgService.swift`, `OrgReader.swift`, `typealias Org = Workspace` shim, TeamKeystore single-key API shims. Final compile must be green; no `Org*` symbols remain.

**Phase F — Verification + ship (1 commit):**
- xcodebuild 5/5 schemes verification
- SPM test count check (expect ~2042-2062)
- Manual smoke (G1-G12) check off
- Shared memory `.claude/shared/current-state.md` update under "## Последнее обновление"
- Final commit: `docs(shared): Track 5 / S2 multiworkspace substrate ready for acceptance gate`
- Push to `feature/track-5-S2-multiworkspace-substrate`; NOT merged (Track 5 collective merge gate)

Total: ~13 commits across 6 phases. Plan doc (Stage 4) decomposes each phase into per-test/per-impl substeps per `superpowers:test-driven-development`.

---

## 14. Acceptance criteria recap

S2 ships when all G1-G12 from §2 pass on author's Mac. After merge to `feature/track-5-S2-multiworkspace-substrate`, the branch stays open awaiting Track 5 collective merge per Track 1/3/4 precedent.

S2 does **not gate** subsequent sub-phases — once on-device substrate is in place, S3 / S4 / S5 / S6 / S7 / S8 sub-phases can begin in parallel sessions consuming the multi-workspace data model.

---

## 15. Implementation plan

Detailed atomic-per-commit step-by-step plan lives in `docs/superpowers/plans/2026-05-14-track-5-S2-multiworkspace-substrate.md` (gitignored — moat), written next via `superpowers:writing-plans`. Plan covers:

- Sequential ordering of M019 / Schema / Database / TeamKeystore / WorkspaceService / ActiveWorkspaceStore / WorkspaceReader / UI consumers / final cleanup
- Per-step acceptance check (per `superpowers:test-driven-development` discipline)
- Commit message templates per `conventions.md` Git rules
- Manual smoke checklist for G11
- Independent review gate via superpowers:code-reviewer subagent

---

## 16. Whitepaper sync

S2 alone does not warrant whitepaper sync. Track 5 contract §19 specifies whitepaper sync happens at end of S8 (full Track 5 ship). S2 ship: shared memory `.claude/shared/current-state.md` updated only.

---

## 17. Living document

Per Track 5 contract §18, amendments expected during S2 implementation. Amendments inline annotated `> **Amendment YYYY-MM-DD (S2 impl):**`.

Already accepted amendments before implementation start:
- §14.1 of Track 5 contract — file-based keystore instead of Keychain (this spec §8.3)
- §5.3 substrate extension — adding `workspace_id` to rotation_outbox + pending_invites beyond contract literal scope

---

## 18. References

- Track 5 contract: [`2026-05-13-track-5-collaboration-contract.md`](2026-05-13-track-5-collaboration-contract.md)
- Track 5 S1 spec: [`2026-05-13-track-5-S1-backend-foundation.md`](2026-05-13-track-5-S1-backend-foundation.md)
- Phase 5.1 architecture contract: [`2026-05-04-phase-5-architecture-contract.md`](2026-05-04-phase-5-architecture-contract.md)
- Phase 5.1.A migrations precedent: [`2026-05-04-phase-5-1-A-migrations.md`](2026-05-04-phase-5-1-A-migrations.md)
- Phase 5.1.D OrgService precedent: [`2026-05-04-phase-5-1-D-org-service.md`](2026-05-04-phase-5-1-D-org-service.md)
- Existing TeamKeystore code: `Packages/LeafCore/Sources/LeafCore/Crypto/TeamKeystore.swift`
- Existing OrgService code: `Packages/LeafCore/Sources/LeafCore/Team/OrgService.swift`
- Existing M006/M007/M008 migrations: `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M00{6,7,8}_*.swift`
- GRDB documentation on `ALTER TABLE RENAME COLUMN`: https://www.sqlite.org/lang_altertable.html
- Brainstorm transcript: 2026-05-14 (current Claude session, D1-D11 design decisions)
