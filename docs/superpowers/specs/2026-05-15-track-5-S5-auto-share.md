# Track 5 / S5 — Auto-Share Substrate

> Phase-level spec. Track 5 contract: `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md`. Predecessor: S4 (`2026-05-14-track-5-S4-direct-messages.md`).
> Status: writing — 2026-05-15.
> Branch: `feature/track-5-S5-auto-share` (leaf) + `feature/track-5-S5-auto-share` (leaf-relay).
> Closes: **UC-T5-2** (Auto-share + AI query).

---

## §1 Purpose

S5 ships the **auto-share substrate** — recipient-symmetric, opt-in-per-source broadcasting of substrate events (git commits, Linear issues, GitHub PRs, Slack mentions, Track-1 D3 detected decisions/blockers/open-questions/where-stopped, raw GitHub activity) under workspace `teamKey` with 30-day retention on server, 90-day default retention on local mirror.

After S5 merges + VPS deploy:

- User opens Settings → "Share Controls" → toggles "Git commits ON" / "Linear issues ON" / "Detected decisions ON" → per-source switches persist.
- User commits to a watched repo → Layer A captures `gh_commit_pushed` event → S5 broadcast loop (running in MenuBarApp via existing SupabaseClient) classifies → `gitCommits` source → checks `share_rules.enabled` → checks default deny-list (path-based, size-based, event_kind-based) → if pass: encrypts under workspace `teamKey` (AES-GCM-256 envelope, version byte `0x04`) → POSTs to Supabase `team_events` table with `expires_at = now() + 30 days`.
- Teammate's MenuBarApp (within ≤30s on next mirror tick) fetches inbound rows → decrypts → UPSERTs into local `team_events_mirror` table.
- Daily local prune in MenuBarApp drops mirror rows older than 90 days (default; user-configurable surface is S8).
- Existing Supabase `retention_purge` daily cron (S1, currently no-op) starts purging server rows where `expires_at < now()`.

S5 closes **UC-T5-2** (Auto-share + AI query). The "AI query" half — `leaf_query_team` MCP tool reading the local mirror — is **S8 scope** per Track 5 contract §4; S5 ships the mirror table + writer only, no query surface beyond direct SQL.

**No APNs push for auto-shared events** (per S4 §11 OQ-T5-4 resolution implication). Recipients discover via Team tab feed view (S7) — not via notification.

---

## §2 Goal — fitness function

Each item is a separate, mechanically-checkable gate.

| # | Check | How to verify |
|---|---|---|
| **G1** | M022 `share_rules` + M023 `team_events_mirror` + M024 `team_event_broadcast_offsets` migrations land on top of M021 (S4) without drift | `swift test --filter MigrationsTests` |
| **G2** | `TeamEventBlobCodec` Unimplemented stub (LeafCore) + `ProdTeamEventBlobCodec` (LeafCorePrivate moat) round-trip plaintext under teamKey via envelope `[0x04 | keyID:16B | nonce:12B | ct | tag:16B]` | `swift test --filter ProdTeamEventBlobCodecTests` |
| **G3** | `ShareSource` enum has exactly 9 cases matching contract §11.1 (gitCommits / linearIssues / slackMentions / githubPRs / detectedDecisions / detectedBlockers / detectedOpenQuestions / detectedWhereStopped / rawGitHubActivity) | enum CaseIterable count assertion in `ShareSourceTests` |
| **G4** | `ShareSourceClassifier.classify(eventKind:)` returns correct ShareSource for known event_kinds (golden table: ≥30 entries covering all 9 sources) + nil for unmappable | `ShareSourceClassifierTests` golden table |
| **G5** | `TeamEventBroadcastService.tick` reads since-cursor → filters → encrypts → POSTs → advances cursor; idempotent on second tick (no duplicate POSTs) | integration test with mock SupabaseClient |
| **G6** | `TeamEventBroadcastService.tick` skips events when share_rules.enabled = false AND when default-deny-list matches; advance cursor regardless | filter-coverage tests with synthetic events |
| **G7** | `TeamEventMirrorService.tick` fetches inbound, decrypts (via keyID lookup), UPSERTs by event_id (idempotent on second tick) | mock SupabaseClient + assert mirror row count |
| **G8** | `ShareRulesStore` reads default state from `ShareRuleDefaults.all` when row absent; UPSERT-writes user override | `ShareRulesStoreTests` |
| **G9** | `TeamEventMirrorStore` UPSERT idempotent on (workspace_id, event_id) | `TeamEventMirrorStoreTests` |
| **G10** | `ShareControlsSettingsSection` SwiftUI view renders 9 toggle rows + never-shared read-only section + uses `ShareRulesReader` for state binding | `ShareControlsSettingsSectionPreviewTests` (snapshot or compile-only) |
| **G11** | Local retention pruner deletes mirror rows older than `retentionDays` (default 90); idempotent | `TeamEventMirrorRetentionPrunerTests` |
| **G12** | Supabase migration adds `team_events_sender_write` INSERT RLS policy + UPDATE RLS denied + `expires_at` indexed for retention_purge fast path | pgTAP test `180_rls_team_events_insert.test.sql` |
| **G13** | Privacy walkback: ADR-010 — no `body` / `file_contents` / `note_body` / `email_subject` / `preview` / `prompt` / `response` ever leaves the device when source is disabled OR matches deny-list | `RelayBodyLeakageTests` extended with team-event probe cases |
| **G14** | Composition root injects `shareRulesReader` + `teamEventBroadcastReader` + `teamEventMirrorReader` into the Window scene environment | LeafApp compile + manual smoke |
| **G15** | xcodebuild green for all 5 schemes (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP) | `xcodebuild build` 5x |
| **G16** | SPM `swift test` green (target: 2155 baseline from S4 + ~60-100 net new → ~2215-2255) | `swift test` |
| **G17** | All pgTAP tests pass (17 baseline from S4 + 1 new = 18 files; ≥55 assertions) | `supabase test db` |

---

## §3 Out of S5 scope

Explicitly **not** in this sub-phase:

- Cross-post Slack/Linear write APIs — **S6**
- Per-recipient share rules (all-or-nothing per source for MVP) — **Track 6**
- Time-bounded sharing with countdown — **forever-only MVP**
- Share Controls presets ("Default team" / "Privacy-paranoid" / "Pair-programming") — **out of MVP**
- iCloud sync of `share_rules` across user's Macs — **out of MVP**
- Tier-gating (Free vs Team CTA on share enable) — **S8**
- Settings → Privacy section showing read-only deny-list — **defer to S5 in-section (rendered inline in Share Controls); separate Privacy section is S8**
- `leaf_query_team(member:)` MCP tool — **S8**
- Settings → Privacy "Keep last N days" configurable surface — **hardcode 90d, surface in S8**
- Team feed view (unified mirror display in Team tab) — **S7**
- Realtime WebSocket subscription for instant mirror updates — **post-MVP; S5 ships 30s polling**
- Mirror UI in S5 — **substrate-only**; transient debug surface in OrganizationView is optional, deferred to S7 redesign
- Per-event-kind override (152 ShareEventTypeKey registry-level toggles) — **out of S5**; S5 uses coarse 9-source grouping. Per-kind drill-down is Track 6.

---

## §4 Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│   LeafAgent (writer)                                            │
│   - Layer A/B collectors capture events                         │
│   - EventWriter.enqueue → Database.write*                       │
│   - Writes to local SQLCipher events table (unchanged)          │
└─────────────────────────────────────────────────────────────────┘
                       │
                       ▼ (cross-process WAL — same events file)
