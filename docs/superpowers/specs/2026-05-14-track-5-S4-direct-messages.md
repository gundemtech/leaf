# Track 5 / S4 — Direct Messages Primitive

**Sub-phase of:** Track 5 — Collaboration Redesign ([contract](2026-05-13-track-5-collaboration-contract.md))
**Status:** Draft (2026-05-14)
**Branch (this repo):** `feature/track-5-S4-direct-messages` (off `feature/track-5-S3-magic-link-invite`)
**Parallel branch (leaf-relay):** `feature/track-5-S4-direct-messages` (off S3 `2f1d5ee`)
**Owner-side:** Local Claude (Mac) writes Swift + TypeScript end-to-end. VPS Claude deploys Edge Functions + APNs secrets after merge per Track 5 contract §17.
**Workflow:** 8 stages per `conventions.md` "Одна phase = одна сессия"

---

## 1. Purpose

S4 ships the **direct-message primitive** — first user-to-user message channel on Track 5 substrate. After S4 merges + VPS deploy:

- Admin opens Team tab → clicks `Send` → modal: To=Dmitrii, Type=Handoff/Task/Ping, Message=text → Send
- Recipient receives APNs push within ≤5s warm / ≤30s cold; click on banner opens Leaf to message; reply inline
- Three template types — **Handoff** (one-shot context drop) / **Task** (open→done lifecycle) / **Ping** (lightweight nudge)
- Sender-attribution + workspace-scoped E2E (AES-GCM-256 under workspace teamKey, Supabase sees ciphertext + recipient_pubkey)
- Task reminders — Postgres cron sweeps tasks open >24h, dispatches APNs reminder push to recipient (one-shot per task)
- Local SQLCipher `messages_mirror` table preserves forever-retention timeline for both sender and recipient
- Mac client gains **first long-lived auth session** — refresh_token persisted in keystore (S3 carry-over I3)
- Standard APNs token-based authentication (.p8 key in Supabase secrets) — token-per-device per pubkey

S4 closes Track 5 **UC-T5-3** (Direct message — Handoff). UC-T5-4 (Task with Linear cross-post) needs S6 for the Linear write path; UC-T5-3 + base Task lifecycle (without cross-post) ship in S4.

---

## 2. Goal — fitness function

