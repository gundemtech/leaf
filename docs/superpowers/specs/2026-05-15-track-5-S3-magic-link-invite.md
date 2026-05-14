# Track 5 / S3 — Magic-Link Invite

**Sub-phase of:** Track 5 — Collaboration Redesign ([contract](2026-05-13-track-5-collaboration-contract.md))
**Status:** Draft (2026-05-15)
**Branch (this repo):** `feature/track-5-S3-magic-link-invite` (off `feature/track-5-S2-multiworkspace-substrate`)
**Parallel branch (leaf-relay):** `feature/track-5-S3-magic-link-invite`
**Owner-side:** Local Claude (Mac) writes Swift + TypeScript. VPS Claude deploys Edge Functions after merge (per Track 5 contract §17).
**Workflow:** 8 stages per `conventions.md` "Одна phase = одна сессия"

---

## 1. Purpose

S3 ships the **first end-to-end Track 5 user feature**: magic-link invite handshake over Supabase. After S3 merges + VPS deploy:

- Admin clicks `Invite` → Leaf generates an opaque link `leaf://invite/<token>?w=<workspace>&a=<admin_pubkey>` and copies it to clipboard
- Invitee clicks the link (on any device with Leaf installed) → the app activates → modal previews workspace name from URL → click `Join` → Leaf performs ECDH+HKDF handshake → workspace materializes locally → invitee row appears in admin's workspace_members
- The default flow has **no manual OTP entry** (URL token has 122-bit entropy; opt-in 6-digit OTP exists as a second factor for paranoid mode)
- Mac client now has its **first piece of network code talking to Supabase** — base `SupabaseClient` with anonymous auth + JWT-bearing reads/writes against RLS-protected tables
- `register_pubkey` Edge Function bridges Supabase Auth `auth.uid()` to Leaf X25519 pubkey identity (the missing piece from S1)
- `invite_resolve` Edge Function replaces the S1 stub with real atomic-claim semantics

S3 closes Track 5 UC-T5-1 (Track 5 contract §2) and is the **first sub-phase to put Track 5 substrate in front of a user.**

---

## 2. Goal — fitness function