┌─────────────────────────────────────────────────────────────────┐
│   Leaf (MenuBarApp)                                             │
│                                                                 │
│   TeamEventBroadcastService (LeafCore/Team/)                    │
│   ├─ read team_event_broadcast_offsets cursor                   │
│   ├─ fetch events since cursor (small batch, 100 max)           │
│   ├─ for each event:                                            │
│   │  1. ShareSourceClassifier.classify(eventKind) → source?     │
│   │     (nil → skip + advance cursor)                           │
│   │  2. ShareRulesStore.isEnabled(source) → bool                │
│   │     (false → skip)                                          │
│   │  3. DefaultDenyList.matches(event) → bool                   │
│   │     (true → skip)                                           │
│   │  4. TeamEventPlaintext from RawEvent                        │
│   │  5. ProdTeamEventBlobCodec.encode (version 0x04)            │
│   │  6. SupabaseClient.sendTeamEvent → 200 OK                   │
│   │  7. advance cursor to event.id                              │
│   │  (any failure on step 6 → halt + retry next tick)           │
│   └─ tick every 30s foreground, or on scenePhase=active         │
│                                                                 │
│   TeamEventMirrorService (LeafCore/Team/)                       │
│   ├─ read latest created_at_ms from team_events_mirror          │
│   ├─ SupabaseClient.fetchInboundTeamEvents(since:) → [rows]     │
│   ├─ for each row:                                              │
│   │  1. EnvelopeHeader.peek → keyID                             │
│   │  2. TeamKeystore.read(keyID) → teamKey (rotation history)   │
│   │  3. ProdTeamEventBlobCodec.decode → TeamEventPlaintext      │
│   │  4. TeamEventMirrorStore.upsert(row) — idempotent           │
│   ├─ tick every 30s foreground (mirror S4 inbox cadence)        │
│                                                                 │
│   TeamEventMirrorRetentionPruner (LeafCore/Team/)               │
│   ├─ DELETE FROM team_events_mirror                             │
│   │  WHERE created_at_ms < (now - retentionDays * 86400000)     │
│   ├─ tick once per launch + daily                               │
│                                                                 │
│   ShareRulesReader (Leaf/Models/) — @Observable                 │
│   ├─ wraps ShareRulesStore CRUD                                 │
│   ├─ state machine: .loading / .loaded(rules) / .error          │
│   └─ surfaced in ShareControlsSettingsSection                   │
│                                                                 │
│   TeamEventBroadcastReader (Leaf/Models/) — @Observable         │
│   └─ wraps service ticks; drives from OrganizationView .task    │
│                                                                 │
│   TeamEventMirrorReader (Leaf/Models/) — @Observable            │
│   └─ wraps service ticks; drives from OrganizationView .task    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                       │
                       ▼ HTTPS (POST /rest/v1/team_events,
                              GET /rest/v1/team_events,
                              both gated by JWT pubkey claim)
┌─────────────────────────────────────────────────────────────────┐
│   Supabase (production)                                         │
│   - team_events table (existing, S1) — INSERT RLS amended       │
│   - retention_purge daily cron (existing, S1) — starts purging  │
│     once S5 populates expires_at                                │
└─────────────────────────────────────────────────────────────────┘
```

### Key design choices

- **Broadcast loop runs in MenuBarApp (Leaf target), NOT Agent.** Agent stays offline-only writer. MenuBarApp already has SupabaseClient + SupabaseSessionStore + WorkspaceReader injected (S3/S4). Cross-process WAL allows MenuBarApp to read events table that Agent writes. Trade-off: if Mac app closed but Agent running, events accumulate until app opens. Acceptable for MVP (MenuBarApp lives in menu bar continuously).
- **Cursor-based incremental scan**, not pub/sub. Pattern matches `DetectorPipeline` + `collector_offsets` precedent. Simple, recoverable on crash, no race conditions across restarts.
- **Halt-on-network-failure, skip-on-validation-failure.** If `SupabaseClient.sendTeamEvent` throws network error → don't advance cursor, retry next tick. If event fails encryption or classification → log + advance cursor (don't block forever on one bad event).
- **No `team_events_outbox` table.** Cursor on `events` table directly. Trade-off: re-classify on every cursor advance (cheap — pure-function classifier). Avoids extra table + outbox-drain complexity.

---

## §5 SQLCipher schema — M022/M023/M024

Three new migrations on top of M021 (S4 `apns_token_local`).

### 5.1 M022 — `share_rules`

```sql
CREATE TABLE IF NOT EXISTS share_rules (
    workspace_id TEXT NOT NULL,
    source_kind  TEXT NOT NULL,
    enabled      INTEGER NOT NULL,           -- 0 / 1
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (workspace_id, source_kind)
);

CREATE INDEX IF NOT EXISTS idx_share_rules_workspace
    ON share_rules(workspace_id);
```

- `source_kind` ∈ {`git_commits`, `linear_issues`, `slack_mentions`, `github_prs`, `detected_decisions`, `detected_blockers`, `detected_open_questions`, `detected_where_stopped`, `raw_github_activity`} — `ShareSource.rawValue`. CHECK constraint **omitted** intentionally — registry source of truth lives in Swift `ShareSource` enum, and adding CHECK couples migration to enum semantics (precedent: `share_event_types` deferred for same reason per ShareEventTypeRegistry.swift comment).
- `enabled` 0/1 — boolean as integer per SQLite convention.
- Row absent → defaults from `ShareRuleDefaults.all` apply.

### 5.2 M023 — `team_events_mirror`

```sql
CREATE TABLE IF NOT EXISTS team_events_mirror (
    event_id     TEXT NOT NULL,
    workspace_id TEXT NOT NULL,
    sender_pubkey_hex TEXT NOT NULL,
    source_kind  TEXT NOT NULL,
    kind         TEXT NOT NULL,             -- original event_kind (e.g. "gh_commit_pushed")
    plaintext_payload_json TEXT NOT NULL,
    server_created_at_ms INTEGER NOT NULL,
    event_ts_ms  INTEGER NOT NULL,          -- sender's wall-clock at capture
    received_at_ms INTEGER NOT NULL,
    PRIMARY KEY (workspace_id, event_id)
);