S4 is **done** when locally (on author's Mac with mocked URLSession + `supabase start` available) all of the following hold:

| # | Check | How to verify |
|---|---|---|
| **G1** | `messages_mirror` table created via M020 with all columns + 3 indexes | SPM migration test — open fresh DB, M020 runs, table schema matches spec §5.1 |
| **G2** | `apns_token_local` table created via M021 (singleton per device_id) | SPM migration test — insert + read back single row; second insert UPSERTs |
| **G3** | `DirectMessageBlobCodec` round-trip (encode → decode == plaintext) under teamKey, AES-GCM tag tampering rejected | SPM unit tests — golden plaintext + tamper-each-byte coverage in LeafCorePrivateTests |
| **G4** | `DirectMessageService.send` orchestrates encrypt + POST + local mirror INSERT | SPM integration test with mocked SupabaseClient — verifies single-pass write, returns SentDirectMessage |
| **G5** | `DirectMessageInboxService.tick` fetches inbound, decrypts, INSERTs into mirror (dedupe by message_id) | SPM integration test — second tick is idempotent (no duplicate rows) |
| **G6** | `SupabaseClient.sendDirectMessage` posts JWT-bearing INSERT to direct_messages with correct PostgREST bytea encoding | SPM integration test against mocked URLSession — verifies request shape + parses response |
| **G7** | `SupabaseClient.fetchInboundMessages` decodes PostgREST `direct_messages` rows correctly (bytea decode, ISO8601 timestamp) | SPM integration test — multi-row response, bytea hex → Data, returns ordered |
| **G8** | `SupabaseClient.markRead` / `.markDone` issues PATCH via PostgREST with proper filter | SPM integration test against mocked URLSession |
| **G9** | `SupabaseClient.registerAPNsToken` writes to apns_tokens via JWT (RLS allows self) | SPM integration test against mocked URLSession |
| **G10** | `SupabaseClient.triggerAPNsPush` invokes apns_push Edge Function with body shape (workspace_id, recipient_pubkey, message_id, title) | SPM integration test against mocked URLSession |
| **G11** | `SupabaseSessionStore` persists refresh_token to keystore; cold launch loads existing session and skips signup | SPM integration test — write session → read back → assert refresh_token survives |
| **G12** | `apns_push` Edge Function builds ES256 JWT for APNs and POSTs to api.push.apple.com (mocked APNs endpoint URL via env override for tests) | Deno unit tests — verifies JWT header/payload, body shape, error mapping (400/403/410) |
| **G13** | `task_reminders` Edge Function selects open tasks > 24h, calls apns_push for each, INSERTs into task_reminder_log (idempotent) | Deno unit tests — fixture DB with 3 tasks (1 open <24h, 1 open >24h with no reminder, 1 already reminded) → only middle one is reminded |
| **G14** | M013 Supabase migration creates task_reminder_log table + updates task_reminders cron body to invoke Edge Function via pg_net | pgTAP test — schema check + cron schedule check |
| **G15** | Direct message UPDATE RLS allows recipient mark_read + mark_done; rejects sender attempt to UPDATE someone else's row | pgTAP test extending existing rls tests |
| **G16** | InviteHandshakeIntegrationTests.swift.disabled-track5-s3 → not retrofitted here, but new `DirectMessageHandshakeIntegrationTests.swift` covers full E2E (send → fetch → decrypt → mirror INSERT) under mocked URLSession | SPM integration test in LeafCorePrivateTests |
| **G17** | New `SendDirectMessageSheet` UI reads workspace members from WorkspaceReader; renders 3 template types; dispatches DirectMessageService.send | XCTest UI smoke + manual local verification (build + open Team) |
| **G18** | All existing SPM tests pass + new ones | `swift test --package-path Packages/LeafCore` exits 0; expected count ~2120-2160 (baseline 2060 from S3 + ~60-100 net new) |
| **G19** | xcodebuild 5/5 schemes green | `xcodebuild -scheme {Leaf,LeafAgent,LeafMCP,LeafCore,LeafCorePrivate}` all exit 0 |
| **G20** | Independent code review APPROVED | superpowers:code-reviewer subagent emits APPROVED verdict (0 Critical / 0 Important) |
| **G21** | Manual smoke deferred to acceptance gate — documented in §15 (UC-T5-3 two-Mac smoke; needs real APNs delivery via signed build) | Spec carries explicit deferred-smoke notation |

Track 5 acceptance gate (UC-T5-1 through UC-T5-7) closes UC-T5-3 (and partial UC-T5-4 without Linear write) with G21 manual smoke passing.

---

## 3. Out of S4 scope

Explicitly **not** in this sub-phase:

- Auto-shared events broadcast loop (`team_events` mirror + `share_rules` table M020 → renumbered, see §17) — S5
- Cross-post Slack / Linear write APIs (Channels picker disabled in Send sheet with "Coming in S6" tooltip) — S6
- Send sheet attach-event picker (attach button disabled with "Coming in S5" tooltip) — S5
- Full Team UI redesign (unified feed, pill-row members, sticky Send sheet integration) — S7
- MCP `leaf_query_team` tool — S8
- Tier-gating on Send (S8)
- Supabase Realtime WebSocket subscription (S4 ships polling-first MVP; Realtime is non-blocking enhancement post-S4)
- Workspace switcher polish for >5 workspaces (Sidebar bottom list — S7)
- 1-level deep threading UI (reply chain rendered nested) — S4 ships schema + service path; UI renders flat with "↰ Replied to <excerpt>" annotation; full nested rendering deferred to S7
- Settings → Notifications config UI (per-type toggle for Handoff/Task/Ping/etc) — S8
- VoIP push for instant wake (OQ-T5-4 resolved as **standard APNs** — see §11)
- macOS Notification Service Extension for content modification — out of MVP (notification title-only payload per privacy invariant; no decryption-in-NSE required)
- iCloud sync of mirror rows across user's Macs — out of MVP

### 3.1 Legacy code disposition

S3 left two carry-overs that S4 addresses:

| S3 carry-over | S4 disposition |
|---|---|
| **I3** — `SupabaseClient` doesn't persist refresh_token; second cold launch re-signs in. | S4 **fixes**: new `SupabaseSessionStore` (file-backed JSON in keystore root, 0o600). `SupabaseClient.init` loads on first auth; refresh saves. Repeat cold launches re-use same anon auth.users row. (S3 spec §6.2 explicitly assigned this to S4.) |
| **I2** — `InviteAcceptService` remaps `inviteBlobMalformed` → `inviteOTPInvalid`. | **Not addressed in S4.** I2 needs codec error-model refactor; carry to Track 6 cleanup per S3 §18. |

No deprecation of S3-era invite path. S4 is additive — new tables, new service, new UI sheet, new Edge Function bodies (apns_push + task_reminders). Existing invite path stays untouched.

---

## 4. Architecture

### 4.1 End-state data flow (sender → recipient)

```
┌────────────────────────────────────────────────────────────────────────────┐
│  Sender Mac                                                                 │
│                                                                             │
│  1. UI: SendDirectMessageSheet                                              │
│     - To: dropdown of workspace members (excluding self)                    │
│     - Type: segmented Handoff / Task / Ping                                 │
│     - Message: textarea (no length limit)                                   │
│     - Attach: disabled placeholder "Coming in S5"                           │
│     - Channels: Leaf (locked ON) + Slack (disabled) + Linear (disabled)     │
│     - Notify: toggle (default ON)                                           │
│     - [Send]                                                                │
│                                                                             │
│  2. DirectMessageService.send(workspaceID:, recipientPubkeyHex:,            │
│                               recipientMemberID:, kind:, body:,             │
│                               replyTo:?, notify:)                           │
│     a. Validate body non-empty + length cap (64KB safety)                   │
│     b. Read workspace + active teamKey + teamKey bytes (32B)                │
│     c. Read self team_member (senderMemberID, senderDisplayName)            │
│     d. Generate messageID = UUID.lowercased()                               │
│     e. Build DirectMessagePlaintext (JSON-encoded inside blob)              │
│     f. directMessageBlobCodec.encode(plaintext, keyID, teamKey) → blob      │
│        [version:1B=0x03 | keyID:16B | nonce:12B | ciphertext | tag:16B]     │
│     g. supabase.sendDirectMessage(workspaceID:, recipientPubkeyHex:,        │
│                                   kind:, encryptedPayload: blob.bytes,      │
│                                   replyTo:?)                                │
│        → POST /rest/v1/direct_messages                                      │
│        → Returns: { message_id, created_at }                                │
│     h. INSERT into local messages_mirror (own copy — sender's timeline)     │
│     i. If notify=ON: fire-and-forget supabase.triggerAPNsPush(              │
│            workspaceID:, recipientPubkeyHex:, messageID:,                   │
│            titleText: "<sender> sent a <kind>")                             │
│        → POST /functions/v1/apns_push                                       │
│        (failure is non-fatal — message persists; UI shows "Push pending")   │
│     j. Return SentDirectMessage { messageID, createdAt }                    │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │  (via Supabase)
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  Supabase                                                                   │
│                                                                             │
│  - direct_messages INSERT (RLS gated: sender = JWT pubkey)                  │
│  - apns_push Edge Function service_role:                                    │
│    1. Look up apns_tokens WHERE pubkey = $recipient → tokens[]              │
│    2. For each token: build APNs JWT (ES256, .p8 key from secrets)          │
│    3. POST https://api.push.apple.com/3/device/<token>                      │
│       headers: authorization: bearer <JWT>,                                 │
│                apns-topic: tech.gundem.leaf, apns-push-type: alert          │
│       body: { aps: { alert: { title }, sound, thread-id },                  │
│               leaf_message_id, leaf_workspace_id }                          │
│    4. On 410 Unregistered: DELETE stale apns_tokens row                     │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │  (APNs delivers push to recipient device)
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  Recipient Mac                                                              │
│                                                                             │
│  3. App wakes on push (warm app: immediate; cold app: launchd start ≤30s)   │
│     - NSUserNotificationCenterDelegate captures push                        │
│     - DirectMessageInboxService.tickOnce(forMessageID:) — eager fetch       │
│                                                                             │
│  4. DirectMessageInboxService.tick (also runs on scenePhase=active +        │
│                                     30s foreground / 5min background)      │
│     a. Read lastFetchedAtMs from messages_mirror MAX(created_at)            │
│     b. supabase.fetchInboundMessages(workspaceID:,                          │
│                                       sinceCreatedAtISO:?, limit: 100)      │
│        → GET /rest/v1/direct_messages?workspace_id=eq.X                     │
│                &recipient_pubkey=eq.SELF                                    │
│                &order=created_at.asc                                        │
│                &created_at=gt.SINCE                                         │
│        → Returns: [{ message_id, sender_pubkey, kind,                       │
│                      encrypted_payload (hex), created_at, ... }, ...]       │
│     c. For each row: peek envelope keyID → resolve teamKey →                │
│            directMessageBlobCodec.decode → DirectMessagePlaintext           │
│     d. INSERT INTO messages_mirror (idempotent — UPSERT by message_id PK)   │
│     e. Read mirror state → DirectMessageInboxReader publishes update        │
│                                                                             │
│  5. UI: Team feed (placeholder section in TeamView for S4 — fully           │
│         redesigned in S7)                                                   │
│     - New messages appear chronologically                                   │
│     - User scrolls to message → DirectMessageService.markRead(messageID)    │
│         → supabase.markRead → PATCH .read_at = now                          │
│     - For Task kind: [Mark done] button → markDone(messageID, doneByPub)    │
│         → supabase.markDone → PATCH .done_at = now                          │
│     - For Handoff/Task: [Reply] button opens SendSheet pre-populated        │
│         with reply_to = parent_message_id                                   │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │  (24h later — task_reminders cron)
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  Supabase cron — pg_cron schedule "0 9 * * *"                              │
│                                                                             │
│  cron body: SELECT net.http_post(                                           │
│    url := 'https://<project>.functions.supabase.co/functions/v1/            │
│            task_reminders',                                                 │
│    body := '{}',                                                            │
│    headers := jsonb_build_object('Authorization', 'Bearer <svc_role_jwt>')  │
│  )                                                                          │
│                                                                             │
│  task_reminders Edge Function:                                              │
│    1. SELECT message_id, workspace_id, sender_pubkey, recipient_pubkey      │
│       FROM direct_messages                                                  │
│       WHERE kind='task' AND done_at IS NULL                                 │
│             AND created_at < now() - interval '24h'                         │
│             AND message_id NOT IN (SELECT message_id FROM task_reminder_log)│
│    2. For each row: invoke apns_push (internal — service_role)              │
│    3. INSERT INTO task_reminder_log (message_id, sent_at)                   │
└────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Cross-repo file layout

**leaf (this repo) — Swift changes:**

```
Packages/LeafCore/Sources/LeafCore/
├── Network/
│   ├── SupabaseClient.swift                       EXTEND — DM methods
│   ├── SupabaseSessionStore.swift                 NEW — refresh_token persistence
│   └── SupabaseEndpoint.swift                     EXTEND — DM endpoints
├── DB/
│   ├── Schema.swift                               EXTEND — MessagesMirror + APNsTokenLocal
│   ├── Migrations/
│   │   ├── M020_MessagesMirror.swift              NEW
│   │   └── M021_APNsTokenLocal.swift              NEW
│   ├── MessagesMirrorStore.swift                  NEW — UPSERT + read accessors
│   └── APNsTokenLocalStore.swift                  NEW — singleton row
├── Team/                                          (renamed in S7 — keep here for now)
│   ├── DirectMessage.swift                        NEW — value types
│   ├── DirectMessageKind.swift                    NEW — enum
│   ├── DirectMessagePlaintext.swift               NEW — Codable JSON shape
│   ├── DirectMessageBlobCodec.swift               NEW — protocol + UnimplementedDirectMessageBlobCodec
│   ├── DirectMessageService.swift                 NEW — sender orchestrator
│   ├── DirectMessageInboxService.swift            NEW — recipient poll + decrypt + mirror upsert
│   ├── APNsRegistrationService.swift              NEW — on-launch register + retry
│   └── SentDirectMessage.swift                    NEW
├── LeafError.swift                                EXTEND — new error cases
└── Insights/                                      (no changes — S5 territory)

Packages/LeafCore/Sources/LeafCorePrivate/
└── Prod/Crypto/
    └── ProdDirectMessageBlobCodec.swift           NEW (moat — gitignored)

Leaf/
├── LeafApp.swift                                  EXTEND — wire DirectMessageService/InboxReader + APNsRegistrationService
├── AppDelegate
│   └── LeafAppDelegate.swift                      EXTEND — registerForRemoteNotifications callbacks
├── Models/
│   ├── DirectMessageInboxReader.swift             NEW — @MainActor @Observable subscriber
│   ├── DirectMessageSendReader.swift              NEW — Send-sheet state machine
│   └── APNsRegistrationReader.swift               NEW — registration state
└── Views/Window/Team/
    └── SendDirectMessageSheet.swift               NEW (initial scope — full integration S7)
```

**leaf-relay (private repo) — TypeScript + SQL:**

```
supabase/
├── migrations/
│   └── 20260514120000_task_reminders_log.sql      NEW (M013 Supabase) — task_reminder_log + pg_net + cron body update + RLS UPDATE policy widening
├── functions/
│   ├── apns_push/
│   │   ├── index.ts                               REWRITE — real body (ES256 JWT + APNs HTTP/2 POST)
│   │   ├── apns-jwt.ts                            NEW helper — ES256 signing + caching
│   │   └── test.ts                                NEW — Deno unit tests
│   └── task_reminders/                            NEW directory
│       ├── index.ts                               NEW
│       └── test.ts                                NEW
└── tests/database/
    ├── 150_task_reminder_log.test.sql             NEW pgTAP
    └── 160_direct_messages_rls.test.sql           NEW pgTAP — UPDATE policy widening (sender+recipient both can update)
```

### 4.3 Composition root wiring (LeafApp init excerpt)

```swift
init() {
    // … existing FileKeyStore + ProdInsights register …
    // … existing ActiveWorkspaceStore + WorkspaceReader …
    // … existing SupabaseClient …  (now reading session from SessionStore)

    // Track 5 / S4 — DM substrate
    let supabaseSessionStore = SupabaseSessionStore(at: TeamKeystore.defaultRoot())
    let supabase = SupabaseClient(
        baseURL: ...,
        anonKey: ...,
        identity: { try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) },
        sessionStore: supabaseSessionStore   // S4 — persistent session
    )

    #if LEAF_PROD
    let dmCodec: any DirectMessageBlobCodec = ProdDirectMessageBlobCodec()
    #else
    let dmCodec: any DirectMessageBlobCodec = UnimplementedDirectMessageBlobCodec()
    #endif

    let dmService = DirectMessageService(
        database: db,
        supabase: supabase,
        codec: dmCodec,
        keystoreRoot: TeamKeystore.defaultRoot()
    )
    let inboxService = DirectMessageInboxService(
        database: db,
        supabase: supabase,
        codec: dmCodec,
        keystoreRoot: TeamKeystore.defaultRoot()
    )

    let inboxReader = DirectMessageInboxReader(inboxService: inboxService,
                                                activeWorkspaceStore: active)
    let sendReader = DirectMessageSendReader(sendService: dmService,
                                              activeWorkspaceStore: active)
    let apnsRegService = APNsRegistrationService(supabase: supabase,
                                                  database: db)
    let apnsRegReader = APNsRegistrationReader(service: apnsRegService)

    _directMessageInboxReader = State(initialValue: inboxReader)
    _directMessageSendReader = State(initialValue: sendReader)
    _apnsRegistrationReader = State(initialValue: apnsRegReader)
}
```

---

## 5. SQLCipher schema additions

### 5.1 M020 — `messages_mirror`

```sql
CREATE TABLE messages_mirror (
    message_id              TEXT PRIMARY KEY,
    workspace_id            TEXT NOT NULL,
    sender_pubkey_hex       TEXT NOT NULL,
    sender_member_id        TEXT NOT NULL,
    sender_display_name     TEXT NOT NULL,
    recipient_pubkey_hex    TEXT NOT NULL,
    kind                    TEXT NOT NULL,        -- 'handoff' | 'task' | 'ping'
    body                    TEXT NOT NULL,
    attachment_kind         TEXT,                  -- optional; populated post-S5
    attachment_external_ref TEXT,
    reply_to                TEXT,                  -- logical FK to messages_mirror.message_id
    sent_at_ms              INTEGER NOT NULL,      -- plaintext.sentAtMs (sender wall-clock)
    server_created_at_ms    INTEGER NOT NULL,      -- Supabase row created_at
    read_at_ms              INTEGER,
    done_at_ms              INTEGER,
    done_by_pubkey_hex      TEXT,
    direction               TEXT NOT NULL          -- 'outbound' (sender's row) | 'inbound' (recipient's row)
                            CHECK (direction IN ('outbound', 'inbound')),
    last_synced_at_ms       INTEGER NOT NULL
);