S3 is **done** when locally (on author's Mac, with `supabase start` running) all of the following hold:

| # | Check | How to verify |
|---|---|---|
| **G1** | `SupabaseClient.signInAnonymously` works against local stack | SPM integration test posts to `/auth/v1/signup?grant_type=anonymous` and gets back access token + user.id |
| **G2** | `SupabaseClient.registerPubkey` inserts pubkey_registry row | SPM integration test calls register_pubkey Edge Function, verifies row appears via service_role SELECT |
| **G3** | `SupabaseClient.resolveInvite` returns canonical response for valid token | SPM integration test seeds a row in invites, calls invite_resolve, verifies response shape + atomic claim mutation |
| **G4** | `SupabaseClient.resolveInvite` returns 404 for claimed/expired/missing token | SPM integration test exercises three failure modes |
| **G5** | `SupabaseClient.postInvite` writes to invites table with proper FK | SPM integration test posts invite, verifies invites row + workspace_id FK validated |
| **G6** | `SupabaseClient.insertWorkspaceMember` writes through RLS-protected JWT | SPM integration test post-handshake inserts membership row using JWT with `pubkey` claim |
| **G7** | New `InviteURL` Track 5 format parser round-trips | SPM unit test on InviteURL `compose(...)` ∘ `parse(...)` for required + optional OTP variants |
| **G8** | `InviteService.generateInvite(workspaceID:, inviteePubkeyHex:, requireOTP:)` posts to Supabase | SPM integration test asserts invite row written + URL returned matches Track 5 contract §12.1 shape |
| **G9** | `InviteAcceptService.acceptInvite(url:displayName:otp:)` materializes workspace via Supabase + ECDH | SPM E2E integration test: admin generates → invitee accepts → workspace + members + teamKey rows materialized on invitee |
| **G10** | `register_pubkey` + `invite_resolve` Edge Functions pass Deno unit tests | `deno test supabase/functions/{register_pubkey,invite_resolve}/test.ts` exit 0 |
| **G11** | pgTAP coverage extends `invites` lifecycle + `pubkey_registry` TOFU | New tests `130_invites_atomic_claim.test.sql` + `140_register_pubkey_tofu.test.sql` exit 0 |
| **G12** | All existing SPM tests pass + new ones | `swift test --package-path Packages/LeafCore` exits 0; expected count ~2065-2105 (baseline 2025 from S2; +40-80 net new for SupabaseClient + InviteService rewire + new URL parser + auth bootstrap) |
| **G13** | xcodebuild 5/5 schemes green | `xcodebuild -scheme {Leaf,LeafAgent,LeafMCP,LeafCore,LeafCorePrivate}` all exit 0 |
| **G14** | Independent code review APPROVED | superpowers:code-reviewer subagent emits APPROVED verdict (0 Critical / 0 Important) |
| **G15** | Manual smoke — two-Mac magic-link round-trip | Admin Mac (alpha build) generates invite, copies URL → other Mac running same build clicks URL → AcceptInviteSheet activates → Join → workspace appears in OrganizationView → admin's pill-row shows invitee within ~3s |
| **G16** | Manual smoke — opt-in OTP round-trip | Admin toggles `Require OTP` ON → URL + 6-digit code emitted → invitee Mac clicks URL → modal shows OTP field → invitee enters wrong OTP → "OTP doesn't match" → enter correct → Join → joined |
| **G17** | Contract amendments landed if needed | Any amendments to Track 5 contract §12 or §5.1 inlined per §18 with date+source annotation |

Track 5 acceptance gate (UC-T5-1 through UC-T5-7) closes UC-T5-1 with G15-G16 passing.

---

## 3. Out of S3 scope

Explicitly **not** in this sub-phase:

- Direct messages tables, UI, APNs delivery — S4
- Auto-shared events broadcast loop — S5
- Cross-post Slack / Linear write APIs — S6
- Team UI redesign (unified feed, pill-row members, sticky Send sheet, workspace switcher in Sidebar) — S7
- Tier-gating + MCP `leaf_query_team` + Settings restructure — S8
- Old Cloudflare `/v1/invite/*` endpoint removal — Track 6 cleanup (S3 stops writing/reading them; endpoints stay deployed but become dead code)
- Old Cloudflare key rotation endpoints (`/v1/key-rotation/*`) — sunset out-of-scope; S3 does **not** touch `RotationFetchService` / `KeyRotationService` Cloudflare wiring (these will migrate to Supabase in a later sub-phase or follow-up)
- Phase 5.5 `pending_invites` polling / auto-poll loop — S3 keeps the local table; UI continues to render rows but the "is it claimed" lookup migrates from Cloudflare polling to Supabase polling, which S3 wires via the same `invite_resolve` Edge Function (read-only flavor — `?probe=1` query parameter; see §6.4). Real-time push of `claimed_at` changes via Supabase Realtime is deferred to S4.
- Supabase Realtime WebSocket subscription wiring (used by Admin pill-row live update post-acceptance) — S3 settles for periodic polling + manual refresh; Realtime is wired in S4 when first DM subscription appears
- `share_rules` / Share Controls UI — S5
- iCloud sync of `active_workspace_id` across user's Macs — out of MVP
- Right-to-deletion hard-wipe of workspace data — S8 Settings restructure

### 3.1 Legacy code disposition

S3 is Track 5-first. Phase 5.5 was a parallel earlier exploration that produced shippable substrate but never crossed its two-Mac smoke gate. S3 supersedes the Phase 5.5 invite stack. Specifically:

| Phase 5.5 artifact | S3 disposition |
|---|---|
| `InviteURL` (`leaf://invite/<32>#<otp>` strict format) | Rewritten in place to Track 5 §12 format. No backward-compat parser for the old shape; previous-format URLs in clipboards become inert (the parser falls into `.malformed`). |
| `RelayClient.postInvite` / `getInvite` / `deleteInvite` | Callers (`InviteService` / `InviteAcceptService` / `InviteOutboxReader`) stop calling these methods. Methods stay in source temporarily (still referenced by carry-over rotation code paths), marked `@available(*, deprecated, message: "Track 5 / S3 — Supabase replaces Cloudflare invite endpoints.")`. Full removal is part of Track 6 cleanup. |
| `RelayClient.postKeyRotation` / `getKeyRotation` / etc. | Unchanged. Key rotation stays on Cloudflare until a separate later migration (out of S3 scope). |
| `InviteService.generateInvite(workspaceID:, inviteePubkeyHex:)` signature | Extended with `requireOTP: Bool = false` parameter and Supabase backend. Existing callers (Phase 5.5 admin UI) updated. |
| `InviteAcceptService.fetchInvite(inviteURL:)` / `fetchInvite(token:)` | Removed (Cloudflare-specific two-step fetch). Replaced by `InviteAcceptService.acceptInvite(url:displayName:otp:)` — single async call wrapping resolve + decrypt + materialize. |
| `ClipboardMatcher` (Phase 5.5.B clipboard auto-detect) | Kept as-is; it's a UX nicety orthogonal to S3 wire protocol. |
| `pending_invites` SQLCipher table + `PendingInvitesStore` (admin local tracking) | Schema unchanged (M010 + S2 `workspaceID`). Insert path moves: when InviteService.generateInvite succeeds, write a `pending_invites` row with the Supabase-issued token. Polling path moves: PendingInvitesStore polls `invite_resolve?probe=1` (see §6.4) instead of `RelayClient.getInvite`. |
| `JoinCode` (Phase 5.5.B admin paste-invitee-pubkey path) | Unchanged. Admin still pastes invitee Join code to capture pubkey; S3 just rewrites the downstream "generate invite" call. |
| `InviteBlob` / `InviteBlobCodec` (LeafCorePrivate moat — AES-GCM crypto over plaintext) | Unchanged. Same blob bytes shape stored in Supabase `invites.encrypted_teamkey` column. |
| `InviteKDF` / `KeyAgreement` (ECDH + HKDF derivation) | Unchanged. Same wrap key derivation. |
| `IdentityService.ensureLocalIdentity` (X25519 device identity) | Unchanged. |
| `InvitePlaintext` (encrypted JSON inside blob) | Unchanged. Carries `org_id` JSON key (semantically workspace id post-M019). |

The principle: **Track 5 contract is the source of truth**, not "preserve Phase 5.5 substrate". Where 5.5 crypto / data primitives happen to map cleanly onto S3 needs, they're reused. Where 5.5 wire format (URL, HTTP wire to Cloudflare) conflicts with Track 5 contract §12, it's replaced.

---

## 4. Architecture

### 4.1 End-state data flow (admin → invitee)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Admin Mac (existing workspace "Acme Corp", admin = self)                    │
│                                                                              │
│  1. UI: GenerateInviteSheet                                                  │
│     - Paste invitee Join code → bytes → hex                                  │
│     - [Require OTP] toggle (default OFF)                                     │
│                                                                              │
│  2. InviteService.generateInvite(workspaceID:, inviteePubkeyHex:,            │
│                                  requireOTP:)                                │
│     a. Read workspace + admin member + active teamKey + teamKey bytes        │
│     b. Compute ECDH(self_priv, invitee_pub) → shared                         │
│     c. Compute wrap key = HKDF(shared, salt = otp_bytes_or_empty,            │
│                                  info = spec_constant)                       │
│     d. AES-GCM-encrypt(InvitePlaintext{teamKey, workspaceID, ...}) → blob    │
│     e. Lazily bootstrap Supabase auth (signInAnonymously + register_pubkey)  │
│     f. JWT-bearing POST → invites table                                      │
│        Body: { workspace_id, admin_pubkey, encrypted_teamkey (base64url),    │
│                expires_at (now+24h), require_otp, otp_hash (HKDF-SHA256(otp))│
│                  IF require_otp else NULL }                                  │
│        Returns: { token: uuid }                                              │
│     g. (Existing local audit) INSERT INTO pending_invites (workspace_id,     │
│                                                            token, otp, ...)  │
│     h. Build URL: leaf://invite/<b64url-uuid>?w=<urlencoded_name>&a=<hex>    │
│        + #<6-digit-otp> IF require_otp                                       │
│     i. Return (InviteOutbound{ url, otp_or_nil, expiresAt })                 │
│                                                                              │
│  3. UI: GenerateInviteSheet                                                  │
│     - Copy URL to clipboard (one button)                                     │
│     - If requireOTP: show 6-digit OTP in separate panel with copy button     │
│     - Countdown 24h                                                          │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │  Admin pastes URL into Slack / iMessage
                                     │  (+ OTP via separate channel if required)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Invitee Mac (cold launch OR app already running)                            │
│                                                                              │
│  1. macOS opens leaf://invite/... → Leaf scenePhase activates                │
│     → LeafApp.onOpenURL fires                                                │
│     → InviteURLHandler.handle(url) parses, routes to InviteAcceptReader      │
│                                                                              │
│  2. UI: AcceptInviteSheet appears                                            │
│     - Header preview from URL: "Join `Acme Corp` team?"                      │
│     - (admin pubkey shown abbreviated: "ABCD1234… as inviter")                │
│     - [Your display name] field                                              │
│     - [Join] button (calls accept)                                           │
│                                                                              │
│  3. InviteAcceptService.acceptInvite(url:displayName:otp:)                   │
│     a. Parse url → token (b64url uuid), workspaceName, adminPubkeyHex,       │
│        otp (from #fragment) or nil                                           │
│     b. If url's #fragment has otp but UI also accepted manual otp →          │
│        UI passes whichever is present; otp absent if require_otp=false       │
│     c. Lazily bootstrap Supabase auth (signInAnonymously                     │
│                                            + register_pubkey(self_pubkey))   │
│     d. SupabaseClient.resolveInvite(token: <b64url-uuid>, invitee_pubkey)    │
│        → POST /functions/v1/invite_resolve with body                         │
│          { token, invitee_pubkey }                                           │
│        → No JWT required (token is the auth)                                 │
│        → Edge Function uses service_role + atomic UPDATE                     │
│        → Response: { encrypted_teamkey (base64url),                          │
│                      admin_pubkey, workspace_id, workspace_name,             │
│                      require_otp, expires_at }                               │
│     e. If response.require_otp=true and otp is nil/empty → throw .otpRequired│
│     f. If response.workspace_name != url's workspaceName → log warning       │
│        but proceed with server-canonical name (URL is unauthenticated)       │
│     g. Compute ECDH(self_priv, admin_pubkey_from_response) → shared          │
│        (admin_pubkey_from_response == admin_pubkey from URL but trust server)│
│     h. Compute wrap key = HKDF(shared, salt=otp_or_empty, info=spec_const)   │
│     i. AES-GCM-decrypt(encrypted_teamkey, wrap_key) → teamKey + plaintext    │
│        On AEAD tag mismatch (wrong OTP / tampered ciphertext) → .otpInvalid  │
│     j. (Existing logic from InviteAcceptService.acceptInvite step 9-11) —    │
│        rejoin OR fresh-insert path:                                          │
│        - If workspaces[id].leftAt != nil → clearWorkspaceLeftAt + insert self│
│        - If workspaces[id] exists with leftAt == nil → throw .alreadyAccepted│
│        - Else → upsertWorkspace + insertAdminMember + insertSelfMember +     │
│                 insertTeamKey                                                │
│     k. TeamKeystore.writeTeamKey(teamKey, workspaceID, keyID)                │
│     l. Refresh Supabase session → JWT now carries `pubkey` claim             │
│        (Auth Hook injects from pubkey_registry)                              │
│     m. SupabaseClient.insertWorkspaceMember(workspace_id,                    │
│                                              pubkey: self_pubkey,            │
│                                              display_name: ...)              │
│        → JWT-bearing INSERT (RLS allows because pubkey claim matches body)   │
│     n. Return AcceptedInvite                                                 │
│                                                                              │
│  4. UI: AcceptInviteSheet                                                    │
│     - Success state: "Joined Acme Corp"                                      │
│     - WorkspaceReader.refresh() → ActiveWorkspaceStore.setActive(workspaceID)│
│     - Sheet auto-dismisses after 1.5s                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │  Admin's Leaf polls workspace_members
                                     │  (S3) or receives Realtime push (S4)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Admin Mac                                                                   │
│  - OrganizationView pill-row shows invitee within ~3s of acceptance         │
│  - pending_invites row updates: claimed_at = ... (next poll tick reflects)  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Cross-repo file layout

**leaf (this repo) — Swift changes:**

```
Packages/LeafCore/Sources/LeafCore/
├── Network/                                       NEW directory
│   ├── SupabaseClient.swift                       NEW
│   ├── SupabaseAuthSession.swift                  NEW — session+token storage
│   ├── SupabaseEndpoint.swift                     NEW — URL composition + headers
│   ├── SupabaseError.swift                        NEW — wire error mapping
│   └── SupabaseConfig.swift                       NEW — Bundle reader for URL + anonKey
├── URLScheme/
│   └── InviteURL.swift                            REWRITTEN to Track 5 §12 format
├── Team/
│   ├── InviteService.swift                        REWRITE — Supabase POST path
│   └── InviteAcceptService.swift                  REWRITE — Supabase resolve path
└── Relay/
    └── RelayClient.swift                          Mark invite methods deprecated

Leaf/
├── Models/
│   ├── InviteAcceptReader.swift                   UPDATE — single-call accept
│   ├── InviteOutboxReader.swift                   UPDATE — Supabase POST result
│   └── PendingInvitesReader.swift                 UPDATE — Supabase probe poll
├── AppLifecycle/
│   └── InviteURLHandler.swift                     UPDATE — Track 5 URL parser
└── Views/Window/
    ├── Organization/AcceptInviteSheet.swift       UPDATE — preview + OTP conditional
    └── Team/GenerateInviteSheet.swift             UPDATE — opt-in OTP toggle
```

**leaf-relay (private repo) — Edge Function changes:**

```
supabase/
├── functions/
│   ├── invite_resolve/
│   │   ├── index.ts                               REWRITE — real body
│   │   └── test.ts                                NEW — Deno unit tests
│   └── register_pubkey/                           NEW directory
│       ├── index.ts                               NEW
│       └── test.ts                                NEW
└── tests/database/
    ├── 130_invites_atomic_claim.test.sql          NEW pgTAP
    └── 140_register_pubkey_tofu.test.sql          NEW pgTAP
```

### 4.3 Composition root wiring (LeafApp)

`LeafApp` already builds `WorkspaceReader` + `ActiveWorkspaceStore` (S2 substrate). S3 adds:

```swift
@main
struct LeafApp: App {
    @State private var activeWorkspaceStore = ActiveWorkspaceStore()
    @State private var workspaceReader: WorkspaceReader
    @State private var supabaseClient: SupabaseClient

    init() {
        let active = ActiveWorkspaceStore()
        let supabase = SupabaseClient(
            baseURL: SupabaseConfig.baseURL(from: Bundle.main),
            anonKey: SupabaseConfig.anonKey(from: Bundle.main),
            identity: { try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) }
        )
        self._activeWorkspaceStore = State(initialValue: active)
        self._workspaceReader = State(
            initialValue: WorkspaceReader(activeStore: active)
        )
        self._supabaseClient = State(initialValue: supabase)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(workspaceReader)
                .environment(activeWorkspaceStore)
                .environment(supabaseClient)
                .onOpenURL { inviteURLHandler.handle($0) }
        }
    }
}
```

`InviteService` / `InviteAcceptService` consume `SupabaseClient` via constructor injection (not `@Environment` — service layer doesn't bind to SwiftUI). UI readers (`InviteAcceptReader`, `InviteOutboxReader`) construct the services with `@Environment(SupabaseClient.self)` ambient.

---

## 5. Magic-link URL format

### 5.1 Track 5 §12 native format

```
leaf://invite/<token>?w=<workspace_name>&a=<admin_pubkey_hex>[#<otp>]
```

> **Amendment 2026-05-15 (S3 spec):** Track 5 contract §12.1 pseudocode used long parameter keys `?workspace=<name>&admin=<pubkey>`. S3 shortens to `?w=&a=` to save ~24 URL characters (workspace pubkey is already 64 hex chars; total URL stays ~120-140 chars instead of ~150-170). Substantive equivalence — keys are opaque to user. Living-doc per Track 5 contract §18.

| Component | Encoding | Length | Required |
|---|---|---|---|
| Scheme | `leaf` (lowercase) | 4 | Yes |
| Host | `invite` (lowercase) | 6 | Yes |
| Path | `/<token>` — base64url-encoded UUID v4, no padding | 23 (`/` + 22) | Yes |
| `w` query | `<workspace_name>`, URL-percent-encoded (RFC 3986) | ≤ 64 chars after decode | Yes |
| `a` query | `<admin_pubkey>`, 64 hex chars lowercase | 64 | Yes |
| Fragment | `<otp>`, 6 ASCII digits | 6 | Only when `require_otp=true` |

Total URL length: ~120-180 characters depending on workspace name. Fits Slack DM (40000 char limit), iMessage, Telegram, email.

### 5.2 Token encoding (base64url-uuid)

Supabase `invites.token` is `uuid PRIMARY KEY DEFAULT gen_random_uuid()` (16 bytes random). Mac client encodes the 16-byte raw representation to base64url-no-padding (22 chars):

```swift
extension UUID {
    var base64URLString: String {
        let bytes = withUnsafeBytes(of: self.uuid) { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var s = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4 for Data(base64Encoded:)
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: s), data.count == 16 else { return nil }
        let uuid: uuid_t = data.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self.init(uuid: uuid)
    }
}
```

Server stores native `uuid`. Client encodes for URL, decodes for `invite_resolve` POST body.

Token entropy: 122 bits (UUID v4 minus 6 fixed version/variant bits). Brute-force at Edge Function default limit (~50 req/s per IP) is computationally infeasible.

### 5.3 InviteURL.swift API

```swift
public enum InviteURL {
    public struct Composed: Sendable, Equatable {
        public let url: URL
        public let token: String        // 22-char base64url-uuid
        public let workspaceName: String
        public let adminPubkeyHex: String
        public let otp: String?         // nil when require_otp=false
    }

    public struct Parsed: Sendable, Equatable {
        public let token: String        // 22-char base64url-uuid
        public let workspaceName: String
        public let adminPubkeyHex: String
        public let otp: String?
    }

    public static func compose(token: String,
                               workspaceName: String,
                               adminPubkeyHex: String,
                               otp: String?) -> Composed

    public static func parse(_ url: URL) -> Result<Parsed, InviteURLError>
}

public enum InviteURLError: Error, Sendable, Equatable {
    case malformed
    case unsupportedVersion   // reserved for future format extensions
}
```

Parser rules (strict — any deviation = `.malformed`):

1. `scheme.lowercased() == "leaf"`
2. `host.lowercased() == "invite"`
3. Path = `/<22 base64url chars>` — chars from `[A-Za-z0-9_-]`
4. `URLComponents.queryItems` contains exactly two entries with names `w` and `a` (in any order)
5. `w` value non-empty after percent-decode, length ≤ 64
6. `a` value matches `^[0-9a-f]{64}$` (lowercase hex)
7. Fragment is either absent OR exactly 6 ASCII digits

No extra query items, no trailing slash, no nested path.

### 5.4 Backward compatibility

The pre-S3 format `leaf://invite/<32-base64url-token>#<otp>` falls under rule 3 (32-char vs 22-char path). It does NOT match the new strict parser → `.malformed` error → `InviteURLHandler` logs and ignores. No backward-compat fallback parser — Phase 5.5 invites in flight at S3 ship time become inert. This is acceptable because Phase 5.5 has not been distributed to alpha users.

---

## 6. SupabaseClient design

### 6.1 Public surface

```swift
public actor SupabaseClient {
    public init(baseURL: URL,
                anonKey: String,
                urlSession: URLSession = .shared,
                identity: @escaping @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey,
                now: @escaping @Sendable () -> Date = { Date() })

    // MARK: - Auth bootstrap (lazy, idempotent)
    public func ensureAuthenticated() async throws -> SupabaseAuthSession

    // MARK: - Edge Functions
    public func registerPubkey() async throws
    public func resolveInvite(token: String,
                              inviteePubkeyHex: String) async throws -> ResolvedInvite
    public func probeInvite(token: String) async throws -> InviteProbeStatus

    // MARK: - REST (PostgREST) — JWT-bearing
    public func postInvite(workspaceID: String,
                           adminPubkeyHex: String,
                           encryptedTeamkey: Data,
                           expiresAt: Date,
                           requireOTP: Bool,
                           otpHashBase64: String?) async throws -> IssuedInvite
    public func insertWorkspaceMember(workspaceID: String,
                                      pubkeyHex: String,
                                      displayName: String) async throws

    // MARK: - Lifecycle (for tests + sign-out)
    public func signOut()
}
```

### 6.2 Authentication state machine

```
.notAuthenticated
       │
       │  ensureAuthenticated()
       ▼
.bootstrapping                         (in-flight signInAnonymously + registerPubkey)
       │
       ├── failure → .notAuthenticated (caller throws SupabaseError.authBootstrapFailed)
       │
       ▼
.authenticated(session)                (session has access_token + pubkey claim populated)
       │
       │  401 from REST → tries refresh once
       ▼
.refreshing
       │
       ├── refresh success → .authenticated(newSession)
       └── refresh failure → .notAuthenticated
```

`SupabaseAuthSession` is an actor-local value type:

```swift
public struct SupabaseAuthSession: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let userID: UUID
    public let expiresAt: Date
    public let pubkeyClaim: String?       // populated after first refresh post-registerPubkey
}
```

Session is **not persisted to disk** in S3 — fresh `signInAnonymously` on each cold launch. Threat: server-side allocates a new auth.users row per launch. Mitigation: minor — Supabase Auth scales to millions of users; throwaway anonymous users are explicitly supported. Carry-over to S4: persist refresh_token in Keychain to avoid re-signup churn (orthogonal to S3 scope; S4 makes auth state long-lived for APNs token registration).

### 6.3 ensureAuthenticated orchestration

```swift
public func ensureAuthenticated() async throws -> SupabaseAuthSession {
    if case .authenticated(let s) = state, s.expiresAt > now() { return s }
    if case .bootstrapping(let task) = state { return try await task.value }

    let task = Task { try await self.performBootstrap() }
    state = .bootstrapping(task)
    do {
        let session = try await task.value
        state = .authenticated(session)
        return session
    } catch {
        state = .notAuthenticated
        throw error
    }
}

private func performBootstrap() async throws -> SupabaseAuthSession {
    // 1. signInAnonymously
    let initial = try await performSignInAnonymously()

    // 2. register_pubkey (idempotent on retry — UNIQUE pubkey allows ON CONFLICT)
    try await performRegisterPubkey(accessToken: initial.accessToken)

    // 3. Refresh session — new JWT carries `pubkey` claim from Auth Hook
    let refreshed = try await performRefresh(refreshToken: initial.refreshToken)

    return refreshed
}
```

Concurrent callers of `ensureAuthenticated` from multiple sheets (admin Generate + invitee Accept on the same Mac, hypothetically) share the in-flight bootstrap Task via `case .bootstrapping(let task)`. Idempotency via `case .authenticated` short-circuit.

### 6.4 Edge Function vs PostgREST routing

Two HTTP shapes:

| Operation | Path | Auth header | Body shape |
|---|---|---|---|
| `signInAnonymously` | `POST /auth/v1/signup?grant_type=anonymous` | `apikey: <anon_key>` | empty JSON `{}` |
| `register_pubkey` | `POST /functions/v1/register_pubkey` | `Authorization: Bearer <access_token>` | `{ "pubkey": "<64-hex>" }` |
| `invite_resolve` | `POST /functions/v1/invite_resolve` | none (anon) — token IS auth | `{ "token": "<uuid-string>", "invitee_pubkey": "<64-hex>" }` |
| `invite_resolve (probe)` | `POST /functions/v1/invite_resolve` | none | `{ "token": "<uuid>", "probe": true }` — read-only, no claim mutation |
| `postInvite` | `POST /rest/v1/invites` | `Authorization: Bearer <access_token>` + `apikey: <anon_key>` | invite row JSON (see §6.6) |
| `insertWorkspaceMember` | `POST /rest/v1/workspace_members` | `Authorization: Bearer <access_token>` + `apikey: <anon_key>` | membership row JSON |

### 6.5 Wire body — POST /rest/v1/invites (admin generate)

```json
{
  "workspace_id": "<uuid>",
  "admin_pubkey": "<64-hex>",
  "encrypted_teamkey": "\\x<hex bytes>",
  "expires_at": "<iso8601>",
  "require_otp": false,
  "otp_hash": null
}
```

Note: PostgREST encodes/decodes `bytea` as hex with `\x` prefix by default (the PostgreSQL canonical bytea hex format). `SupabaseClient.postInvite` encodes blob bytes via `"\\x" + bytes.map { String(format: "%02x", $0) }.joined()`. The Edge Function response separately uses base64url for the same field (we control that shape directly) — see §6.6. URL token still uses base64url (§5.2). Three encodings coexist by design: bytea hex (PostgREST wire), base64url (Edge Function JSON), base64url (URL token).

RLS policy on `invites` (from S1 §6.4) blocks public reads. INSERT is gated through service_role (Edge Function path) OR through JWT-bearing admin with workspace ownership check. S1 schema currently has **no public INSERT policy on invites** — only `service_role` can write. S3 amends RLS to allow workspace-admin INSERT:

> **Amendment 2026-05-15 (S3 spec):** Track 5 contract §5.2 + S1 §6.4 — `invites` table RLS extended with admin INSERT policy: `CREATE POLICY invites_admin_insert ON invites FOR INSERT WITH CHECK (admin_pubkey = (auth.jwt() ->> 'pubkey') AND public.is_workspace_admin(workspace_id, auth.jwt() ->> 'pubkey'))`. SELECT/UPDATE/DELETE stay service_role-only (resolve mutation goes through invite_resolve Edge Function; admin doesn't read invites table directly — it polls invite_resolve?probe=1). Reason: avoid an extra `insert_invite` Edge Function for a write that's safely RLS-gated.

### 6.6 Wire body — POST /functions/v1/invite_resolve (invitee resolve)

Request:
```json
{ "token": "<uuid-string-36-chars>", "invitee_pubkey": "<64-hex>" }
```

Response (200):
```json
{
  "encrypted_teamkey": "<base64url no-pad>",
  "admin_pubkey": "<64-hex>",
  "workspace_id": "<uuid>",
  "workspace_name": "<utf8 string>",
  "require_otp": false,
  "expires_at": "<iso8601>"
}
```

Error responses:
- `400` — bad payload shape → `SupabaseError.badRequest`
- `404` — token not found / already claimed / expired → `SupabaseError.inviteNotResolvable` → caller maps to `LeafError.inviteAlreadyConsumed`
- `429` — rate-limit → `SupabaseError.rateLimited`
- `5xx` → `SupabaseError.serverError`

### 6.7 Wire body — POST /functions/v1/invite_resolve (probe variant)

For admin-side `pending_invites` UI polling without consuming the invite:

Request:
```json
{ "token": "<uuid-string>", "probe": true }
```

Response (200):
```json
{
  "status": "pending" | "claimed" | "expired" | "not_found",
  "claimed_at": "<iso8601 | null>",
  "claimed_by_pubkey": "<hex | null>",
  "expires_at": "<iso8601>"
}
```

Probe path bypasses the atomic claim mutation — SELECT only. Returns minimal data (no encrypted_teamkey leak; admin already has it locally).

### 6.8 Configuration (Bundle wiring)

`SupabaseConfig.swift` reads `LeafSupabaseURL` + `LeafSupabaseAnonKey` from Info.plist (substituted from xcconfig at build time):

```swift
public enum SupabaseConfig {
    public static func baseURL(from bundle: Bundle = .main) -> URL {
        guard let s = bundle.object(forInfoDictionaryKey: "LeafSupabaseURL") as? String,
              let url = URL(string: s) else {
            preconditionFailure("LeafSupabaseURL missing or malformed in Info.plist")
        }
        return url
    }

    public static func anonKey(from bundle: Bundle = .main) -> String {
        guard let s = bundle.object(forInfoDictionaryKey: "LeafSupabaseAnonKey") as? String,
              !s.isEmpty else {
            preconditionFailure("LeafSupabaseAnonKey missing in Info.plist")
        }
        return s
    }
}
```

xcconfig additions (build-time substitution):

```
// Leaf/Leaf.xcconfig
SUPABASE_URL = https://jwxnhwyqjzjmjnmwpwyq.supabase.co
SUPABASE_ANON_KEY = $(SUPABASE_ANON_KEY_FROM_ENV)
```

`SUPABASE_ANON_KEY_FROM_ENV` populated from `.env.xcconfig.local` (gitignored) for local dev OR from CI secret in release builds. Pattern mirrors existing OAuth client IDs (`LeafGitHubOAuthClientID` / etc).

> **Note:** Supabase `anon_key` is a public JWT-like token signed with the project's JWT secret; safe to embed in client binaries. RLS is the security boundary, not the key.

---

## 7. register_pubkey Edge Function

### 7.1 Purpose

Bridge Supabase Auth `auth.users.id` (UUID) to Leaf X25519 pubkey (hex). Required so the Auth Hook (S1 §7.2.2 `custom_access_token_hook`) can inject the `pubkey` claim into the JWT, which all other RLS policies depend on.

S3 ships this Edge Function (the S1 spec deferred it — S1 §7.2.3).

### 7.2 Body

```typescript
// supabase/functions/register_pubkey/index.ts
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing_authorization" }, 401);

  // Verify caller's JWT (anonymous or authenticated)
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: "unauthorized" }, 401);

  // Parse body
  let body: { pubkey?: unknown };
  try { body = await req.json(); } catch { return json({ error: "bad_payload" }, 400); }
  const pubkey = body.pubkey;
  if (typeof pubkey !== "string" || !/^[0-9a-f]{64}$/.test(pubkey)) {
    return json({ error: "invalid_pubkey" }, 400);
  }

  // TOFU INSERT with conflict policy
  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { error: insertErr } = await serviceClient
    .from("pubkey_registry")
    .insert({ auth_id: user.id, pubkey });

  if (insertErr) {
    // Idempotent on retry — auth_id PK conflict means same user re-calling
    if (insertErr.code === "23505") {  // PostgreSQL unique_violation
      // Distinguish: PK conflict (same auth_id, same pubkey) is idempotent OK.
      // UNIQUE pubkey conflict (same pubkey, different auth_id) is TOFU-loss.
      const { data: existing } = await serviceClient
        .from("pubkey_registry")
        .select("pubkey")
        .eq("auth_id", user.id)
        .maybeSingle();
      if (existing?.pubkey === pubkey) {
        return json({ ok: true, idempotent: true }, 200);
      } else {
        // Two cases: (a) auth_id PK collision with different pubkey,
        //   (b) UNIQUE(pubkey) collision with different auth_id (TOFU loser).
        return json({ error: "pubkey_already_registered" }, 409);
      }
    }
    return json({ error: "insert_failed", detail: insertErr.message }, 500);
  }

  return json({ ok: true, idempotent: false }, 200);
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
```

### 7.3 TOFU semantics

- First (auth_id, pubkey) pair wins. Both UNIQUE constraints in S1 `pubkey_registry` schema (`auth_id PK`, `pubkey UNIQUE`).
- Retry by same caller (auth_id) with same pubkey → idempotent OK (200, `{ ok: true, idempotent: true }`).
- Retry by same caller (auth_id) with different pubkey → 409 (auth_id already claimed) — shouldn't happen in practice; device only has one X25519 priv.
- Retry by different caller (auth_id) with already-registered pubkey → 409 (pubkey already taken). TOFU-loser receives error and must escalate to admin recovery (out of S3; user-visible error code `pubkey_already_registered`).

### 7.4 Carry-over: Ed25519 challenge-response

Post-S3 hardening: replace TOFU with signature proof. Generate Ed25519 signing key alongside X25519 agreement key in `IdentityService`; sign a challenge derived from `auth.uid()`. Edge Function verifies signature. Out of S3 (tracked carry-over for S8 / post-Track 5).

---

## 8. invite_resolve Edge Function (real body)

### 8.1 Two-mode dispatch

```typescript
// supabase/functions/invite_resolve/index.ts
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: { token?: unknown; invitee_pubkey?: unknown; probe?: unknown };
  try { body = await req.json(); } catch { return json({ error: "bad_payload" }, 400); }
  const token = body.token;
  if (typeof token !== "string" || !isValidUUID(token)) {
    return json({ error: "invalid_token" }, 400);
  }

  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  if (body.probe === true) {
    return await handleProbe(serviceClient, token);
  }

  const inviteePubkey = body.invitee_pubkey;
  if (typeof inviteePubkey !== "string" || !/^[0-9a-f]{64}$/.test(inviteePubkey)) {
    return json({ error: "invalid_invitee_pubkey" }, 400);
  }

  return await handleClaim(serviceClient, token, inviteePubkey);
});
```

### 8.2 Atomic claim mutation

```typescript
async function handleClaim(client, token: string, inviteePubkey: string) {
  // Atomic: UPDATE ... WHERE conditions ... RETURNING — fail-on-already-claimed
  const { data, error } = await client.rpc("claim_invite", {
    _token: token,
    _invitee_pubkey: inviteePubkey,
    _now: new Date().toISOString(),
  });
  if (error) return json({ error: "claim_failed", detail: error.message }, 500);
  if (!data || data.length === 0) return json({ error: "not_resolvable" }, 404);

  const row = data[0];
  // Lookup workspace name (join would have required RLS bypass on workspaces too —
  // use service_role read instead).
  const { data: ws } = await client
    .from("workspaces")
    .select("name")
    .eq("id", row.workspace_id)
    .maybeSingle();

  return json({
    encrypted_teamkey: bytesToBase64URL(row.encrypted_teamkey),
    admin_pubkey: row.admin_pubkey,
    workspace_id: row.workspace_id,
    workspace_name: ws?.name ?? "",
    require_otp: row.require_otp,
    expires_at: row.expires_at,
  }, 200);
}
```

The Postgres function `claim_invite` (defined in migration 13 — see §8.4) does the atomic claim in a single statement:

```sql
CREATE OR REPLACE FUNCTION public.claim_invite(
  _token uuid,
  _invitee_pubkey text,
  _now timestamptz
) RETURNS TABLE (
  workspace_id uuid,
  admin_pubkey text,
  encrypted_teamkey bytea,
  require_otp boolean,
  expires_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE invites
    SET claimed_at = _now,
        claimed_by_pubkey = _invitee_pubkey
    WHERE token = _token
      AND claimed_at IS NULL
      AND expires_at > _now
    RETURNING workspace_id, admin_pubkey, encrypted_teamkey, require_otp, expires_at;
$$;

GRANT EXECUTE ON FUNCTION public.claim_invite TO service_role;
REVOKE EXECUTE ON FUNCTION public.claim_invite FROM authenticated, anon, public;
```

### 8.3 Probe mode

```typescript
async function handleProbe(client, token: string) {
  const { data, error } = await client
    .from("invites")
    .select("expires_at, claimed_at, claimed_by_pubkey")
    .eq("token", token)
    .maybeSingle();
  if (error) return json({ error: "probe_failed", detail: error.message }, 500);
  if (!data) return json({ status: "not_found" }, 200);

  const now = new Date();
  let status: "pending" | "claimed" | "expired";
  if (data.claimed_at !== null) status = "claimed";
  else if (new Date(data.expires_at) <= now) status = "expired";
  else status = "pending";

  return json({
    status,
    claimed_at: data.claimed_at,
    claimed_by_pubkey: data.claimed_by_pubkey,
    expires_at: data.expires_at,
  }, 200);
}
```

### 8.4 New migration M013 (Supabase, claim_invite RPC + RLS amendment)

`supabase/migrations/20260515120000_invite_claim_fn.sql`:

```sql
-- Track 5 / S3 — atomic claim RPC for invite_resolve Edge Function.

CREATE OR REPLACE FUNCTION public.claim_invite(...) ...;
GRANT ... REVOKE ...;

-- RLS amendment per S3 spec §6.5 — admin INSERT path
CREATE POLICY invites_admin_insert ON invites FOR INSERT
  WITH CHECK (
    admin_pubkey = (auth.jwt() ->> 'pubkey')
    AND public.is_workspace_admin(workspace_id, auth.jwt() ->> 'pubkey')
  );
```

This is a new Supabase migration (M013) on top of S1's M001-M012. Filename `20260515120000_invite_claim_fn.sql`.

---

## 9. InviteService rewire (admin path)

### 9.1 New signature

```swift
public struct InviteService: Sendable {
    public init(
        database: Database,
        supabase: SupabaseClient,
        inviteKDF: any InviteKDF,
        inviteBlobCodec: any InviteBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomOTP: @escaping @Sendable () throws -> String = InviteService.secureRandomOTP,
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    )

    public func generateInvite(workspaceID: String,
                               inviteePubkeyHex: String,
                               requireOTP: Bool = false) async throws -> InviteOutbound

    public func generateInvite(workspaceID: String,
                               inviteeJoinCode: String,
                               requireOTP: Bool = false) async throws -> InviteOutbound

    public func revokeInvite(token: String) async throws  // Future: PATCH invites SET expires_at=now()
}

public struct InviteOutbound: Sendable, Hashable {
    public let token: String              // 22-char base64url-uuid
    public let url: URL                   // leaf://invite/<token>?w=...&a=...[#<otp>]
    public let otp: String?               // nil when requireOTP=false
    public let expiresAtMs: Int64
    public let inviteePubkeyHex: String
}
```

Constructor change: `relayClient: RelayClient` → `supabase: SupabaseClient`.

### 9.2 generateInvite orchestration

```swift
public func generateInvite(workspaceID: String,
                           inviteePubkeyHex: String,
                           requireOTP: Bool = false) async throws -> InviteOutbound {
    // 1. Validate hex (64 chars, [0-9a-fA-F])
    guard inviteePubkeyHex.count == 64,
          inviteePubkeyHex.allSatisfy({ $0.isHexDigit }) else {
        throw LeafError.invalidPayload
    }
    let inviteeHex = inviteePubkeyHex.lowercased()

    // 2-4. Read workspace / self / active teamKey scoped to workspaceID (unchanged from S2 surface)
    guard let workspace = try database.readWorkspace(id: workspaceID) else {
        throw LeafError.databaseUnavailable
    }
    let members = try database.readTeamMembers(workspaceID: workspace.id, includeRemoved: false)
    guard let selfMember = members.first else { throw LeafError.databaseUnavailable }
    guard let activeKey = try database.readActiveTeamKey(workspaceID: workspace.id) else {
        throw LeafError.databaseUnavailable
    }
    let teamKeyBytes = try TeamKeystore.readTeamKey(
        workspaceID: workspace.id, keyID: activeKey.id, at: keystoreRoot
    )

    // 5. Identity
    let priv = try identity()

    // 6. OTP — only generated when requireOTP=true. KDF salt = "" otherwise (per D6: ECDH provides primary security; OTP is opt-in augmentation).
    let otp: String? = requireOTP ? try randomOTP() : nil
    let kdfOTP: String = otp ?? ""

    // 7. ECDH
    let shared = try KeyAgreement.sharedSecret(privateKey: priv, peerPublicKeyHex: inviteeHex)

    // 8. Wrap key
    let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: kdfOTP)

    // 9. Plaintext + blob
    let nowMs = Int64(now().timeIntervalSince1970 * 1000)
    let plaintext = InvitePlaintext(
        teamKeyBase64: teamKeyBytes.base64EncodedString(),
        teamKeyID: activeKey.id,
        orgID: workspace.id,
        orgName: workspace.name,
        adminMemberID: selfMember.id,
        adminDisplayName: selfMember.displayName,
        issuedAtMs: nowMs
    )
    let blob = try inviteBlobCodec.encode(
        plaintext, adminPubkey: priv.publicKey.rawRepresentation, wrapKey: wrapKey
    )

    // 10. OTP hash for server-side check (only when requireOTP). Salt label + HMAC construction
    // live in ProdInviteKDF (LeafCorePrivate moat); public InviteService just delegates.
    let otpHashBase64: String? = otp.map { otpVal in
        inviteKDF.hashOTPForServerStorage(otp: otpVal).base64EncodedString()
    }

    // 11. POST to Supabase invites table (via SupabaseClient)
    let expiresAtMs = nowMs + 24 * 60 * 60 * 1000
    let issued = try await supabase.postInvite(
        workspaceID: workspace.id,
        adminPubkeyHex: priv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
        encryptedTeamkey: blob.bytes,
        expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000),
        requireOTP: requireOTP,
        otpHashBase64: otpHashBase64
    )

    // 12. Compose URL
    let adminHex = priv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    let composed = InviteURL.compose(
        token: issued.tokenBase64URL,
        workspaceName: workspace.name,
        adminPubkeyHex: adminHex,
        otp: otp
    )

    return InviteOutbound(
        token: issued.tokenBase64URL,
        url: composed.url,
        otp: otp,
        expiresAtMs: expiresAtMs,
        inviteePubkeyHex: inviteeHex
    )
}
```

### 9.3 OTP hash format

Server stores `otp_hash bytea` (S1 `invites` schema). S3 client-side HMAC computation (salt label + HMAC construction) lives in `ProdInviteKDF.hashOTPForServerStorage(otp:)` — LeafCorePrivate moat per architecture contract §6. Public `InviteService` calls the protocol method, never touches the salt directly. Output: 32 bytes → base64 over the wire → bytea in DB. Client never sends raw OTP to server; only invitee receives raw OTP via separate channel.

> **Note on OTP server-side verification:** S3 Edge Function does NOT verify the OTP server-side. The OTP is only used in HKDF for wrap key derivation. If invitee submits wrong OTP, the AES-GCM decryption fails (tag mismatch) → `LeafError.otpInvalid`. The `otp_hash` column is reserved for future server-side rate-limit (lock out after N failed attempts) — but S3 ships only the hash without checks. **Implementation note:** keep `otp_hash` column populated but unused server-side; document carry-over.

> **Amendment 2026-05-15 (S3 spec):** Track 5 contract §12.3 implies server-side OTP verification but is intentionally vague. S3 implements the security guarantee via crypto only (AES-GCM tag check) without server-side hash compare. The `otp_hash` column is populated for future hardening but not consulted. This matches Phase 5.2's existing pattern (no server-side OTP check). Reason: simpler MVP; equivalent security (server doesn't see plaintext OTP either way).

---

## 10. InviteAcceptService rewrite (invitee path)

### 10.1 New surface

```swift
public struct InviteAcceptService: Sendable {
    public init(
        database: Database,
        supabase: SupabaseClient,
        inviteKDF: any InviteKDF,
        inviteBlobCodec: any InviteBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil,
        generateMemberID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    )

    /// Track 5 / S3 — single-call accept. Wraps URL parse + resolve + decrypt + materialize.
    /// otp is mutable: pre-filled from URL fragment if present; UI populates if absent + required.
    public func acceptInvite(url: URL,
                             displayName: String,
                             otp: String?) async throws -> AcceptedInvite

    /// Preview from URL only — no network call. For UI header before user commits.
    public static func preview(url: URL) -> Result<URLPreview, InviteURLError>
}

public struct URLPreview: Sendable, Equatable {
    public let workspaceName: String      // from URL (unverified — server canonical comes from resolve)
    public let adminPubkeyHex: String     // from URL
    public let token: String              // 22-char base64url-uuid
    public let hasFragmentOTP: Bool       // true means URL itself carries OTP (paranoid mode)
}
```

The old two-step `fetchInvite` + `acceptInvite` is collapsed into single `acceptInvite(url:displayName:otp:)`. Reason: Supabase resolve is atomic claim; we don't want intermediate state where blob is fetched but not yet materialized — too easy to lose the claim if user closes the app.

### 10.2 acceptInvite orchestration

```swift
public func acceptInvite(url: URL,
                         displayName: String,
                         otp: String?) async throws -> AcceptedInvite {
    // 1. Validate inputs
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw LeafError.invalidPayload }

    // 2. Parse URL
    let parsed: InviteURL.Parsed
    switch InviteURL.parse(url) {
    case .success(let p): parsed = p
    case .failure: throw LeafError.inviteURLMalformed
    }

    // 3. Decode token to UUID (server expects uuid string)
    guard let tokenUUID = UUID(base64URLString: parsed.token) else {
        throw LeafError.inviteURLMalformed
    }
    let tokenString = tokenUUID.uuidString.lowercased()

    // 4. Identity
    let priv = try identity()
    let inviteePubkeyHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()

    // 5. Bootstrap Supabase auth (lazy — registerPubkey runs here if first time)
    _ = try await supabase.ensureAuthenticated()

    // 6. Atomic claim via Edge Function
    let resolved: ResolvedInvite
    do {
        resolved = try await supabase.resolveInvite(
            token: tokenString,
            inviteePubkeyHex: inviteePubkeyHex
        )
    } catch SupabaseError.inviteNotResolvable {
        throw LeafError.inviteAlreadyConsumed
    }

    // 7. OTP gating
    let effectiveOTP: String
    if resolved.requireOTP {
        guard let candidate = otp ?? parsed.otp, !candidate.isEmpty else {
            throw LeafError.inviteOTPRequired   // UI prompts for OTP entry
        }
        effectiveOTP = candidate
    } else {
        effectiveOTP = ""
    }

    // 8. Trust server's admin_pubkey + workspace_id. URL params are unverified.
    let adminPubHex = resolved.adminPubkey
    let workspaceID = resolved.workspaceID
    let workspaceName = resolved.workspaceName   // server-canonical

    // 9. ECDH + HKDF + decrypt
    let shared = try KeyAgreement.sharedSecret(privateKey: priv,
                                               peerPublicKeyHex: adminPubHex)
    let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: effectiveOTP)
    let blob = InviteBlob(bytes: resolved.encryptedTeamkey)
    let plaintext: InvitePlaintext
    do {
        plaintext = try inviteBlobCodec.decode(blob, wrapKey: wrapKey)
    } catch LeafError.inviteOTPInvalid, LeafError.inviteBlobMalformed {
        throw LeafError.inviteOTPInvalid
    }

    // 10. Validate plaintext.orgID matches resolved.workspaceID (defense-in-depth)
    guard plaintext.orgID == workspaceID else {
        throw LeafError.inviteBlobMalformed
    }

    // 11. Decode teamKey bytes
    guard let teamKeyBytes = Data(base64Encoded: plaintext.teamKeyBase64),
          teamKeyBytes.count == 32 else {
        throw LeafError.inviteBlobMalformed
    }

    // 12. Build value types (mirror S2 InviteAcceptService.acceptInvite step 9)
    let acceptedAt = now()
    let issuedAt = Date(timeIntervalSince1970: TimeInterval(plaintext.issuedAtMs) / 1000)
    let workspaceRow = Workspace(id: workspaceID,
                                 name: workspaceName,
                                 createdAt: issuedAt,
                                 createdByMemberID: plaintext.adminMemberID)
    let adminMember = TeamMember(id: plaintext.adminMemberID,
                                 workspaceID: workspaceID,
                                 role: .admin,
                                 pubkeyHex: adminPubHex,
                                 displayName: plaintext.adminDisplayName,
                                 addedAt: issuedAt, removedAt: nil)
    let selfMemberID = generateMemberID()
    let selfMember = TeamMember(id: selfMemberID,
                                workspaceID: workspaceID,
                                role: .member,
                                pubkeyHex: inviteePubkeyHex,
                                displayName: trimmedName,
                                addedAt: acceptedAt, removedAt: nil)
    let teamKey = TeamKey(id: plaintext.teamKeyID,
                          workspaceID: workspaceID,
                          generatedAt: issuedAt,
                          deprecatedAt: nil,
                          generatedByMemberID: plaintext.adminMemberID)

    // 13. Keystore-first (S2 substrate — orphan file better than orphan DB rows)
    try TeamKeystore.writeTeamKey(teamKeyBytes,
                                  workspaceID: workspaceID,
                                  keyID: plaintext.teamKeyID,
                                  at: keystoreRoot)

    // 14. DB writes — same three-path logic from S2 acceptInvite (rejoin / already-member / fresh)
    if let existing = try database.readWorkspace(id: workspaceID) {
        guard existing.leftAt != nil else {
            throw LeafError.inviteAlreadyAccepted
        }
        try database.clearWorkspaceLeftAt(workspaceID: workspaceID)
        try database.insertTeamMember(selfMember)
        try database.insertTeamKeyIfAbsent(teamKey)
    } else {
        try database.upsertWorkspace(workspaceRow)
        try database.insertTeamMember(adminMember)
        try database.insertTeamMember(selfMember)
        try database.insertTeamKey(teamKey)
    }

    // 15. Push self to Supabase workspace_members with bounded in-process retry.
    //     Rationale: local workspace + teamKey already materialized; the only outstanding work is the remote membership row that admin's pill-row depends on. Failing this means admin can't see invitee until invitee retries.
    //     Retry policy: 3 attempts with backoff 200ms / 500ms / 2s. After 3 failures, the accept flow still returns success (local state is valid); UI surfaces a banner "Membership not yet synced — retry?" with a manual retry button bound to `supabase.insertWorkspaceMember`.
    //     Out of S3 scope: persistent retry across launches (would need a local outbox column). S4 introduces a general direct-message outbox pattern that subsumes this — when S4 lands, membership sync moves to the same outbox primitive.
    try await retryWithBackoff(attempts: 3, delays: [.milliseconds(200), .milliseconds(500), .seconds(2)]) {
        try await supabase.insertWorkspaceMember(
            workspaceID: workspaceID,
            pubkeyHex: inviteePubkeyHex,
            displayName: trimmedName
        )
    }
    // retryWithBackoff swallows the final error and stores it on a `lastSyncError` field on `AcceptedInvite` so the UI can render the retry banner. The accept path itself does NOT throw on remote-sync failure (local materialization is the source of truth).

    return AcceptedInvite(
        orgID: workspaceID,
        orgName: workspaceName,
        teamKeyID: plaintext.teamKeyID,
        selfMemberID: selfMemberID,
        membershipSyncStatus: membershipSyncStatus   // .ok or .pending(LeafError)
    )
}
```

`AcceptedInvite.membershipSyncStatus` extends Phase 5.2 struct:

```swift
public struct AcceptedInvite: Sendable, Hashable {
    public let orgID: String
    public let orgName: String
    public let teamKeyID: String
    public let selfMemberID: String
    public let membershipSyncStatus: MembershipSyncStatus
}

public enum MembershipSyncStatus: Sendable, Hashable {
    case ok                       // remote insert succeeded
    case pending(LeafError)       // remote insert failed; UI shows retry banner
}
```

### 10.3 New error cases

| LeafError | When | UI response |
|---|---|---|
| `inviteURLMalformed` | URL doesn't parse via Track 5 strict rules | "This link doesn't look like a valid Leaf invite." |
| `inviteAlreadyConsumed` | Edge Function returned 404 (claimed / expired / missing) | "This invite has expired or already been used." |
| `inviteOTPRequired` (NEW) | resolve.requireOTP=true and otp arg is nil/empty | Modal expands to show OTP field |
| `inviteOTPInvalid` | AES-GCM decryption failed (wrong OTP / tampered blob) | "OTP doesn't match. Try again." (retry-able) |
| `inviteBlobMalformed` | Blob structurally invalid (wrong length / version) | "Invite link is corrupted." (non-recoverable) |
| `inviteAlreadyAccepted` | Local workspace exists with `leftAt == nil` | "You're already in this team." |

`inviteOTPRequired` is a new error introduced by S3. Existing `inviteOTPInvalid` semantics preserved.

---

## 11. UI changes

### 11.1 GenerateInviteSheet (admin path)

Phase 5.5 GenerateInviteSheet currently shows: token + OTP, mandatory. S3 changes:

- **[Require OTP] toggle** at the top — default OFF. Tooltip: "Adds a 6-digit code that must be sent through a separate channel (e.g., iMessage if you sent the link via Slack)."
- When toggle ON → after generation, layout shows: large URL with [Copy] button + separate OTP card with [Copy] button + helper text "Send the 6-digit code through a different channel"
- When toggle OFF → after generation, layout shows: single URL with [Copy] button + helper text "Anyone with this link can join in the next 24 hours"
- 24h countdown timer unchanged
- [Revoke] button calls `supabase.postInvite` future-extension (or simply lets the invite expire) — S3 stub returns `success` immediately, real revoke implementation lands in S4 carry-over

### 11.2 AcceptInviteSheet (invitee path)

Phase 5.5 AcceptInviteSheet currently has: paste URL field + OTP field + display name + Join. S3 changes:

- **Entry by deep-link** — `InviteURLHandler.handle(url)` opens the sheet pre-filled with the URL. URL is hidden from UI (no paste field) — replaced by header preview from URL:
  ```
  ╔════════════════════════════════════════╗
  ║  Join "Acme Corp" team?                 ║
  ║                                         ║
  ║  Inviter: 0a1b2c3d… (admin)             ║
  ╚════════════════════════════════════════╝
  ```
- **[Your display name]** field — required, no length limit
- **OTP field** — initially hidden. After `resolveInvite` returns and `requireOTP=true`, UI expands the OTP field. Pre-fill from URL fragment if present (paranoid mode where admin embedded OTP in URL — rare but allowed)
- **[Join] button** — on click:
  1. Disable button, show spinner
  2. Call `InviteAcceptService.acceptInvite(url:, displayName:, otp:)`
  3. On `inviteOTPRequired` → expand OTP field, focus, show "Enter the 6-digit code from the inviter"
  4. On `inviteOTPInvalid` → keep OTP field, show inline error "OTP doesn't match — try again"
  5. On `inviteAlreadyConsumed` → show error banner "This invite expired or was already used" + [Close]
  6. On other errors → show error banner with retry button
  7. On success → "Joined Acme Corp" + auto-dismiss + WorkspaceReader.refresh

- **Manual paste fallback** — small text button "Paste a different link" reveals paste field (kept for users who copy URL manually rather than click)

### 11.3 InviteURLHandler (deep-link router)

Existing handler accepts `leaf://invite/<32>#<otp>` strict. S3 replaces parser invocation:

```swift
func handle(_ url: URL) {
    switch InviteURL.parse(url) {
    case .success:
        logger.info("opened deep-link invite — routing to AcceptReader")
        acceptReader?.fetch(inviteURL: url)
    case .failure:
        logger.warning("ignored non-matching URL scheme: \(url.absoluteString, privacy: .public)")
    }
}
```

API unchanged; behavior change is purely the parser swap. Clipboard auto-detect (`ClipboardMatcher`) updates the substring `needle` from `"leaf://invite/"` (unchanged prefix) — but parsing the matched URL goes through the new strict parser. Old-format URLs in clipboards become non-actionable.

### 11.4 InviteAcceptReader (UI state machine — `Leaf/Models/`)

Existing reader exposed `fetch(inviteURL:)` then `accept(otp:, displayName:)` two-call shape. S3 collapses to single async call + state transitions:

```swift
@MainActor
@Observable
final class InviteAcceptReader {
    enum State {
        case idle
        case previewing(preview: URLPreview, url: URL)
        case joining(url: URL)
        case otpPrompt(preview: URLPreview, url: URL)
        case error(LeafError, retryURL: URL?)
        case joined(AcceptedInvite)
    }

    private(set) var state: State = .idle
    private let acceptService: InviteAcceptService

    init(acceptService: InviteAcceptService) {
        self.acceptService = acceptService
    }

    func fetch(inviteURL url: URL) {
        switch InviteAcceptService.preview(url: url) {
        case .success(let p): state = .previewing(preview: p, url: url)
        case .failure: state = .error(.inviteURLMalformed, retryURL: nil)
        }
    }

    func join(displayName: String, otp: String?) async {
        guard case .previewing(let preview, let url) = state else { return }
        state = .joining(url: url)
        do {
            let accepted = try await acceptService.acceptInvite(url: url, displayName: displayName, otp: otp)
            state = .joined(accepted)
        } catch LeafError.inviteOTPRequired {
            state = .otpPrompt(preview: preview, url: url)
        } catch let leafError as LeafError {
            state = .error(leafError, retryURL: url)
        } catch {
            state = .error(.unknown, retryURL: url)
        }
    }
}
```

---

## 12. Test approach

### 12.1 Layered testing strategy

| Layer | Tooling | Scope |
|---|---|---|
| Swift unit | XCTest in SPM | URL parser/composer, KDF round-trip, error mapping, value-type equality |
| Swift integration (mocked) | XCTest + `MockURLSession` returning canned Supabase JSON | SupabaseClient state machine, retry logic, error code mapping |
| Swift integration (real local) | XCTest in SPM against `supabase start` | Full E2E flow: signup → registerPubkey → JWT refresh → invite POST → resolve → INSERT workspace_members |
| Edge Function unit | `deno test` in `supabase/functions/<fn>/test.ts` | Body shape parsing, mock Supabase client returns, error response shape |
| pgTAP | `supabase test db` | RLS policies for new admin INSERT path + atomic claim_invite RPC semantics |
| Manual smoke | Two-Mac alpha build | UC-T5-1 closure (golden path + opt-in OTP path) |

### 12.2 Swift test files

```
Packages/LeafCore/Tests/LeafCoreTests/
├── SupabaseClientTests.swift                          NEW
├── SupabaseClientAuthBootstrapTests.swift             NEW — ensureAuthenticated state machine
├── SupabaseClientResolveTests.swift                   NEW — invite_resolve wire mapping
├── SupabaseClientProbeTests.swift                     NEW — probe variant
├── SupabaseClientPostInviteTests.swift                NEW — admin POST shape
├── SupabaseClientWorkspaceMembersTests.swift          NEW — INSERT via JWT
├── SupabaseEndpointTests.swift                        NEW — URL composition / header set
├── SupabaseErrorMappingTests.swift                    NEW — 4xx/5xx → LeafError
├── InviteURLV3Tests.swift                             NEW — Track 5 §12 strict parser
├── InviteURLV3ComposeTests.swift                      NEW — composer + round-trip
├── InviteServiceTrackFiveTests.swift                  NEW — generateInvite with SupabaseClient mock
├── InviteAcceptServiceTrackFiveTests.swift            NEW — acceptInvite E2E with mocks
├── InviteServiceTests.swift                           RETROFIT — drop RelayClient assertions, add SupabaseClient
├── InviteAcceptServiceTests.swift                     RETROFIT — collapse two-step into single-call
├── InviteURLTests.swift                               DELETE — replaced by V3Tests (old format gone)
└── ClipboardMatcherTests.swift                        RETROFIT — old-format URLs now NOT matched
```

> **Test count expectation:**
> - Baseline post-S2: 2025 SPM tests.
> - S3 deletions: ~15 (old InviteURLTests cases for `#otp` format).
> - S3 retrofits: ~25 (InviteServiceTests + InviteAcceptServiceTests body updates without count change).
> - S3 additions: ~60-80 net new across SupabaseClient layer + new URL parser variants + new InviteService/InviteAcceptService Track 5 paths.
> - Expected after S3: **~2070-2090 SPM tests**.

### 12.3 Swift integration tests against local Supabase

Gated behind environment flag `LEAF_RUN_SUPABASE_INTEGRATION_TESTS=1` — skipped in CI default, runs locally when developer has `supabase start` active. Pattern:

```swift
final class SupabaseIntegrationTests: XCTestCase {
    override class func setUp() {
        guard ProcessInfo.processInfo.environment["LEAF_RUN_SUPABASE_INTEGRATION_TESTS"] == "1" else {
            // Skip class
            return
        }
    }
    ...
}
```

Avoids burdening CI with Docker requirement; lets author run full E2E locally before push.

### 12.4 Deno tests for Edge Functions

```typescript
// supabase/functions/register_pubkey/test.ts
import { assertEquals, assertExists } from "jsr:@std/assert";

Deno.test("register_pubkey rejects missing authorization", async () => {
  const res = await fetch("http://127.0.0.1:54321/functions/v1/register_pubkey", {
    method: "POST",
    body: JSON.stringify({ pubkey: "00".repeat(32) }),
  });
  assertEquals(res.status, 401);
});

Deno.test("register_pubkey accepts valid pubkey with anonymous JWT", async () => {
  const { token } = await signUpAnon();  // helper
  const res = await fetch(/* ... */, {
    method: "POST",
    headers: { "Authorization": `Bearer ${token}` },
    body: JSON.stringify({ pubkey: "ab".repeat(32) }),
  });
  assertEquals(res.status, 200);
});

Deno.test("register_pubkey TOFU rejects pubkey claimed by another auth_id", async () => {
  // Sign up two anon users; first registers pubkey X; second tries to register X.
  ...
  assertEquals(res2.status, 409);
});
```

Similar coverage for `invite_resolve` (atomic claim, probe variant, 404 paths).

### 12.5 pgTAP additions

```sql
-- supabase/tests/database/130_invites_atomic_claim.test.sql
BEGIN;
SELECT plan(6);

-- Seed
INSERT INTO workspaces (id, name, created_by_pubkey)
  VALUES ('00000000-0000-0000-0000-000000000001', 'TestWS', REPEAT('ad', 32));
INSERT INTO invites (token, workspace_id, admin_pubkey, encrypted_teamkey,
                     expires_at, require_otp)
  VALUES ('11111111-1111-1111-1111-111111111111',
          '00000000-0000-0000-0000-000000000001',
          REPEAT('ad', 32), '\x00', now() + interval '24 hours', false);

-- First claim succeeds, returns row
SELECT results_eq(
  $$SELECT count(*) FROM public.claim_invite(
      '11111111-1111-1111-1111-111111111111'::uuid,
      REPEAT('fe', 32),
      now()
    )$$,
  $$VALUES (1::bigint)$$,
  'first claim returns 1 row'
);

-- Second claim of same token returns 0 rows (atomic — already claimed)
SELECT results_eq(
  $$SELECT count(*) FROM public.claim_invite(
      '11111111-1111-1111-1111-111111111111'::uuid,
      REPEAT('cd', 32),
      now()
    )$$,
  $$VALUES (0::bigint)$$,
  'double claim returns 0 rows'
);

-- claimed_by_pubkey reflects first claimant
SELECT results_eq(
  $$SELECT claimed_by_pubkey FROM invites WHERE token = '11111111-...'::uuid$$,
  $$VALUES (REPEAT('fe', 32))$$,
  'claimed_by_pubkey set to first claimant'
);

-- Expired token returns 0 rows
INSERT INTO invites (...) VALUES (..., expires_at = now() - interval '1 hour');
SELECT results_eq(
  $$SELECT count(*) FROM public.claim_invite(..., now())$$,
  $$VALUES (0::bigint)$$,
  'expired invite cannot be claimed'
);

-- Probe SELECT (separate pattern)
SELECT results_eq(
  $$SELECT (claimed_at IS NOT NULL) FROM invites WHERE token = '11111111-...'::uuid$$,
  $$VALUES (true)$$,
  'probe shows claimed=true after claim'
);

-- Admin INSERT RLS allow
SET LOCAL "request.jwt.claims" = '{"pubkey": "<test-admin-pubkey>"}';
SELECT lives_ok(
  $$INSERT INTO invites (workspace_id, admin_pubkey, encrypted_teamkey,
                          expires_at, require_otp)
     VALUES ('<test-ws-uuid>', '<test-admin-pubkey>', '\x00',
             now() + interval '24 hours', false)$$,
  'admin can INSERT invite'
);

SELECT * FROM finish();
ROLLBACK;
```

```sql
-- supabase/tests/database/140_register_pubkey_tofu.test.sql
BEGIN;
SELECT plan(4);

-- Seed two auth.users
-- Test: first INSERT succeeds
-- Test: same auth_id + same pubkey is idempotent (would error via UNIQUE PK; expected by app to catch 23505 and treat as ok)
-- Test: different auth_id + same pubkey rejected (UNIQUE pubkey constraint)
-- Test: different auth_id + different pubkey accepted
SELECT * FROM finish();
ROLLBACK;
```

### 12.6 Manual smoke (G15-G16)

**Two-Mac alpha build setup:** Both Macs running `feature/track-5-S3-magic-link-invite` alpha build, talking to production Supabase (`leaf-backend`, Frankfurt). Independent X25519 identities. No pre-existing workspace.

**G15 — Golden path (no OTP):**
1. Admin Mac: Onboarding → Create workspace "TestRoom" → OrganizationView shows workspace
2. Admin Mac: Team tab → [+ Invite] → enter invitee's Join code (paste from invitee's onboarding screen) → toggle `Require OTP` OFF → click [Generate]
3. Admin Mac: URL copied to clipboard ("leaf://invite/...?w=TestRoom&a=..."). Send via iMessage to invitee.
4. Invitee Mac: receives iMessage, clicks link → Leaf activates → AcceptInviteSheet appears, header "Join `TestRoom` team?" + admin pubkey preview
5. Invitee Mac: enters display name "Bob" → [Join]
6. Within ~3s: invitee Mac OrganizationView updates to show "TestRoom" with members [admin, Bob]
7. Admin Mac OrganizationView (after manual refresh or periodic poll, S3 has no Realtime): pill-row updates to show invitee within ~30s

**G16 — Opt-in OTP path:**
1. Admin Mac: Team tab → [+ Invite] → enter invitee Join code → toggle `Require OTP` **ON** → [Generate]
2. Admin Mac: URL + OTP both shown. Copy URL → iMessage. Copy OTP → Telegram.
3. Invitee Mac: clicks URL → AcceptInviteSheet → enters display name → [Join]
4. Modal expands: "Enter the 6-digit code from the inviter" — invitee types **wrong code** → "OTP doesn't match — try again"
5. Invitee enters correct code → [Join] → success → joined

### 12.7 Privacy walkback

After implementation, audit that no plaintext-leaking fields cross the relay:

- `invites.encrypted_teamkey` — opaque bytes (✅)
- `invites.admin_pubkey` — hex (✅ — public by definition)
- `invites.workspace_id` — uuid (✅ — opaque to invitee until decrypt)
- `workspace_name` — UTF-8 text returned by invite_resolve to invitee. **Visible to Supabase server.** Acceptable per Track 5 contract §6 (E2E for messages; metadata like workspace names leak — same posture as Phase 5.5).
- `display_name` — UTF-8 text written to workspace_members. Visible to Supabase. Same posture.
- `pubkey_registry.pubkey` — hex (✅ — public by definition).

No prompt/response/keystroke/file-content fields ever cross relay. ADR-010 invariant preserved.

---

## 13. OQ resolutions

| OQ (from Track 5 contract §16) | S3 resolution |
|---|---|
| **OQ-T5-7** Old Cloudflare invite endpoints sunset timeline | **Partial.** S3 stops calling `/v1/invite/*` from new builds. Endpoints stay deployed serving in-flight pre-S3 invites (24h expiry → fully drained by S3 ship + 24h). Full removal in Track 6 cleanup. |

Other Track 5 contract OQs explicitly deferred (S2 closed OQ-T5-2 already; OQ-T5-3/4/5 belong to other sub-phases; OQ-T5-1/6/8/9 to S8 or post-Track-5).

---

## 14. Phase decomposition

S3 lands as a sequence of atomic commits, each compiling + tests green at the boundary (per `superpowers:test-driven-development`).

**Phase A — SupabaseClient foundation (3 commits):**

1. `feat(network): SupabaseClient skeleton + Bundle config` — new `LeafCore/Network/` directory with `SupabaseClient` actor, `SupabaseAuthSession` value type, `SupabaseEndpoint` URL composer, `SupabaseError` enum. No actual HTTP wire yet; pure type scaffolding. Unit tests for Endpoint URL composition + header sets.
2. `feat(network): SupabaseClient.signInAnonymously wire + state machine` — implement the auth state machine. Mocked URLSession returning fixture JSON. Tests: state transitions, concurrent caller deduplication, 401 retry logic.
3. `feat(network): SupabaseClient.registerPubkey + JWT refresh flow` — TOFU INSERT call; refresh session post-INSERT to pick up `pubkey` claim. Tests: idempotent retry, 409 mapping.

**Phase B — Edge Functions (2 commits, leaf-relay branch):**

4. `feat(edge): register_pubkey real body` — new `supabase/functions/register_pubkey/{index,test}.ts`. Deno unit tests for missing-auth / bad-payload / TOFU paths. Add migration M013 (claim_invite RPC scaffold + RLS amendment).
5. `feat(edge): invite_resolve real body with atomic claim` — rewrite `index.ts` for two-mode dispatch (claim + probe). Deno unit tests. Update pgTAP `130_invites_atomic_claim.test.sql` + `140_register_pubkey_tofu.test.sql`.

**Phase C — InviteURL Track 5 format (1 commit):**

6. `feat(url): InviteURL Track 5 §12 strict format` — rewrite `InviteURL.swift`. Delete InviteURLTests, add InviteURLV3Tests. Update `ClipboardMatcher` (only the regex / parse call; needle prefix unchanged).

**Phase D — Service rewires (2 commits):**

7. `feat(team): InviteService Track 5 — Supabase POST + URL composition` — rewrite `InviteService.swift`. Constructor swap. Add `requireOTP` parameter. Update `InviteOutbound` shape (URL field). Retrofit existing `InviteServiceTests` to use SupabaseClient mock instead of RelayClient mock. New `InviteServiceTrackFiveTests` for new URL output.
8. `feat(team): InviteAcceptService Track 5 — single-call accept` — collapse two-step into single-call. Update `InviteAcceptServiceTests` retrofit + add `InviteAcceptServiceTrackFiveTests`.

**Phase E — UI rewires (3 commits):**

9. `feat(app): InviteURLHandler + Reader Track 5 wiring` — update `InviteURLHandler.handle` (parser already swapped at Phase C). Rewrite `InviteAcceptReader` state machine. No new tests (UI plumbing).
10. `feat(ui): GenerateInviteSheet opt-in OTP toggle` — new toggle UI; conditional OTP card display. Manual smoke at this stage (G15 abbreviated).
11. `feat(ui): AcceptInviteSheet preview + conditional OTP` — header preview from URL; OTP expansion on `inviteOTPRequired`; success state. Manual smoke at this stage (G15 + G16 full).

**Phase F — Composition root + Auth bootstrap wiring (1 commit):**

12. `feat(app): LeafApp wires SupabaseClient into environment` — `LeafApp.init` constructs `SupabaseClient`, injects via `.environment`. `InviteAcceptReader` + `InviteOutboxReader` constructors updated to read SupabaseClient.

**Phase G — Verification + ship (1 commit):**

13. `docs(shared): Track 5 / S3 magic-link invite ready for acceptance gate` — final commit updating `.claude/shared/current-state.md`. Push feature branch. Independent code review subagent run. Awaits Track 5 collective merge gate.

Total: **13 commits** across 7 phases. Detailed per-step decomposition in plan doc (Stage 4).

---

## 15. Implementation plan

Detailed atomic-per-commit plan in `docs/superpowers/plans/2026-05-15-track-5-S3-magic-link-invite.md` (gitignored — moat), written next via `superpowers:writing-plans`.

---

## 16. VPS Claude handoff

After S3 merges into `gundemtech/leaf-relay` (collective Track 5 merge), hand off:

> Deploy Track 5 S3 Edge Functions. Code on `gundemtech/leaf-relay` main (post-Track-5-merge), subfolder `supabase/`.
>
> Tasks:
> 1. `cd ~/leaf-relay && supabase link --project-ref jwxnhwyqjzjmjnmwpwyq`
> 2. `supabase db push` — apply M013 (claim_invite RPC + admin INSERT RLS amendment)
> 3. `supabase functions deploy register_pubkey` — new function
> 4. `supabase functions deploy invite_resolve` — real body (replaces stub)
> 5. Smoke test: from local Mac running production-pointed build, generate test invite + resolve from second Mac. Verify atomic claim mutation (second resolve → 404).
> 6. Update `infra/CHANGELOG.md` in leaf-docs with deploy timestamp.
> 7. NO new secrets required (S3 doesn't introduce APNs / Slack / Linear credentials — those land S4/S6).
>
> Do NOT ship S4 / S5 / S6 / S7 / S8 work. VPS is deploy/infra only.

---

## 17. Acceptance criteria recap

S3 ships when all G1-G17 from §2 pass on author's Mac. After merge to `feature/track-5-S3-magic-link-invite`, the branch stays open awaiting Track 5 collective merge per Track 1/3/4 precedent.

S3 closes Track 5 UC-T5-1. Other UCs unblocked by S3:
- **UC-T5-6** (multi-workspace switcher) — substrate exists (S2); UI requires S7. S3 invite acceptance creates additional workspaces beyond the first — making S7 switcher meaningful.

---

## 18. Living document

Per Track 5 contract §18, amendments expected during S3 implementation. Inline-annotated `> **Amendment YYYY-MM-DD (S3 impl):**`.

Already accepted amendments before implementation start:
- Contract §5.2 — `invites` RLS extended with admin INSERT policy (this spec §6.5)
- Contract §12.3 — server-side OTP verification clarified as crypto-only (this spec §9.3)

---

## 19. Whitepaper sync

S3 alone does not warrant whitepaper sync. Track 5 contract §19 specifies whitepaper sync happens at end of S8 (full Track 5 ship). S3 ship: shared memory `.claude/shared/current-state.md` updated only.

---

## 20. References

- Track 5 contract: [`2026-05-13-track-5-collaboration-contract.md`](2026-05-13-track-5-collaboration-contract.md)
- Track 5 S1 spec: [`2026-05-13-track-5-S1-backend-foundation.md`](2026-05-13-track-5-S1-backend-foundation.md)
- Track 5 S2 spec: [`2026-05-14-track-5-S2-multiworkspace-substrate.md`](2026-05-14-track-5-S2-multiworkspace-substrate.md)
- Supabase Auth anonymous: https://supabase.com/docs/guides/auth/auth-anonymous
- Supabase Auth Hooks (custom_access_token_hook): https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook
- PostgREST: https://docs.postgrest.org/en/v12/
- Existing TeamKeystore (S2 surface): `Packages/LeafCore/Sources/LeafCore/Crypto/TeamKeystore.swift`
- Existing WorkspaceService (S2 surface): `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceService.swift`
- Existing InviteService (Phase 5.5 — to be rewritten): `Packages/LeafCore/Sources/LeafCore/Team/InviteService.swift`
- S1 RLS policies migration: `~/Desktop/Leaf/leaf-relay` `origin/feature/track-5-S1-supabase-foundation` `supabase/migrations/20260513120900_rls_policies.sql`
- S1 invites table migration: same branch `supabase/migrations/20260513120600_invites.sql`
- Brainstorm transcript: 2026-05-15 (current Claude session)