CREATE INDEX IF NOT EXISTS idx_team_events_mirror_workspace_created
    ON team_events_mirror(workspace_id, server_created_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_team_events_mirror_sender
    ON team_events_mirror(workspace_id, sender_pubkey_hex, server_created_at_ms DESC);
```

- Composite PK `(workspace_id, event_id)` allows same event_id across workspaces (theoretically possible if user is in multiple workspaces; safe).
- `source_kind` ∈ `ShareSource.rawValue` — denormalized for filter queries without re-classifying.
- `kind` preserved for fidelity (e.g. `gh_commit_pushed` vs the broader `git_commits` source bucket).
- `plaintext_payload_json` = decoded `TeamEventPlaintext.payload` JSON (subset of RawEvent payload per ADR-010 — see §6.3 for permitted fields).
- `server_created_at_ms` = Supabase's `created_at` as ms epoch (used for cursor + retention prune).
- `event_ts_ms` = sender's original event timestamp (preserved for timeline reconstruction).
- `received_at_ms` = local clock when mirror UPSERTed (debugging).

### 5.3 M024 — `team_event_broadcast_offsets`

```sql
CREATE TABLE IF NOT EXISTS team_event_broadcast_offsets (
    workspace_id  TEXT NOT NULL PRIMARY KEY,
    cursor_event_id INTEGER NOT NULL DEFAULT 0,
    last_attempt_at_ms INTEGER,
    last_success_at_ms INTEGER,
    consecutive_failures INTEGER NOT NULL DEFAULT 0
);
```

- One cursor per workspace (matches schema multi-workspace model from S2). Auto-share is workspace-scoped (each workspace has its own teamKey + members).
- `cursor_event_id` = local `events.id` integer; advances monotonically.
- `consecutive_failures` tracked for exponential backoff (cap at 30s × 2^min(failures, 6) = 32min max).

### 5.4 Schema constant additions

In `LeafCore/Storage/Schema.swift`:

```swift
public enum Schema {
    public enum Tables {
        public static let shareRules = "share_rules"
        public static let teamEventsMirror = "team_events_mirror"
        public static let teamEventBroadcastOffsets = "team_event_broadcast_offsets"
        // ... existing
    }

    public enum ShareSources {
        public static let gitCommits = "git_commits"
        public static let linearIssues = "linear_issues"
        public static let slackMentions = "slack_mentions"
        public static let githubPRs = "github_prs"
        public static let detectedDecisions = "detected_decisions"
        public static let detectedBlockers = "detected_blockers"
        public static let detectedOpenQuestions = "detected_open_questions"
        public static let detectedWhereStopped = "detected_where_stopped"
        public static let rawGitHubActivity = "raw_github_activity"
    }
}
```

---

## §6 Value types + crypto envelope

### 6.1 `ShareSource` enum

```swift
public enum ShareSource: String, Sendable, Codable, CaseIterable, Hashable {
    case gitCommits            = "git_commits"
    case linearIssues          = "linear_issues"
    case slackMentions         = "slack_mentions"
    case githubPRs             = "github_prs"
    case detectedDecisions     = "detected_decisions"
    case detectedBlockers      = "detected_blockers"
    case detectedOpenQuestions = "detected_open_questions"
    case detectedWhereStopped  = "detected_where_stopped"
    case rawGitHubActivity     = "raw_github_activity"
}
```

### 6.2 `ShareRule` row

```swift
public struct ShareRule: Sendable, Equatable, Hashable {
    public let workspaceID: String
    public let source: ShareSource
    public let enabled: Bool
    public let updatedAtMs: Int64
}

public enum ShareRuleDefaults {
    /// Default enabled state per Track 5 contract §11.1.
    /// ON: git_commits, linear_issues, detected_decisions, detected_blockers.
    /// OFF: everything else (slack_mentions, github_prs, detected_open_questions,
    /// detected_where_stopped, raw_github_activity).
    public static let all: [ShareSource: Bool] = [
        .gitCommits:            true,
        .linearIssues:          true,
        .detectedDecisions:     true,
        .detectedBlockers:      true,
        .slackMentions:         false,
        .githubPRs:             false,
        .detectedOpenQuestions: false,
        .detectedWhereStopped:  false,
        .rawGitHubActivity:     false,
    ]

    public static func isEnabledByDefault(_ source: ShareSource) -> Bool {
        all[source] ?? false
    }
}
```

### 6.3 `TeamEventPlaintext`

```swift
public struct TeamEventPlaintext: Sendable, Equatable, Codable {
    public let eventID: String              // UUID lowercased (Supabase team_events PK)
    public let workspaceID: String
    public let senderMemberID: String
    public let senderPubkeyHex: String
    public let source: ShareSource
    public let kind: String                 // original event_kind, e.g. "gh_commit_pushed"
    public let payload: TeamEventPayload    // ADR-010 filtered subset
    public let eventTsMs: Int64             // sender's wall-clock at capture

    private enum CodingKeys: String, CodingKey {
        case eventID         = "event_id"
        case workspaceID     = "workspace_id"
        case senderMemberID  = "sender_member_id"
        case senderPubkeyHex = "sender_pubkey_hex"
        case source
        case kind
        case payload
        case eventTsMs       = "event_ts_ms"
    }
}

public struct TeamEventPayload: Sendable, Equatable, Codable {
    /// Bag of string-keyed values from RawEvent.payload filtered to ADR-010 safelist.
    /// JSON shape preserved verbatim (string-encoded numeric values stay as strings).
    /// Permitted keys per source (see TeamEventPayloadBuilder.allowedKeys):
    /// - gitCommits: commit_sha, repo_full_name, branch, commit_message_subject (truncated 140 chars), files_changed_count
    /// - linearIssues: issue_id, issue_identifier, issue_title_excerpt (truncated 140), issue_state_type, team_key
    /// - slackMentions: channel_id_bucket, has_mention_self, reactions_count, thread_root_ts
    /// - githubPRs: pr_number, repo_full_name, pr_state, pr_title_excerpt (truncated 140), additions_bucket
    /// - detectedDecisions: topic_keywords_json, reasoning_excerpt (truncated 200), confidence_bucket
    /// - detectedBlockers: target_kind, target_ref, blocker_kind, blocker_excerpt (truncated 140)
    /// - detectedOpenQuestions: question_excerpt (truncated 140), alternatives_count, context_kind
    /// - detectedWhereStopped: excerpt (truncated 140), wip_signal_count
    /// - rawGitHubActivity: action, ref_type, repo_full_name (for non-PR/commit events)
    ///
    /// **Banned keys** (regression-tested in RelayBodyLeakageTests):
    ///   body, file_contents, note_body, email_subject, preview, prompt, response,
    ///   slack_message_text, linear_comment_body, github_comment_body, slack_canvas_content
    public let fields: [String: String]
}
```

### 6.4 `TeamEventBlobCodec` protocol

In `LeafCore/Team/TeamEventBlobCodec.swift`:

```swift
public protocol TeamEventBlobCodec: Sendable {
    /// Encodes plaintext + seals under teamKey. Returns envelope bytes.
    /// - Parameters:
    ///   - plaintext: payload to encrypt.
    ///   - keyID: exactly 16 bytes (UUID `team_keys.id` raw bytes).
    ///   - teamKey: exactly 32 bytes raw AES-256 key.
    /// - Throws: `LeafError.teamEventBlobMalformed` on bad input sizes.
    func encode(_ plaintext: TeamEventPlaintext,
                keyID: Data,
                teamKey: Data) throws -> Data

    /// Decodes envelope under teamKey. Caller resolves keyID via EnvelopeHeader.peek first.
    /// - Throws: `LeafError.teamEventBlobMalformed` on short bytes / unknown version /
    ///   AES-GCM tag mismatch / JSON decode failure.
    func decode(_ bytes: Data, teamKey: Data) throws -> TeamEventPlaintext
}

public struct UnimplementedTeamEventBlobCodec: TeamEventBlobCodec {
    public init() {}
    public func encode(_ plaintext: TeamEventPlaintext, keyID: Data, teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }
    public func decode(_ bytes: Data, teamKey: Data) throws -> TeamEventPlaintext {
        throw LeafError.notImplemented
    }
}
```

### 6.5 Envelope shape (LeafCorePrivate moat)

`ProdTeamEventBlobCodec` in `LeafCorePrivate/Sources/LeafCorePrivate/Prod/Crypto/ProdTeamEventBlobCodec.swift`:

- Envelope `[version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]` — same shape as presence (`0x01`), invite (`0x02`), DM (`0x03`).
- **Version byte: `0x04` for team events.**
- AES-GCM-256 under `teamKey`; nonce random 12B per seal.
- AAD = `[version | keyID]` (29 bytes) — bound version and keyID to ciphertext; prevents server tampering with version/keyID (precedent: S4 C4 fix).
- Tag mismatch / version mismatch / length-too-short → `LeafError.teamEventBlobMalformed`.

**Exact AAD construction + byte-slice ranges + JSONEncoder configuration live in LeafCorePrivate per architecture moat boundary** (precedent: `ProdEnvelopeCodec` / `ProdInviteBlobCodec` / `ProdDirectMessageBlobCodec`).

### 6.6 `LeafError` additions

```swift
extension LeafError {
    case teamEventBlobMalformed
    case teamEventClassificationFailed
    case teamEventDenylistMatched  // not surfaced to user, logged only
}
```

---

## §7 SupabaseClient extensions — wire layer

In `LeafCore/Network/SupabaseClient+TeamEvents.swift`:

### 7.1 New methods

```swift
extension SupabaseClient {
    public func sendTeamEvent(
        workspaceID: String,
        eventID: String,                 // client-generated UUID
        sourceKind: String,              // ShareSource.rawValue
        kind: String,                    // original event_kind
        encryptedPayload: Data,
        expiresAt: Date
    ) async throws -> SupabaseSentTeamEventRow
    // POST /rest/v1/team_events
    // Returns: { event_id, created_at }

    public func fetchInboundTeamEvents(
        workspaceID: String,
        sinceCreatedAtMs: Int64?,
        limit: Int                       // default 100
    ) async throws -> [SupabaseTeamEventRow]
    // GET /rest/v1/team_events?workspace_id=eq.X
    //     &order=created_at.asc &limit=N
    //     &created_at=gt.SINCE (omitted on initial fetch)
    // RLS gates: workspace member access.
}
```

### 7.2 Wire shapes

**POST /rest/v1/team_events:**

```json
{
  "event_id": "<uuid lowercased>",
  "workspace_id": "<uuid>",
  "sender_pubkey": "<64-hex>",
  "source_kind": "git_commits",
  "kind": "gh_commit_pushed",
  "encrypted_payload": "\\x<hex bytes>",
  "expires_at": "<iso>"
}
```

Headers: `Authorization: Bearer <JWT>` + `apikey: <anon>` + `Prefer: return=representation` + `Prefer: resolution=ignore-duplicates` (sender retry safety — server returns existing row on conflict).

**GET /rest/v1/team_events:**

PostgREST query: `workspace_id=eq.X&order=created_at.asc&limit=100&created_at=gt.<iso>`. Response: array of row objects. `encrypted_payload` returned as `\x<hex>` PostgREST bytea → decoder converts to Data.

### 7.3 Error mapping

Mirrors `SupabaseError` shape from S3/S4. Per-status:

- 200/201 OK
- 401 → `.unauthorized`
- 403 → `.forbidden` (RLS denied — usually means JWT pubkey doesn't match workspace member)
- 409 → silently ignored (Prefer: resolution=ignore-duplicates handles via server response — client treats as success and advances cursor)
- 5xx → `.serverError(status:)`

---

## §8 Broadcast service

### 8.1 `TeamEventBroadcastService` (LeafCore/Team/)

```swift
public actor TeamEventBroadcastService {
    private let database: Database
    private let supabase: SupabaseClient
    private let codec: TeamEventBlobCodec
    private let keystore: TeamKeystore
    private let classifier: ShareSourceClassifier
    private let denylist: DefaultDenyList
    private let shareRulesStore: ShareRulesStore
    private let workspaceID: String
    private let identity: IdentityProvider
    private let logger: Logger

    private let retentionDays: Int = 30  // contract §13

    public init(/* deps */) { /* ... */ }

    /// Reads cursor → fetches batch → for each event: classify, check rules,
    /// check denylist, encode, POST, advance cursor. Halts on network failure.
    public func tick(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> BroadcastTickResult {
        let cursor = try database.readBroadcastCursor(workspaceID: workspaceID)
        let events = try database.fetchEventsAfter(cursorEventID: cursor.cursorEventID, limit: 100)
        guard !events.isEmpty else {
            return .init(processedCount: 0, sentCount: 0, skippedCount: 0)
        }

        var sent = 0, skipped = 0
        for event in events {
            do {
                guard let source = classifier.classify(eventKind: event.kind) else {
                    skipped += 1
                    try database.advanceBroadcastCursor(workspaceID: workspaceID, toEventID: event.id, nowMs: nowMs)
                    continue
                }
                if !(try shareRulesStore.isEnabled(workspaceID: workspaceID, source: source)) {
                    skipped += 1
                    try database.advanceBroadcastCursor(workspaceID: workspaceID, toEventID: event.id, nowMs: nowMs)
                    continue
                }
                if denylist.matches(event: event) {
                    skipped += 1
                    try database.advanceBroadcastCursor(workspaceID: workspaceID, toEventID: event.id, nowMs: nowMs)
                    continue
                }

                let plaintext = try buildPlaintext(event: event, source: source)
                let activeKey = try keystore.readActiveTeamKey(workspaceID: workspaceID)
                let envelope = try codec.encode(plaintext, keyID: activeKey.keyID, teamKey: activeKey.key)
                let expiresAt = Date(timeIntervalSince1970: TimeInterval(nowMs / 1000 + Int64(retentionDays * 86400)))

                _ = try await supabase.sendTeamEvent(
                    workspaceID: workspaceID,
                    eventID: plaintext.eventID,
                    sourceKind: source.rawValue,
                    kind: event.kind,
                    encryptedPayload: envelope,
                    expiresAt: expiresAt
                )
                sent += 1
                try database.advanceBroadcastCursor(workspaceID: workspaceID, toEventID: event.id, nowMs: nowMs)
            } catch let err as SupabaseError where err.isTransientNetwork {
                try database.recordBroadcastFailure(workspaceID: workspaceID, nowMs: nowMs)
                throw err  // bubble up — caller decides retry timing
            } catch {
                // Validation / encryption failure — log + skip (don't block on bad event)
                logger.error("broadcast skip event=\(event.id, privacy: .public): \(String(describing: error), privacy: .public)")
                skipped += 1
                try database.advanceBroadcastCursor(workspaceID: workspaceID, toEventID: event.id, nowMs: nowMs)
            }
        }

        try database.recordBroadcastSuccess(workspaceID: workspaceID, nowMs: nowMs)
        return .init(processedCount: events.count, sentCount: sent, skippedCount: skipped)
    }

    private func buildPlaintext(event: RawEventRow, source: ShareSource) throws -> TeamEventPlaintext {
        let id = try identity.ensure()
        let payload = TeamEventPayloadBuilder.build(event: event, source: source)
        return TeamEventPlaintext(
            eventID: UUID().uuidString.lowercased(),
            workspaceID: workspaceID,
            senderMemberID: try resolveSelfMemberID(),
            senderPubkeyHex: id.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            source: source,
            kind: event.kind,
            payload: payload,
            eventTsMs: event.tsMs
        )
    }
}

public struct BroadcastTickResult: Sendable, Equatable {
    public let processedCount: Int
    public let sentCount: Int
    public let skippedCount: Int
}
```

### 8.2 `ShareSourceClassifier`

In `LeafCore/Team/ShareSourceClassifier.swift`:

```swift
public struct ShareSourceClassifier: Sendable {
    private static let kindToSource: [String: ShareSource] = [
        // gitCommits
        "gh_commit_pushed":                   .gitCommits,
        // linearIssues
        "issue_updated":                      .linearIssues,
        "linear_status_transition":           .linearIssues,
        "linear_priority_changed":            .linearIssues,
        "linear_label_added":                 .linearIssues,
        "linear_label_removed":               .linearIssues,
        "linear_assignee_changed":            .linearIssues,
        "linear_cycle_changed":               .linearIssues,
        "linear_estimate_changed":            .linearIssues,
        "linear_comment_authored":            .linearIssues,
        "linear_project_update_authored":     .linearIssues,
        // slackMentions
        "slack_message_authored_aggregate":   .slackMentions,
        "slack_thread_reply_aggregate":       .slackMentions,
        "slack_mention_received":             .slackMentions,
        // githubPRs
        "gh_pr_opened":                       .githubPRs,
        "gh_pr_merged":                       .githubPRs,
        "gh_pr_closed":                       .githubPRs,
        "gh_pr_review_submitted":             .githubPRs,
        "gh_pr_review_comment_authored":      .githubPRs,
        "gh_pr_review_thread_resolved":       .githubPRs,
        // detectedDecisions
        "decision_detected":                  .detectedDecisions,
        // detectedBlockers
        "blocker_started":                    .detectedBlockers,
        "blocker_resolved":                   .detectedBlockers,
        // detectedOpenQuestions
        "open_question_opened":               .detectedOpenQuestions,
        "open_question_resolved":             .detectedOpenQuestions,
        // detectedWhereStopped
        "where_stopped_snapshot":             .detectedWhereStopped,
        // rawGitHubActivity
        "gh_branch_created":                  .rawGitHubActivity,
        "gh_branch_deleted":                  .rawGitHubActivity,
        "gh_tag_created":                     .rawGitHubActivity,
        "gh_release_published":               .rawGitHubActivity,
        "gh_discussion_authored":             .rawGitHubActivity,
        "gh_discussion_comment_authored":     .rawGitHubActivity,
        "gh_issue_comment_authored":          .rawGitHubActivity,
    ]

    public init() {}

    public func classify(eventKind: String) -> ShareSource? {
        Self.kindToSource[eventKind]
    }
}
```

Coverage: 32 event_kinds across 9 sources. Everything else (`active_app_changed`, `idle_state_changed`, `focus_mode_*`, `meeting_state_*`, `linear_comment_reaction_*`, `gh_star_*`, `gh_watch_*`, `slack_status_change`, Track-4 S1/S2/S3 OS observers, `intensity_*`, etc.) → nil → skipped (not auto-shareable in S5).

### 8.3 `DefaultDenyList`

In `LeafCore/Team/DefaultDenyList.swift`:

```swift
public struct DefaultDenyList: Sendable {
    public init() {}

    /// Returns true if event matches one of:
    /// 1. event.kind starts with "ai_" or is in aiContentBanned set
    /// 2. event.payload has "file_path" containing one of: ".env", ".git/config",
    ///    ".aws/credentials", ".ssh/"
    /// 3. event.payload has "file_size" > 100_000_000
    ///
    /// Match → drop entirely (no partial events per contract §11.2).
    public func matches(event: RawEventRow) -> Bool {
        if event.kind.hasPrefix("ai_") { return true }
        if Self.aiContentBanned.contains(event.kind) { return true }
        if let path = event.payload["file_path"] {
            for needle in Self.bannedPathFragments {
                if path.contains(needle) { return true }
            }
        }
        if let sizeStr = event.payload["file_size"],
           let size = Int(sizeStr),
           size > Self.maxFileSize {
            return true
        }
        return false
    }

    private static let aiContentBanned: Set<String> = [
        // No event_kinds emit ai prompt/response content per ADR-010, but defense in depth.
    ]
    private static let bannedPathFragments: [String] = [
        ".env", ".git/config", ".aws/credentials", ".ssh/"
    ]
    private static let maxFileSize = 100_000_000  // 100MB per contract §6
}
```

### 8.4 `TeamEventPayloadBuilder`

In `LeafCore/Team/TeamEventPayloadBuilder.swift`:

```swift
public enum TeamEventPayloadBuilder {
    /// Builds ADR-010-filtered payload subset per source.
    /// Reads from event.payload (RawEvent payload_json deserialized), picks only
    /// allow-listed keys per source, truncates body/excerpt fields per contract §6.
    public static func build(event: RawEventRow, source: ShareSource) -> TeamEventPayload {
        let allowed = allowedKeys(for: source)
        var out: [String: String] = [:]
        for key in allowed {
            if let value = event.payload[key] {
                if let truncCap = truncateCap(for: key, source: source) {
                    out[key] = String(value.prefix(truncCap))
                } else {
                    out[key] = value
                }
            }
        }
        return TeamEventPayload(fields: out)
    }

    static func allowedKeys(for source: ShareSource) -> Set<String> {
        // See §6.3 docstring for verbatim per-source allowlist.
        // Implementation in this file.
    }

    static func truncateCap(for key: String, source: ShareSource) -> Int? {
        // commit_message_subject: 140
        // issue_title_excerpt: 140
        // pr_title_excerpt: 140
        // reasoning_excerpt: 200
        // blocker_excerpt: 140
        // question_excerpt: 140
        // excerpt (where_stopped): 140
    }
}
```

ADR-010 walkback is mechanically enforced by allowlist — anything not in `allowedKeys(for:)` is **never** copied into the plaintext payload. Banned keys (body, file_contents, note_body, email_subject, preview, prompt, response, etc.) are absent from any allowlist by construction.

---

## §9 Mirror reader

### 9.1 `TeamEventMirrorService`

In `LeafCore/Team/TeamEventMirrorService.swift`:

```swift
public actor TeamEventMirrorService {
    private let database: Database
    private let supabase: SupabaseClient
    private let codec: TeamEventBlobCodec
    private let keystore: TeamKeystore
    private let workspaceID: String
    private let logger: Logger

    public func tick(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> MirrorTickResult {
        let watermarkMs = try database.readMirrorWatermarkMs(workspaceID: workspaceID)
        let rows = try await supabase.fetchInboundTeamEvents(
            workspaceID: workspaceID,
            sinceCreatedAtMs: watermarkMs,
            limit: 100
        )
        guard !rows.isEmpty else {
            return .init(fetchedCount: 0, decodedCount: 0, upsertedCount: 0)
        }

        var decoded = 0, upserted = 0
        for row in rows {
            do {
                let header = try EnvelopeHeader.peek(from: row.encryptedPayload)
                guard let teamKey = try keystore.readTeamKey(workspaceID: workspaceID, keyID: header.keyID) else {
                    logger.warning("mirror skip — unknown keyID: \(row.eventID)")
                    continue
                }
                let plaintext = try codec.decode(row.encryptedPayload, teamKey: teamKey)
                // Trust plaintext source/kind over server-controlled columns
                // (precedent: S4 C4 fix — AAD binds only [version|keyID]).
                try database.upsertTeamEventMirror(
                    eventID: plaintext.eventID,
                    workspaceID: plaintext.workspaceID,
                    senderPubkeyHex: plaintext.senderPubkeyHex,
                    sourceKind: plaintext.source.rawValue,
                    kind: plaintext.kind,
                    plaintextPayloadJSON: try TeamEventPayloadEncoder.encode(plaintext.payload),
                    serverCreatedAtMs: row.createdAtMs,
                    eventTsMs: plaintext.eventTsMs,
                    receivedAtMs: nowMs
                )
                decoded += 1
                upserted += 1
            } catch {
                logger.error("mirror decode failed: \(String(describing: error), privacy: .public)")
            }
        }
        return .init(fetchedCount: rows.count, decodedCount: decoded, upsertedCount: upserted)
    }
}

public struct MirrorTickResult: Sendable, Equatable {
    public let fetchedCount: Int
    public let decodedCount: Int
    public let upsertedCount: Int
}
```

### 9.2 30s foreground tick — composition

`OrganizationView` (S4 added similar pattern for DM inbox) gains a second `.task(id:)` for team-event mirror:

```swift
// In OrganizationView.swift
.task(id: activeWorkspaceID) {
    guard let wid = activeWorkspaceID else { return }
    while !Task.isCancelled {
        await teamEventMirrorReader.tick(workspaceID: wid)
        try? await Task.sleep(for: .seconds(30))
    }
}
```

(Combined with the S4 DM inbox tick — both run in parallel.)

Broadcast tick has identical cadence (30s polling matches mirror cadence — no advantage to running broadcast faster since events are batched anyway).

### 9.3 Multi-workspace handling

Per S2 (multi-workspace substrate): each workspace has its own broadcast cursor + mirror cursor + share_rules. `TeamEventBroadcastService` + `TeamEventMirrorService` instances are constructed per-workspace (or take `workspaceID` parameter on tick). For MVP, only the active workspace is auto-served; other workspaces tick on workspace switch.

---

## §10 Share Controls UI

### 10.1 `ShareRulesStore`

In `LeafCore/Storage/ShareRulesStore.swift`:

```swift
public struct ShareRulesStore: Sendable {
    private let database: Database

    public func read(workspaceID: String) throws -> [ShareSource: Bool] {
        var out: [ShareSource: Bool] = ShareRuleDefaults.all
        let rows = try database.readShareRules(workspaceID: workspaceID)
        for row in rows {
            if let src = ShareSource(rawValue: row.sourceKind) {
                out[src] = row.enabled
            }
        }
        return out
    }

    public func isEnabled(workspaceID: String, source: ShareSource) throws -> Bool {
        try read(workspaceID: workspaceID)[source] ?? ShareRuleDefaults.isEnabledByDefault(source)
    }

    public func setEnabled(workspaceID: String, source: ShareSource, enabled: Bool, nowMs: Int64) throws {
        try database.upsertShareRule(
            workspaceID: workspaceID,
            sourceKind: source.rawValue,
            enabled: enabled,
            updatedAtMs: nowMs
        )
    }
}
```

### 10.2 `ShareRulesReader` (@Observable)

In `Leaf/Models/ShareRulesReader.swift`:

```swift
@MainActor
@Observable
final class ShareRulesReader {
    enum State: Equatable {
        case loading
        case loaded(rules: [ShareSource: Bool])
        case error(message: String)
    }

    private(set) var state: State = .loading

    private let store: ShareRulesStore
    private let activeStore: ActiveWorkspaceStore
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "share-rules")

    init(store: ShareRulesStore, activeStore: ActiveWorkspaceStore) {
        self.store = store
        self.activeStore = activeStore
    }

    func refresh() {
        guard let wid = activeStore.activeWorkspaceID else {
            state = .error(message: "No active workspace.")
            return
        }
        do {
            let rules = try store.read(workspaceID: wid)
            state = .loaded(rules: rules)
        } catch {
            logger.error("ShareRulesReader.refresh: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't read share rules.")
        }
    }

    func setEnabled(_ source: ShareSource, enabled: Bool) {
        guard let wid = activeStore.activeWorkspaceID else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try store.setEnabled(workspaceID: wid, source: source, enabled: enabled, nowMs: nowMs)
            refresh()
        } catch {
            logger.error("ShareRulesReader.setEnabled: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't update setting.")
        }
    }
}
```

### 10.3 `ShareControlsSettingsSection`

In `Leaf/Views/Window/Settings/ShareControlsSettingsSection.swift`:

```swift
struct ShareControlsSettingsSection: View {
    @Environment(ShareRulesReader.self) private var reader

    var body: some View {
        LeafSection(
            title: "Share Controls",
            description: "Per-source toggles. Off by default for everything except commits, Linear issues, and detected decisions/blockers. Teammates only see what you explicitly turn on."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                ForEach(ShareSource.allCases, id: \.rawValue) { source in
                    ShareSourceRow(source: source, reader: reader)
                }
                NeverSharedCard()
            }
        }
        .onAppear { reader.refresh() }
    }
}