CREATE INDEX idx_messages_mirror_workspace_recent ON messages_mirror
    (workspace_id, server_created_at_ms DESC);

CREATE INDEX idx_messages_mirror_unread ON messages_mirror
    (workspace_id, recipient_pubkey_hex, server_created_at_ms DESC)
    WHERE read_at_ms IS NULL AND direction = 'inbound';

CREATE INDEX idx_messages_mirror_open_tasks ON messages_mirror
    (workspace_id, server_created_at_ms DESC)
    WHERE kind = 'task' AND done_at_ms IS NULL;
```

**Why `direction` column.** Same `message_id` exists on both sender and recipient Macs after sync. Sender's `tick` writes `direction='outbound'`; recipient's `tick` writes `direction='inbound'`. UI uses this to differentiate "I sent this" vs "they sent this" rendering.

### 5.2 M021 — `apns_token_local`

```sql
CREATE TABLE apns_token_local (
    device_id            TEXT PRIMARY KEY,           -- stable Mac identifier (IOPlatformUUID)
    apns_token           TEXT NOT NULL,              -- hex token from APNs
    environment          TEXT NOT NULL               -- 'development' | 'production'
                          CHECK (environment IN ('development', 'production')),
    registered_at_ms     INTEGER NOT NULL,
    last_pushed_at_ms    INTEGER,                    -- best-effort observation
    server_synced_at_ms  INTEGER                     -- last successful Supabase apns_tokens UPSERT
);
```

Singleton expected (one row per device); PK enforcement allows UPSERT pattern.

### 5.3 Migration safety

M020 + M021 are pure CREATE — atomic via GRDB migrator; partial application impossible. Backfill: zero rows (mirror grows post-migration as messages arrive; APNs token row materializes on first registerForRemoteNotifications callback). Forward-only per repo convention.

### 5.4 Schema namespace additions

```swift
public enum MessagesMirror {
    public static let tableName = "messages_mirror"
    public static let messageID = "message_id"
    // ... all columns from §5.1
    public static let indexWorkspaceRecent = "idx_messages_mirror_workspace_recent"
    public static let indexUnread = "idx_messages_mirror_unread"
    public static let indexOpenTasks = "idx_messages_mirror_open_tasks"
}