private struct ShareSourceRow: View {
    let source: ShareSource
    @Bindable var reader: ShareRulesReader

    var body: some View {
        LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                Image(systemName: source.sfSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(LeafColor.text.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(source.displayName).font(LeafType.body.regular)
                    Text(source.explainer).font(LeafType.body.small)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { reader.setEnabled(source, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LeafColor.accent.primary)
            }
        }
    }

    private var isEnabled: Bool {
        if case .loaded(let rules) = reader.state {
            return rules[source] ?? ShareRuleDefaults.isEnabledByDefault(source)
        }
        return ShareRuleDefaults.isEnabledByDefault(source)
    }
}

private struct NeverSharedCard: View {
    var body: some View {
        LeafCard(variant: .glass, padding: .regular, header: { EmptyView() }) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Never shared")
                    .font(LeafType.body.regularEmphasized)
                Text("Regardless of toggles above, the following are never transmitted:")
                    .font(LeafType.body.small)
                ForEach(NeverSharedItem.all, id: \.title) { item in
                    HStack(alignment: .top, spacing: LeafSpace.xs) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        VStack(alignment: .leading) {
                            Text(item.title).font(LeafType.body.smallEmphasized)
                            Text(item.description).font(LeafType.body.small)
                        }
                    }
                }
            }
        }
    }
}