public enum APNsTokenLocal {
    public static let tableName = "apns_token_local"
    // ...
}
```

---

## 6. DirectMessage value types + codec

### 6.1 `DirectMessageKind`

```swift
public enum DirectMessageKind: String, Sendable, Codable {
    case handoff
    case task
    case ping
}
```

Stored as 'handoff' / 'task' / 'ping' in SQLCipher + Supabase + plaintext. CHECK constraint server-side mirrors enum.

### 6.2 `DirectMessagePlaintext`

```swift
public struct DirectMessagePlaintext: Sendable, Equatable, Codable {
    public let messageID: String                  // UUID lowercased
    public let workspaceID: String
    public let senderMemberID: String
    public let senderPubkeyHex: String
    public let senderDisplayName: String
    public let recipientMemberID: String?         // optional — recipient may not be known by sender's local member list yet
    public let recipientPubkeyHex: String
    public let kind: DirectMessageKind
    public let body: String
    public let attachment: DirectMessageAttachment?  // S5 will populate; S4 always nil
    public let replyTo: String?                   // optional message_id of parent
    public let sentAtMs: Int64                    // sender wall-clock

    private enum CodingKeys: String, CodingKey {
        case messageID         = "message_id"
        case workspaceID       = "workspace_id"
        case senderMemberID    = "sender_member_id"
        case senderPubkeyHex   = "sender_pubkey_hex"
        case senderDisplayName = "sender_display_name"
        case recipientMemberID = "recipient_member_id"
        case recipientPubkeyHex = "recipient_pubkey_hex"
        case kind, body, attachment, replyTo
        case sentAtMs          = "sent_at_ms"
    }
}

public struct DirectMessageAttachment: Sendable, Equatable, Codable {
    public let kind: String           // e.g., "commit", "linear_issue", "github_pr"
    public let externalRef: String    // human-readable reference
    public let displayLabel: String?  // optional UI label
}
```

JSON encoding sortedKeys for deterministic ciphertext-equality testing (matches `ProdInviteBlobCodec` pattern).

### 6.3 `DirectMessageBlobCodec` protocol

```swift
public protocol DirectMessageBlobCodec: Sendable {
    func encode(_ plaintext: DirectMessagePlaintext,
                keyID: Data,                // 16B UUID raw bytes
                teamKey: Data) throws -> Data    // returns envelope bytes

    func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext
}

public struct UnimplementedDirectMessageBlobCodec: DirectMessageBlobCodec {
    public init() {}
    public func encode(_ plaintext: DirectMessagePlaintext, keyID: Data, teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }
    public func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext {
        throw LeafError.notImplemented
    }
}
```

### 6.4 Envelope shape (LeafCorePrivate moat)

`ProdDirectMessageBlobCodec` (in `LeafCorePrivate/Prod/Crypto/ProdDirectMessageBlobCodec.swift`):

- Public envelope shape — same `[version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]` as presence envelope (architecture.md §Presence distribution).
- Version byte distinguishes DM blob from presence and invite blobs (reserve next free byte in `0x01` / `0x02` / … sequence per existing moat convention).
- AES-GCM-256 under `teamKey`; nonce random 12B per seal.
- Tag mismatch / version mismatch / length-too-short → `LeafError.directMessageBlobMalformed`.

Exact AAD construction + byte-slice ranges + JSONEncoder configuration live in LeafCorePrivate per architecture moat boundary (precedent: `ProdEnvelopeCodec` / `ProdInviteBlobCodec`).

### 6.5 `SentDirectMessage` return type

```swift
public struct SentDirectMessage: Sendable, Equatable {
    public let messageID: String
    public let createdAtISO: String      // server canonical timestamp
    public let pushDispatchStatus: PushDispatchStatus

    public enum PushDispatchStatus: Sendable, Equatable {
        case sent            // Edge Function returned 200
        case skipped         // notify=OFF
        case failed(String)  // Edge Function failure — message persists anyway
    }
}
```

---

## 7. SupabaseClient extensions

### 7.1 New methods

```swift
extension SupabaseClient {
    // MARK: - DM send

    public func sendDirectMessage(
        workspaceID: String,
        recipientPubkeyHex: String,
        kind: DirectMessageKind,
        encryptedPayload: Data,
        replyTo: String?
    ) async throws -> SupabaseSentMessageRow
    // POST /rest/v1/direct_messages
    // Returns: { message_id, created_at }

    // MARK: - DM fetch

    public func fetchInboundMessages(
        workspaceID: String,
        recipientPubkeyHex: String,
        sinceCreatedAtISO: String?,
        limit: Int
    ) async throws -> [SupabaseDirectMessageRow]
    // GET /rest/v1/direct_messages?workspace_id=eq.X
    //     &recipient_pubkey=eq.Y &order=created_at.asc &limit=N
    //     &created_at=gt.SINCE (omitted on initial fetch)

    public func fetchOutboundMessages(
        workspaceID: String,
        senderPubkeyHex: String,
        sinceCreatedAtISO: String?,
        limit: Int
    ) async throws -> [SupabaseDirectMessageRow]
    // Used for sender's own timeline sync (in case of multi-device setup)

    // MARK: - DM lifecycle

    public func markRead(messageID: String) async throws
    // PATCH /rest/v1/direct_messages?message_id=eq.X { read_at: now }

    public func markDone(messageID: String, doneByPubkeyHex: String) async throws
    // PATCH ... { done_at: now, done_by_pubkey: $self }

    // MARK: - APNs

    public func registerAPNsToken(
        deviceID: String,
        apnsToken: String,
        environment: String
    ) async throws
    // POST /rest/v1/apns_tokens (UPSERT via Prefer: resolution=merge-duplicates on PK)

    public func triggerAPNsPush(
        workspaceID: String,
        recipientPubkeyHex: String,
        messageID: String,
        titleText: String
    ) async throws
    // POST /functions/v1/apns_push
    // Returns: { ok: true, devices_pushed: N } — failures ≤ devices_pushed
}
```

### 7.2 Wire shapes

**POST /rest/v1/direct_messages:**

```json
{
  "workspace_id": "<uuid>",
  "sender_pubkey": "<64-hex>",
  "recipient_pubkey": "<64-hex>",
  "kind": "handoff" | "task" | "ping",
  "encrypted_payload": "\\x<hex bytes>",
  "reply_to": "<uuid | null>"
}
```

Headers: `Authorization: Bearer <JWT>` + `apikey: <anon>` + `Prefer: return=representation` (PostgREST returns created row).

**GET /rest/v1/direct_messages:**

PostgREST query string with `workspace_id=eq.X&recipient_pubkey=eq.Y&order=created_at.asc&limit=100`. Optional `&created_at=gt.<iso>` for incremental sync.

Response: array of row objects. `encrypted_payload` comes back as `\x<hex>` PostgREST bytea format → decoder converts to Data.

**PATCH /rest/v1/direct_messages?message_id=eq.X:**

```json
{ "read_at": "<iso>" }
```

```json
{ "done_at": "<iso>", "done_by_pubkey": "<64-hex>" }
```

**POST /rest/v1/apns_tokens with PostgREST upsert:**

```http
POST /rest/v1/apns_tokens
Prefer: resolution=merge-duplicates
Content-Type: application/json

{ "pubkey": "<64-hex>", "device_id": "<string>", "apns_token": "<hex>" }
```

RLS gates: `pubkey = JWT pubkey` — self-only. `updated_at` set by DEFAULT now() on UPSERT.

**POST /functions/v1/apns_push:**

```json
{
  "workspace_id": "<uuid>",
  "recipient_pubkey": "<64-hex>",
  "message_id": "<uuid>",
  "title": "Anton sent a handoff",
  "is_reminder": false
}
```

Authenticated with JWT. Edge Function uses service_role internally to look up apns_tokens. Response:

```json
{ "ok": true, "devices_pushed": 1, "errors": [] }
```

### 7.3 `SupabaseSessionStore` (S3 carry-over I3 fix)

File-backed JSON in keystore root, 0o600 perms:

```swift
public struct SupabaseSessionStore: Sendable {
    private let path: URL

    public init(at keystoreRoot: URL) {
        self.path = keystoreRoot.appendingPathComponent("supabase-session.json")
    }

    public func read() throws -> PersistedSession?
    public func write(_ session: PersistedSession) throws
    public func clear() throws
}

public struct PersistedSession: Codable, Sendable, Equatable {
    public let refreshToken: String
    public let userID: String           // auth.users.id, for diagnostic
    public let savedAtMs: Int64
}
```

`SupabaseClient.init` takes optional `sessionStore`. On first `ensureAuthenticated()` call:

- If `state == .notAuthenticated` and `sessionStore.read()` returns persisted session → attempt token refresh with persisted `refreshToken`
- If refresh succeeds → `.authenticated(newSession)` and `sessionStore.write(newPersisted)`
- If refresh fails (refresh_token expired / revoked) → fall through to fresh `signInAnonymously` flow
- On every successful refresh → `sessionStore.write()`

Failure modes:
- Disk read error → log + proceed as if no persisted session (fresh signup)
- Disk write error → log + don't crash (session still works in-memory until quit)

Test surface: `SupabaseSessionStoreTests` covers read/write/clear round-trip + invalid JSON + missing file.

### 7.4 Carry-over preserved

I2 (codec error remap in InviteAcceptService) — NOT addressed in S4. Stays as Track 6 cleanup item.

---

## 8. APNs Edge Function (`apns_push`) real body

### 8.1 Authentication — token-based (.p8)

Apple supports two APNs auth schemes; we use **token-based** (.p8 key) over cert-based:

| Aspect | Token (.p8) | Cert |
|---|---|---|
| Renewal | Annual key rotation manual | Annual cert renewal manual |
| Per-bundle | One key serves all bundles for team | One cert per bundle |
| Storage | .p8 file (PKCS#8 EC private) | .p12 + password |
| HTTP/2 JWT auth | Required | Optional |

Token-based wins for: ease of rotation (single key in Supabase secrets), HTTPS/2 native, team-wide reuse.

### 8.2 Secrets in Supabase

```bash
supabase secrets set \
  APNS_KEY_P8="$(cat AuthKey_XXXXX.p8)" \
  APNS_KEY_ID=ABCDEFGHIJ \
  APNS_TEAM_ID=Y6Z2C9N9N9 \
  APNS_BUNDLE_ID=tech.gundem.leaf
```

VPS Claude handles the deployment step (per Track 5 contract §17 — S4 row).

### 8.3 JWT for APNs

```typescript
// apns_push/apns-jwt.ts
import { decode as decodePEM } from "https://deno.land/std@0.224.0/encoding/base64.ts";

let cachedJWT: { jwt: string; expiresAt: number } | null = null;

export async function getAPNsJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && cachedJWT.expiresAt > now + 60) return cachedJWT.jwt;

  const keyP8 = Deno.env.get("APNS_KEY_P8")!;
  const keyID = Deno.env.get("APNS_KEY_ID")!;
  const teamID = Deno.env.get("APNS_TEAM_ID")!;

  const header = btoa(JSON.stringify({ alg: "ES256", kid: keyID, typ: "JWT" }))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const payload = btoa(JSON.stringify({ iss: teamID, iat: now }))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const data = new TextEncoder().encode(`${header}.${payload}`);
  const privateKey = await importP8Key(keyP8);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    data
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const jwt = `${header}.${payload}.${sigB64}`;
  cachedJWT = { jwt, expiresAt: now + 50 * 60 };  // APNs allows 60min; refresh at 50
  return jwt;
}

async function importP8Key(p8: string): Promise<CryptoKey> {
  // Strip PEM armor + base64 decode
  const pemBody = p8
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const der = decodePEM(pemBody);
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}
```

JWT cached in module-scope for the lifetime of the Edge Function worker (per-invocation cold-starts make caching opportunistic; APNs JWT can be reused up to 60 minutes).

### 8.4 Edge Function body

```typescript
// apns_push/index.ts
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { getAPNsJWT } from "./apns-jwt.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing_authorization" }, 401);

  // Verify caller's JWT
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: "unauthorized" }, 401);

  // Parse body
  let body: { workspace_id?: unknown; recipient_pubkey?: unknown; message_id?: unknown; title?: unknown; is_reminder?: unknown };
  try { body = await req.json(); } catch { return json({ error: "bad_payload" }, 400); }
  const workspaceID = body.workspace_id;
  const recipientPubkey = body.recipient_pubkey;
  const messageID = body.message_id;
  const title = body.title;
  const isReminder = body.is_reminder === true;
  if (typeof workspaceID !== "string"
      || typeof recipientPubkey !== "string" || !/^[0-9a-f]{64}$/.test(recipientPubkey)
      || typeof messageID !== "string"
      || typeof title !== "string" || title.length === 0 || title.length > 200) {
    return json({ error: "invalid_payload" }, 400);
  }

  // Service-role client for apns_tokens lookup + cleanup
  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: tokens, error: tokenErr } = await serviceClient
    .from("apns_tokens")
    .select("device_id, apns_token")
    .eq("pubkey", recipientPubkey);
  if (tokenErr) return json({ error: "token_fetch_failed" }, 500);
  if (!tokens || tokens.length === 0) {
    return json({ ok: true, devices_pushed: 0, errors: [] }, 200);
  }

  const apnsJWT = await getAPNsJWT();
  const apnsTopic = Deno.env.get("APNS_BUNDLE_ID")!;
  const apnsHost = Deno.env.get("APNS_HOST") ?? "https://api.push.apple.com";
  // Test override — Deno tests set APNS_HOST to mock server URL.

  const apnsBody = JSON.stringify({
    aps: {
      alert: { title },
      sound: "default",
      "thread-id": workspaceID,
      "mutable-content": 1
    },
    leaf_message_id: messageID,
    leaf_workspace_id: workspaceID,
    leaf_is_reminder: isReminder
  });

  const errors: { device_id: string; status: number; reason?: string }[] = [];
  let pushed = 0;
  for (const t of tokens) {
    const apnsURL = `${apnsHost}/3/device/${t.apns_token}`;
    const res = await fetch(apnsURL, {
      method: "POST",
      headers: {
        "authorization": `bearer ${apnsJWT}`,
        "apns-topic": apnsTopic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json"
      },
      body: apnsBody
    });
    if (res.status === 200) {
      pushed += 1;
      continue;
    }
    // Parse APNs error body
    let reason: string | undefined;
    try {
      const errBody = await res.json();
      reason = errBody?.reason;
    } catch {}
    errors.push({ device_id: t.device_id, status: res.status, reason });
    // 410 Gone → token unregistered; clean up
    if (res.status === 410) {
      await serviceClient
        .from("apns_tokens")
        .delete()
        .eq("pubkey", recipientPubkey)
        .eq("device_id", t.device_id);
    }
  }
  return json({ ok: true, devices_pushed: pushed, errors }, 200);
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
```

### 8.5 APNs error handling

| Status | Reason | Disposition |
|---|---|---|
| 200 | accepted | counted as pushed |
| 400 | bad token shape / missing fields | recorded in errors[] |
| 403 | bad APNs JWT | logged + recorded — operational alert |
| 410 | Unregistered (uninstalled / token expired) | DELETE apns_tokens row + recorded |
| 5xx | APNs transient | recorded; no retry in S4 (single best-effort attempt per cron run) |

Per-device delivery isolation: errors on one token don't short-circuit the loop.

### 8.6 Test surface (`apns_push/test.ts`)

Mock APNs server (Deno test server) + env override `APNS_HOST=http://127.0.0.1:<port>`:

1. Valid payload + matching token → 200, devices_pushed=1
2. 410 from APNs → token deleted from apns_tokens
3. Missing JWT in request → 401
4. Invalid payload shape → 400
5. Multi-token recipient (2 devices) → both attempted, both counted

---

## 9. Task reminders Edge Function + M013 migration

### 9.1 M013 Supabase migration