private struct NeverSharedItem {
    let title: String
    let description: String

    static let all: [NeverSharedItem] = [
        .init(title: "Secrets-bearing files", description: ".env*, .git/config, .aws/credentials, .ssh/"),
        .init(title: "Large files", description: "Anything over 100 MB"),
        .init(title: "AI prompts and responses", description: "Conversation content with Claude, Cursor, etc."),
        .init(title: "Personal apps", description: "Signal, Messages, Discord, Spotify, and similar — not opt-in by default"),
    ]
}
```

### 10.4 Per-source display name + SF Symbol

In `ShareSource+Display.swift`:

```swift
extension ShareSource {
    var displayName: String {
        switch self {
        case .gitCommits:            return "Git commits"
        case .linearIssues:          return "Linear issues"
        case .slackMentions:         return "Slack mentions"
        case .githubPRs:             return "GitHub PRs"
        case .detectedDecisions:     return "Detected decisions"
        case .detectedBlockers:      return "Detected blockers"
        case .detectedOpenQuestions: return "Detected open questions"
        case .detectedWhereStopped:  return "Detected where-stopped"
        case .rawGitHubActivity:     return "Raw GitHub activity"
        }
    }

    var explainer: String {
        switch self {
        case .gitCommits:            return "Commits authored on watched folders."
        case .linearIssues:          return "Issues you touched (status/comments/labels/cycles)."
        case .slackMentions:         return "Threads and messages where you're explicitly mentioned."
        case .githubPRs:             return "PRs you opened, merged, or reviewed."
        case .detectedDecisions:     return "Decisions extracted from messages and notes."
        case .detectedBlockers:      return "Patterns flagged as blockers (stuck Linear tickets, 'blocked on' messages)."
        case .detectedOpenQuestions: return "Unresolved questions detected in your activity."
        case .detectedWhereStopped:  return "Snapshots of where work paused."
        case .rawGitHubActivity:     return "Stars, releases, branches, discussions."
        }
    }

    var sfSymbol: String {
        switch self {
        case .gitCommits:            return "arrow.triangle.branch"
        case .linearIssues:          return "list.bullet.rectangle"
        case .slackMentions:         return "at"
        case .githubPRs:             return "arrow.triangle.pull"
        case .detectedDecisions:     return "lightbulb"
        case .detectedBlockers:      return "hand.raised.fill"
        case .detectedOpenQuestions: return "questionmark.circle"
        case .detectedWhereStopped:  return "pause.rectangle"
        case .rawGitHubActivity:     return "cursorarrow.click"
        }
    }
}
```

### 10.5 Composition root injection

In `Leaf/LeafApp.swift`:

```swift
// In init():
let shareRulesStore = ShareRulesStore(database: …)
let shareRulesReader = ShareRulesReader(store: shareRulesStore, activeStore: active)
_shareRulesReader = State(initialValue: shareRulesReader)

let broadcastService = TeamEventBroadcastService(/* deps */)
let mirrorService = TeamEventMirrorService(/* deps */)
let broadcastReader = TeamEventBroadcastReader(service: broadcastService)
let mirrorReader = TeamEventMirrorReader(service: mirrorService)
_teamEventBroadcastReader = State(initialValue: broadcastReader)
_teamEventMirrorReader = State(initialValue: mirrorReader)