```sql
-- supabase/migrations/20260514120000_task_reminders_log.sql
-- Track 5 / S4 — task reminders cron real body.

-- Enable HTTP-from-DB
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Idempotency log — one reminder per task forever.
CREATE TABLE task_reminder_log (
    message_id TEXT PRIMARY KEY REFERENCES direct_messages(message_id) ON DELETE CASCADE,
    sent_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Replace S1 stub cron body with real invocation.
SELECT cron.unschedule('task_reminders');
SELECT cron.schedule(
    'task_reminders',
    '0 9 * * *',
    $$
    SELECT net.http_post(
        url := current_setting('app.supabase_functions_url') || '/task_reminders',
        body := '{}'::jsonb,
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || current_setting('app.supabase_service_role_key'),
            'Content-Type', 'application/json'
        )
    );
    $$
);

-- DM RLS UPDATE policy widening (S4 amendment to S1 §6 line 138-140):
-- Allow sender OR recipient to UPDATE (read_at by recipient, done_at by either party).
DROP POLICY IF EXISTS direct_messages_recipient_update ON direct_messages;
CREATE POLICY direct_messages_party_update ON direct_messages FOR UPDATE
  USING (sender_pubkey    = (auth.jwt() ->> 'pubkey')
      OR recipient_pubkey = (auth.jwt() ->> 'pubkey'))
  WITH CHECK (sender_pubkey    = (auth.jwt() ->> 'pubkey')
           OR recipient_pubkey = (auth.jwt() ->> 'pubkey'));
```

> **Amendment 2026-05-14 (S4 spec):** Track 5 contract §5.2 + S1 §6 — `direct_messages` UPDATE policy widened from recipient-only to either party. Sender needs UPDATE for `done_at` (Task lifecycle — sender can mark Task done if recipient completed via another channel like Linear). Recipient still owns `read_at`. AAD model intact: server-side `WITH CHECK` ensures only party-related rows touched. Reason: contract §8.1 Task lifecycle "open → acknowledged (auto on read) → done (manual mark)" is ambiguous about who marks done; UX demands either party. Living-doc process per Track 5 contract §18.

### 9.2 `app.supabase_functions_url` + `app.supabase_service_role_key` settings

These postgres settings are populated by Supabase Dashboard / `supabase secrets` separately; cron body reads them at execution time. VPS Claude handoff per Track 5 contract §17.

If not set, cron silently no-ops (net.http_post fails); operational alerts pick up on first scheduled run.

### 9.3 `task_reminders` Edge Function body

```typescript
// supabase/functions/task_reminders/index.ts
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // service_role-only — cron is the only caller; check Authorization
  const authHeader = req.headers.get("Authorization");
  const expected = "Bearer " + Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!authHeader || authHeader !== expected) {
    return json({ error: "unauthorized" }, 401);
  }

  const serviceClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Find open tasks > 24h old without prior reminder
  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data: openTasks, error: queryErr } = await serviceClient
    .rpc("fetch_unreminded_tasks", { cutoff_iso: cutoff });
  if (queryErr) return json({ error: "query_failed", detail: queryErr.message }, 500);
  if (!openTasks || openTasks.length === 0) {
    return json({ ok: true, reminded: 0 }, 200);
  }

  let reminded = 0;
  const errors: { message_id: string; reason: string }[] = [];
  for (const task of openTasks) {
    // Invoke apns_push internally — call own Edge Function via fetch
    const apnsPushURL = `${Deno.env.get("SUPABASE_URL")}/functions/v1/apns_push`;
    const res = await fetch(apnsPushURL, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
        "content-type": "application/json"
      },
      body: JSON.stringify({
        workspace_id: task.workspace_id,
        recipient_pubkey: task.recipient_pubkey,
        message_id: task.message_id,
        title: "Task still open",
        is_reminder: true
      })
    });
    if (res.status === 200) {
      // Log idempotency record
      const { error: logErr } = await serviceClient
        .from("task_reminder_log")
        .insert({ message_id: task.message_id });
      if (logErr) {
        errors.push({ message_id: task.message_id, reason: logErr.message });
        continue;
      }
      reminded += 1;
    } else {
      errors.push({ message_id: task.message_id, reason: `apns_push status ${res.status}` });
    }
  }

  return json({ ok: true, reminded, errors }, 200);
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
```

### 9.4 `fetch_unreminded_tasks` RPC

Add to M013 SQL:

```sql
CREATE OR REPLACE FUNCTION public.fetch_unreminded_tasks(cutoff_iso text)
RETURNS TABLE (
    message_id uuid,
    workspace_id uuid,
    sender_pubkey text,
    recipient_pubkey text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT dm.message_id, dm.workspace_id, dm.sender_pubkey, dm.recipient_pubkey
    FROM direct_messages dm
    LEFT JOIN task_reminder_log trl ON trl.message_id = dm.message_id
    WHERE dm.kind = 'task'
      AND dm.done_at IS NULL
      AND dm.created_at < cutoff_iso::timestamptz
      AND trl.message_id IS NULL
$$;

REVOKE EXECUTE ON FUNCTION public.fetch_unreminded_tasks FROM public, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.fetch_unreminded_tasks TO service_role;
```

### 9.5 Test surface (`task_reminders/test.ts`)

Mock direct_messages fixture + spy on apns_push invocations:

1. Empty DB → reminded=0
2. Task <24h old → not reminded
3. Task >24h open + no prior reminder → invoke apns_push, INSERT log, reminded=1
4. Task >24h open + has log entry → skipped
5. Task >24h done → not reminded
6. apns_push returns 500 → log NOT inserted (retry-able next cron)

---

## 10. APNs registration on Mac (Swift side)

### 10.1 macOS APNs lifecycle

- App must call `NSApplication.shared.registerForRemoteNotifications()` after user grants UN notifications permission
- AppDelegate `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` receives 32-byte token
- AppDelegate `application(_:didFailToRegisterForRemoteNotificationsWithError:)` for failures
- Token format: 64-char hex string (32 bytes hex-encoded)

### 10.2 `APNsRegistrationService` (LeafCore)

```swift
public actor APNsRegistrationService {
    private let database: Database
    private let supabase: SupabaseClient
    private let deviceID: String          // IOPlatformUUID from Mac hardware

    public func recordToken(_ apnsToken: String, environment: String) async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Local mirror — singleton per device_id
        try database.upsertAPNsTokenLocal(
            deviceID: deviceID,
            apnsToken: apnsToken,
            environment: environment,
            registeredAtMs: nowMs
        )

        // Push to Supabase
        do {
            try await supabase.registerAPNsToken(
                deviceID: deviceID,
                apnsToken: apnsToken,
                environment: environment
            )
            try database.markAPNsTokenServerSynced(deviceID: deviceID,
                                                    syncedAtMs: nowMs)
        } catch {
            // Local row exists; retry on next launch / scenePhase=active
            throw error
        }
    }

    public func retrySyncIfNeeded() async throws {
        guard let row = try database.readAPNsTokenLocal(deviceID: deviceID),
              row.serverSyncedAtMs == nil else { return }
        try await supabase.registerAPNsToken(
            deviceID: row.deviceID,
            apnsToken: row.apnsToken,
            environment: row.environment
        )
        try database.markAPNsTokenServerSynced(
            deviceID: row.deviceID,
            syncedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
```

### 10.3 `LeafAppDelegate` extensions

```swift
final class LeafAppDelegate: NSObject, NSApplicationDelegate {
    // ... existing applicationShouldHandleReopen ...

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request user notification authorization (badge + alert + sound)
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    NSApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let env: String
        #if DEBUG
        env = "development"
        #else
        env = "production"
        #endif
        Task { @MainActor in
            try? await apnsRegistrationReader.recordToken(tokenHex, environment: env)
        }
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        leafAppLogger.error("APNs register failed: \(String(describing: error), privacy: .public)")
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        // userInfo contains leaf_message_id, leaf_workspace_id, leaf_is_reminder
        if let messageID = userInfo["leaf_message_id"] as? String,
           let workspaceID = userInfo["leaf_workspace_id"] as? String {
            Task { @MainActor in
                directMessageInboxReader.tickOnce(workspaceID: workspaceID,
                                                  forMessageID: messageID)
            }
        }
    }
}
```

`apnsRegistrationReader` and `directMessageInboxReader` are stored as appDelegate properties (passed in via NSApplicationDelegateAdaptor binding wiring, or as global accessors). Pattern keeps SwiftUI App init clean.

### 10.4 Test discipline

APNs delivery itself cannot be tested without a signed build + real Apple Developer account. S4 ships:

- Unit tests for `APNsRegistrationService` with mocked SupabaseClient
- Unit tests for `LeafAppDelegate` token-receive path using mock token bytes
- Integration test deferred to two-Mac manual smoke (parallel with Track 5 acceptance gate)

`#if DEBUG` debug menu item "Simulate APNs token" inserts a fake hex token for end-to-end Send sheet flow exercise locally.

---

## 11. OQ-T5-4 resolution: VoIP vs Standard APNs

**Decision:** Standard `apns-push-type: alert` with `apns-priority: 10` (immediate). VoIP rejected.

**Why:**

1. **VoIP semantic abuse risk**: Apple specifically restricts VoIP push to CallKit-integrated apps; non-call apps using VoIP can trigger App Store rejection / forced throttling.
2. **No content-sniff requirement**: APNs payload contains title only (no body excerpt per privacy invariant §6); standard alert push delivers the title fine.
3. **Cold-start latency**: 30s contract budget. Standard push with `priority: 10` typically delivers within 1-5s warm, 5-30s cold. VoIP would be ~1-3s in all states — gain of 5-10s isn't worth the abuse risk.
4. **Battery / data plan**: VoIP forces immediate wake; standard alert allows iOS / macOS to coalesce. Better fit for "ambient memory" product positioning.

Carry-over: if production telemetry shows >30s cold delivery for >10% of pushes, revisit. Tracked outside S4.

---

## 12. UI: SendDirectMessageSheet

### 12.1 Sheet shape

Sheet pattern mirrors `AcceptInviteSheet` (LeafSheetLayout + state-driven content). Initial scope is sheet-only — full Team UI redesign places the Send sticky button in Team tab in S7.

```swift
struct SendDirectMessageSheet: View {
    @Environment(DirectMessageSendReader.self) private var reader
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(\.dismiss) private var dismiss
    @State private var recipientPubkey: String = ""  // member pubkey hex
    @State private var kind: DirectMessageKind = .ping
    @State private var body: String = ""
    @State private var notify: Bool = true

    var body: some View {
        LeafSheetLayout(title: "Send to teammate", onDismiss: dismiss) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                content
                Spacer(minLength: 0)
                footer
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            composeCard
        case .sending:
            HStack { Spacer(); ProgressView("Sending…"); Spacer() }
        case .sent(let result):
            sentCard(result: result)
        case .error(let message):
            LeafBanner(tone: .danger, title: "Couldn't send", description: message,
                        ctaTitle: "Try again", onCTA: { reader.reset() })
        }
    }

    private var composeCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                // To dropdown
                memberDropdown
                // Type segmented
                kindSegmented
                // Body textarea
                bodyTextarea
                // Channels — locked
                channelsSection
                // Notify
                notifyToggle
            }
        }
    }
    // ... member dropdown queries workspaceReader.activeMembers
    // ... kind segmented Handoff / Task / Ping
    // ... body multi-line text editor
    // ... channels (Leaf locked on, Slack/Linear disabled with chip "Coming in S6")
    // ... notify toggle
}
```

### 12.2 Send sheet state machine (`DirectMessageSendReader`)

```swift
@MainActor
@Observable
final class DirectMessageSendReader {
    enum State {
        case idle
        case sending
        case sent(SentDirectMessage)
        case error(String)
    }

    private(set) var state: State = .idle
    private let sendService: DirectMessageService
    private let activeStore: ActiveWorkspaceStore

    func send(recipientPubkeyHex: String,
              recipientMemberID: String?,
              kind: DirectMessageKind,
              body: String,
              notify: Bool) async {
        guard let wid = activeStore.activeWorkspaceID else { return }
        state = .sending
        do {
            let result = try await sendService.send(
                workspaceID: wid,
                recipientPubkeyHex: recipientPubkeyHex,
                recipientMemberID: recipientMemberID,
                kind: kind,
                body: body,
                notify: notify
            )
            state = .sent(result)
        } catch let err as LeafError {
            state = .error(String(describing: err))
        } catch {
            state = .error("unexpected: \(error)")
        }
    }

    func reset() { state = .idle }
}
```

### 12.3 Entry point — initial scope

S4 ships only the sheet + its reader; integration into TeamView (sticky Send button at bottom) is S7 scope.

For S4 testing — add a temporary `[Send Direct Message]` button in `OrganizationView` member list (next to existing member rows). Allows author to exercise the path locally without full Team UI. Removed in S7 redesign.

### 12.4 Inbox UI — initial scope

S4 ships `DirectMessageInboxReader` with `recentMessages: [MessagesMirrorRow]` published surface. Initial UI: temporary list section in OrganizationView header showing last 10 inbound messages. S7 redesign replaces this with full Team feed.

---

## 13. Test approach

### 13.1 Test layout

```
Packages/LeafCore/Tests/LeafCoreTests/
├── DB/
│   ├── M020MessagesMirrorTests.swift              NEW
│   ├── M021APNsTokenLocalTests.swift              NEW
│   ├── MessagesMirrorStoreTests.swift             NEW
│   └── APNsTokenLocalStoreTests.swift             NEW
├── Network/
│   ├── SupabaseSessionStoreTests.swift            NEW
│   ├── SupabaseClientSendDirectMessageTests.swift NEW
│   ├── SupabaseClientFetchInboundTests.swift      NEW
│   ├── SupabaseClientFetchOutboundTests.swift     NEW
│   ├── SupabaseClientMarkReadDoneTests.swift      NEW
│   ├── SupabaseClientRegisterAPNsTests.swift      NEW
│   ├── SupabaseClientTriggerAPNsPushTests.swift   NEW
│   └── SupabaseEndpointDMTests.swift              NEW
├── Team/
│   ├── DirectMessageKindTests.swift               NEW
│   ├── DirectMessagePlaintextCodingTests.swift    NEW
│   ├── DirectMessageBlobCodecProtocolTests.swift  NEW (UnimplementedDirectMessageBlobCodec throws)
│   ├── DirectMessageServiceTests.swift            NEW
│   ├── DirectMessageInboxServiceTests.swift       NEW
│   └── APNsRegistrationServiceTests.swift         NEW
└── (existing tests)

Packages/LeafCore/Tests/LeafCorePrivateTests/
├── Crypto/
│   ├── ProdDirectMessageBlobCodecTests.swift             NEW
│   ├── ProdDirectMessageBlobCodecTamperTests.swift       NEW (byte-level tamper coverage)
│   └── ProdDirectMessageBlobCodecRoundTripTests.swift    NEW
└── (existing tests)
```

### 13.2 Mock URLSession pattern

`SupabaseClient` test pattern from S3 (URLProtocol-based intercept) reused. Add shared helper `MockSupabaseURLSession.swift` if not already in `TestSupport/`.

### 13.3 Integration tests gated behind env

`SupabaseIntegrationTests` from S3 extended to cover DM endpoints. Same `LEAF_RUN_SUPABASE_INTEGRATION_TESTS=1` gate.

### 13.4 Deno tests for Edge Functions

```
supabase/functions/apns_push/test.ts          NEW — covers G12
supabase/functions/task_reminders/test.ts     NEW — covers G13
```

Run via `deno test --allow-all supabase/functions/*/test.ts`.

### 13.5 pgTAP tests

```
supabase/tests/database/150_task_reminder_log.test.sql      NEW
supabase/tests/database/160_direct_messages_rls.test.sql    NEW — sender_pubkey or recipient_pubkey UPDATE allow / non-party deny
```