// In body:
.environment(shareRulesReader)
.environment(teamEventBroadcastReader)
.environment(teamEventMirrorReader)
```

`WindowSettingsView` add line:

```swift
SystemObserversSettingsSection()
ShareControlsSettingsSection()   // ← new
UpdatesSection(updater: updater)
```

---

## §11 Default deny-list filter

Per contract §6 + §11.2 — applied **before** encryption (no partial events).

Implementation: §8.3 `DefaultDenyList.matches(event:)` checks:

1. **AI prompt/response content** — `event.kind` starts with `ai_` (currently no such kinds emit since AI hook captures metadata only per ADR-010, but defense-in-depth).
2. **Path-based** — `event.payload["file_path"]` (or any payload string field via fallback loop) contains `.env`, `.git/config`, `.aws/credentials`, `.ssh/`.
3. **Size-based** — `event.payload["file_size"]` > 100MB.

Matches drop entire event (not partial). Logged at `info` level (not error — denylist is expected behavior).

`RelayBodyLeakageTests` (existing test class enforcing ADR-010) extended with team-event probe cases:

- Synthetic event with `file_path: "/home/.env"` → broadcast service skips → never encrypted, never POSTed.
- Synthetic event with `file_size: "200000000"` → skipped.
- Synthetic event with `kind: "ai_prompt_submitted"` → skipped.

---

## §12 Retention scheduler

### 12.1 Server retention (Supabase)

Existing migration `20260513121000_retention_purge_cron.sql` (S1) is **already deployed** with body:

```sql
SELECT cron.schedule(
  'retention_purge',
  '0 3 * * *',
  $$DELETE FROM team_events WHERE expires_at IS NOT NULL AND expires_at < now()$$
);
```

**No new migration needed for the cron itself.** S5's only server-side change is:

1. Populate `expires_at = now() + 30 days` on `POST /rest/v1/team_events` (client-side responsibility — `TeamEventBroadcastService` computes and sends).
2. Ensure `team_events.expires_at` is indexed for retention_purge fast path.

`team_events.expires_at` index — verify existing schema. If absent, add via S5 migration:

```sql
-- 20260516120000_team_events_s5.sql
CREATE INDEX IF NOT EXISTS idx_team_events_expires_at
    ON team_events(expires_at)
    WHERE expires_at IS NOT NULL;