### 13.6 Expected test count

- Baseline post-S3: 2060 SPM tests.
- S4 additions: ~80-100 net new across DM substrate.
- Expected after S4: **~2140-2160 SPM tests**.
- pgTAP files: 14 → 16 (+2). Assertions: 38 → ~50 (+12).

### 13.7 Build verification

```bash
swift test --package-path Packages/LeafCore
xcodebuild -scheme Leaf build
xcodebuild -scheme LeafAgent build
xcodebuild -scheme LeafMCP build
xcodebuild -scheme LeafCore build
xcodebuild -scheme LeafCorePrivate build
```

All exit 0 for G18 / G19.

---

## 14. Local vs VPS handoff

| Task | Local Claude (Mac) | VPS Claude |
|---|---|---|
| Migration M020 + M021 (SQLCipher) | ✅ implement + test | n/a |
| `DirectMessageBlobCodec` protocol + Unimplemented | ✅ | n/a |
| `ProdDirectMessageBlobCodec` (moat) | ✅ implement + test | n/a |
| `SupabaseClient` DM extensions | ✅ implement + test (mocked URLSession) | n/a |
| `SupabaseSessionStore` | ✅ implement + test | n/a |
| `DirectMessageService` + `DirectMessageInboxService` | ✅ implement + test | n/a |
| `APNsRegistrationService` + LeafAppDelegate wiring | ✅ implement + unit-test | manual smoke on signed build (real APNs delivery — both Macs) |
| `SendDirectMessageSheet` + `DirectMessageSendReader` + `DirectMessageInboxReader` | ✅ implement + UI smoke (local debug build) | n/a |
| M013 Supabase migration + pgTAP | ✅ author SQL + write pgTAP | deploy via `supabase db push` after merge |
| `apns_push` Edge Function real body + Deno tests | ✅ implement + run Deno tests | deploy via `supabase functions deploy apns_push` after merge |
| `task_reminders` Edge Function + Deno tests | ✅ implement + run Deno tests | deploy via `supabase functions deploy task_reminders` after merge |
| APNs secrets configuration | n/a | `supabase secrets set APNS_KEY_P8 APNS_KEY_ID APNS_TEAM_ID APNS_BUNDLE_ID` |
| Apple Developer Portal setup (.p8 key gen + bundle ID + Push capability) | n/a | account holder action (Anton); .p8 file handed off to VPS Claude securely |
| pg cron app settings (`app.supabase_functions_url`, `app.supabase_service_role_key`) | n/a | configured via Supabase Dashboard settings |
| Two-Mac manual smoke G21 | ✅ ship-build + Anton sends DM to Dmitrii | n/a |

---

## 15. Manual smoke checklist (acceptance gate — deferred)

S4 manual smoke runs against signed alpha build on two real Macs with real Apple Push credentials live. Local SPM tests + Edge Function unit tests cover the wire shapes; APNs delivery itself requires production environment.

**G21 acceptance scenario:**

1. Both Macs running same alpha build pointing at production Supabase
2. Both have shared workspace from S3 acceptance (UC-T5-1 passed)
3. Both have granted Notifications permission (UN authorization → APNs register)
4. Each Mac's APNs token visible in Supabase `apns_tokens` table (verify via dashboard)
5. **Handoff send test:** Mac A → OrganizationView → click [Send Direct Message] next to Dmitrii's row → Type=Handoff, Body="Test ping from S4 smoke" → Send → "Sent" UI confirmation
6. Mac B receives APNs push within 5s (warm) — banner shows "Anton sent a handoff" — click → Leaf opens (or focuses if backgrounded)
7. Mac B: OrganizationView inbox section shows new message → click → marks read → sender's app eventually sees `read_at` update (via inbox poll on Mac A — 30s foreground tick)
8. **Task lifecycle test:** Mac A sends Type=Task → Mac B receives → next day cron sends reminder (or simulate via `select pg_cron.run_now('task_reminders')` on Supabase) → Mac B receives reminder push → Mac B marks Task done → Mac A sees done timestamp + done_by_pubkey
9. **Ping send test:** Mac A sends Type=Ping → Mac B receives → no reminder cron involvement; auto-dim after read
10. **APNs cleanup test:** delete Leaf from Mac B → Mac A sends another Handoff → apns_push gets 410 from APNs → Supabase apns_tokens row deleted (verify via dashboard)

Acceptance gate documents the smoke run alongside G15+G16 (S3) — collective Track 5 merge after all-green.

---

## 16. New error cases

```swift
public enum LeafError {
    // ... existing cases ...

    /// AES-GCM decryption of direct message blob failed (wrong key / tampered).
    case directMessageBlobMalformed

    /// Direct message exceeded body length cap (64KB safety limit).
    case directMessageBodyTooLarge

    /// APNs token registration failed at Supabase (4xx / 5xx).
    case apnsRegistrationFailed(reason: String)

    /// Supabase session persistence read/write failure (non-fatal — caller decides).
    case supabaseSessionStoreFailure(reason: String)

    /// Edge Function returned non-200 status when triggering apns_push.
    case apnsPushDispatchFailed(reason: String)
}
```

UI surfaces:
- `directMessageBlobMalformed` — debug-only; production reflects "decryption failed" toast with reload option (cycle inbox tick).
- `directMessageBodyTooLarge` — Send sheet shows inline error before button enables.
- `apnsRegistrationFailed` — Settings → Notifications surfaces "Push not delivered to server" with retry button (S8 surface; S4 logs only).
- `supabaseSessionStoreFailure` — logged, session works in-memory, no UI surface.
- `apnsPushDispatchFailed` — Send sheet shows pushDispatchStatus = .failed; message persists, retry from UI optional (S8 carry-over).

---

## 17. Migration number reconciliation

Track 5 contract §5.4 specified:

- M019 — workspaces (S2) ✅ shipped
- M020 — share_rules (S5)
- M021 — messages_mirror (S4)
- M022 — team_events_mirror (S5)
- M023 — apns_token_local (S4)

S4 lands first chronologically after S3 — so M020 + M021 take the next two slots. Contract reconciliation:

> **Amendment 2026-05-14 (S4 spec):** Track 5 contract §5.4 ordering adjusted. M020 → `messages_mirror` (S4), M021 → `apns_token_local` (S4). M022 → `share_rules` (S5), M023 → `team_events_mirror` (S5). Reason: phase shipping order is S2→S3→S4→S5, so M-number assignment reflects chronology. No functional impact — substrate identical, only filenames + Schema constants differ. Living-doc per contract §18.

---

## 18. Implementation plan reference

Implementation plan (atomic per-commit decomposition) lives at:

```
docs/superpowers/plans/2026-05-14-track-5-S4-direct-messages.md
```

Plan file is gitignored locally (per repo convention — implementation moat). Plan written in Stage 4 after spec self-review + user approval.

---

## 19. References

- Track 5 contract: `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md` (§8 DM primitive, §10 Notifications, §13 Retention, §17 Local/VPS split)
- S3 spec: `docs/superpowers/specs/2026-05-15-track-5-S3-magic-link-invite.md` (SupabaseClient pattern, Edge Function discipline, apikey gotcha)
- S2 spec: `docs/superpowers/specs/2026-05-14-track-5-S2-multiworkspace-substrate.md` (workspace_id substrate)
- S1 spec: `docs/superpowers/specs/2026-05-13-track-5-S1-backend-foundation.md` (direct_messages + apns_tokens Supabase tables, pre-deployed)
- Phase 5.1.C envelope precedent: `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdEnvelopeCodec.swift`
- Phase 5.2.B invite blob precedent: `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteBlobCodec.swift`
- ADR-010 won't-list (privacy invariant — no body content in APNs / cross-post warnings): whitepaper `docs/team-sharing/privacy-security/`
- APNs documentation: https://developer.apple.com/documentation/usernotifications/sending-push-notifications-using-command-line-tools
- pg_net extension: https://supabase.com/docs/guides/database/extensions/pg_net