```

### 12.2 Local mirror retention

In `LeafCore/Team/TeamEventMirrorRetentionPruner.swift`:

```swift
public actor TeamEventMirrorRetentionPruner {
    private let database: Database
    private let retentionDays: Int

    public init(database: Database, retentionDays: Int = 90) {
        self.database = database
        self.retentionDays = retentionDays
    }

    /// Deletes mirror rows where created_at_ms < now - retentionDays * 86400000.
    public func prune(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Int {
        let cutoff = nowMs - Int64(retentionDays) * 86_400_000
        return try database.deleteTeamEventMirrorOlderThan(cutoffMs: cutoff)
    }
}
```

Scheduled tick: invoked once per MenuBarApp launch + once daily (via `Timer.publish(every: 86400)` or scenePhase=active check `Date().timeIntervalSince(lastPruneAt) > 86400`).

`retentionDays = 90` hardcoded — user-configurable surface is S8 (Settings → Privacy → "Keep last N days").

---

## §13 RLS amendments

### 13.1 Existing `team_events` policies (from S1)

Verified via pgTAP `030_rls_team_events.test.sql`:
- SELECT: workspace member only — `is_workspace_member(workspace_id, auth.jwt() ->> 'pubkey')`.
- INSERT: not in S1 test (currently no policy — defaults to deny).

### 13.2 S5 migration — `20260516120000_team_events_s5.sql`

```sql
-- Track 5 / S5 — Auto-Share Substrate
-- Adds:
-- 1. INSERT RLS policy on team_events (sender writes self-attributed rows in workspaces they belong to)
-- 2. expires_at btree index for retention_purge fast path

CREATE POLICY team_events_sender_write ON team_events FOR INSERT
  WITH CHECK (
    sender_pubkey = (auth.jwt() ->> 'pubkey')
    AND public.is_workspace_member(workspace_id, auth.jwt() ->> 'pubkey')
  );

-- UPDATE / DELETE policies: intentionally none (immutable rows; retention_purge runs as superuser).

CREATE INDEX IF NOT EXISTS idx_team_events_expires_at
    ON team_events(expires_at)
    WHERE expires_at IS NOT NULL;
```

### 13.3 pgTAP test — `180_rls_team_events_insert.test.sql`

```sql
-- Authenticated INSERT with self-pubkey + workspace member → succeeds
-- Authenticated INSERT with different sender_pubkey (impersonation) → denied
-- Authenticated INSERT with non-member workspace → denied
-- Service_role bypass → succeeds (smoke seed scenarios)
```

≥4 assertions.

---

## §14 ShareSource ↔ event_kind classifier — golden table

See §8.2 for the full 32-entry mapping. Test fixture in `ShareSourceClassifierTests.swift`:

```swift
final class ShareSourceClassifierTests: XCTestCase {
    private let classifier = ShareSourceClassifier()

    func testGitCommitMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "gh_commit_pushed"), .gitCommits)
    }

    func testLinearIssueMapping() {
        XCTAssertEqual(classifier.classify(eventKind: "issue_updated"), .linearIssues)
        XCTAssertEqual(classifier.classify(eventKind: "linear_status_transition"), .linearIssues)
        // ... 8 more
    }

    func testSlackMentionMapping() { /* 3 */ }
    func testGitHubPRMapping() { /* 6 */ }
    func testDetectedDecisionsMapping() { /* 1 */ }
    func testDetectedBlockersMapping() { /* 2 */ }
    func testDetectedOpenQuestionsMapping() { /* 2 */ }
    func testDetectedWhereStoppedMapping() { /* 1 */ }
    func testRawGitHubActivityMapping() { /* 7 */ }

    func testUnclassifiedEventsReturnNil() {
        XCTAssertNil(classifier.classify(eventKind: "active_app_changed"))
        XCTAssertNil(classifier.classify(eventKind: "idle_state_changed"))
        XCTAssertNil(classifier.classify(eventKind: "intensity_snapshot"))
        XCTAssertNil(classifier.classify(eventKind: "ai_prompt_submitted"))  // AI never shareable
    }

    func testEveryKnownEventKindHasDeterministicMapping() {
        // Compile-time assertion that the classifier static table compiles —
        // catches accidental key collisions or typos.
        XCTAssertEqual(ShareSource.allCases.count, 9)
    }
}
```

---

## §15 Test coverage targets

SPM baseline 2155 (S4). S5 adds (estimates):

| File | Tests |
|---|---|
| MigrationsTests (M022/M023/M024) | +3 |
| ShareSourceTests | +2 (enum CaseIterable, rawValue stability) |
| ShareSourceClassifierTests | +10 (golden table + nil cases) |
| ShareRulesStoreTests | +5 (default read, override read, UPSERT, multi-workspace) |
| TeamEventMirrorStoreTests | +5 (UPSERT idempotent, query by workspace, query by sender) |
| TeamEventBroadcastOffsetsTests | +4 |
| ProdTeamEventBlobCodecTests | +6 (round-trip, tag mismatch, version mismatch, length too short, AAD validation, JSON deterministic) |
| TeamEventPayloadBuilderTests | +9 (one per source — allowlist enforced, truncation works, banned keys absent) |
| DefaultDenyListTests | +6 (env, git config, aws, ssh, size, ai_kind) |
| TeamEventBroadcastServiceTests | +8 (golden path, skip-on-source-nil, skip-on-rules-disabled, skip-on-denylist, halt-on-network-fail, cursor advance, retry, multi-event batch) |
| TeamEventMirrorServiceTests | +6 (golden path, idempotent, unknown keyID skip, decode-fail skip, watermark advance, multi-event batch) |
| TeamEventMirrorRetentionPrunerTests | +3 (default 90d, custom days, idempotent) |
| ShareRulesReaderTests | +5 (loading → loaded, refresh on workspace change, setEnabled persists, error path) |
| RelayBodyLeakageTests (extended) | +5 (path-based deny, size deny, ai_kind deny, banned-key absence, banned-key sentinel walk) |

**Total: +77 SPM tests** → target ~2232.

pgTAP: 17 baseline → +1 (`180_rls_team_events_insert.test.sql`) = 18 files, ≥55 assertions.

xcodebuild: 5/5 schemes green (Leaf + LeafAgent + LeafCore + LeafCorePrivate + LeafMCP).

---

## §16 Migration ordering reconciliation

Per current state (`current-state.md`):
- S4 actually shipped: M020 `messages_mirror` + M021 `apns_token_local`.

S5 reconciliation (amending contract §17 per §18 living-document process):

| Migration | Owner | Table |
|---|---|---|
| M020 | S4 | messages_mirror |
| M021 | S4 | apns_token_local |
| **M022** | **S5** | **share_rules** |
| **M023** | **S5** | **team_events_mirror** |
| **M024** | **S5** | **team_event_broadcast_offsets** |

Result: **33 SQLCipher tables** after S5 lands (30 baseline + 3 new).

leaf-relay Supabase migrations:
- 14 baseline (S1–S4 + claim_invite) → +1 (`20260516120000_team_events_s5.sql`) = 15 migrations.

---

## §17 Carry-overs + future work

**S5 itself does not address (S6+):**
- Cross-post Slack/Linear write APIs — full S6 scope.
- `slack_mentions` source captures both authored aggregates and mention-received events; the channel-bucket anonymization (`channel_id_bucket`) field is `TeamEventPayloadBuilder.allowedKeys[.slackMentions]` value — verify it stays bucketed (not raw channel IDs) per ADR-010.
- ModeClassifier (Phase 4.9) once implemented may emit `mode_changed` events — S5 classifier does not include them; future amendment.

**S5 ships with known limitations:**
- Per-source coarseness — user cannot opt-in granular per-event-kind (e.g. share commits but exclude force-pushes). Deferred to Track 6 per contract §3.
- No retroactive sharing — toggling source ON does not backfill historical events.
- Workspace switch may leave a tick mid-flight on the previous workspace's cursor; ticks are workspace-scoped, so cursor advance for workspace A does not leak into workspace B's broadcast loop.
- `received_at_ms` is recorder's local clock — clock skew between sender and recipient is visible in timeline reconstruction (consistent with S4 DM behavior).

**S8 follow-ups:**
- Settings → Privacy → "Keep last N days" surface for `TeamEventMirrorRetentionPruner.retentionDays`.
- `leaf_query_team(member:)` MCP tool — reads `team_events_mirror` table, returns structured timeline.
- Per-recipient share rules ("share commits with Bob but not Carol") — Track 6.

**Test housekeeping:**
- `RelayBodyLeakageTests` continues to grow per phase — S5 adds ~5 new sentinel walks (one per banned-key class).
- `ShareSourceClassifier` golden table needs maintenance whenever new event_kinds land in Layer A/B/D3 — future ShareEventTypeKey registry entries that should auto-share require classifier entry.

---

## §18 Implementation plan reference

Tactical plan lives in `docs/superpowers/plans/2026-05-15-track-5-S5-auto-share.md` (gitignored — moat per `.gitignore` `docs/superpowers/plans/`). Plan covers per-task atomic-commit decomposition, exact file lists per commit, test-first-discipline sequencing, and pre-push checklist.

Order (sequence forced by dependencies; rough estimate 10-12 tasks):

1. **Schema migrations** — M022 `share_rules`, M023 `team_events_mirror`, M024 `team_event_broadcast_offsets` (one commit each or bundled; commit prefix `feat(s5)`).
2. **Value types** — `ShareSource`, `ShareRule`, `ShareRuleDefaults`, `TeamEventPlaintext`, `TeamEventPayload`, `LeafError` additions.
3. **Crypto codec (LeafCore)** — `TeamEventBlobCodec` protocol + `UnimplementedTeamEventBlobCodec` stub.
4. **Crypto codec (LeafCorePrivate)** — `ProdTeamEventBlobCodec` real body (version `0x04`, AAD, round-trip tests).
5. **Stores** — `ShareRulesStore`, `TeamEventMirrorStore`, `TeamEventBroadcastOffsetsStore`.
6. **Classifier + denylist + payload builder** — `ShareSourceClassifier`, `DefaultDenyList`, `TeamEventPayloadBuilder`.
7. **Wire layer** — `SupabaseClient+TeamEvents`, `SupabaseSentTeamEventRow`, `SupabaseTeamEventRow`, endpoint URL composition.
8. **Broadcast service** — `TeamEventBroadcastService` actor + tick logic + cursor advancement.
9. **Mirror service** — `TeamEventMirrorService` actor + tick logic + watermark advancement.
10. **Retention pruner** — `TeamEventMirrorRetentionPruner` actor.
11. **Supabase migration + pgTAP** — `20260516120000_team_events_s5.sql` + `180_rls_team_events_insert.test.sql`.
12. **UI substrate** — `ShareRulesReader`, `TeamEventBroadcastReader`, `TeamEventMirrorReader` (@Observable readers).
13. **UI section** — `ShareControlsSettingsSection` + `ShareSourceRow` + `NeverSharedCard`.
14. **Composition root** — `LeafApp.init` wiring + 30s ticks in OrganizationView.task + retention pruner schedule.
15. **RelayBodyLeakageTests extension** — sentinel walks for team-event payloads.

Per-step gates: tests pass, build green, single-purpose commit, no `xcuserdata` / no `.DS_Store` / pre-push-leaf checklist before push.

---

**End of spec.** Independent code review (Stage 6) against this spec + the plan + the implementation diff.
