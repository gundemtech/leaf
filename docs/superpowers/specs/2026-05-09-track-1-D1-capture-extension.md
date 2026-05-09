# Track 1 / D1 — Capture Extension: bodies + attachments + Phase 4.8 PR metadata

**Status:** Active (2026-05-09). First sub-phase of Track 1 stack.
**Owner:** Dmitrii.
**Stack:** branches off `feature/track-1-detection-substrate`. **НЕ merged в main** — D1 → D2 → D3 идут sequential, merge стэка в main коллективно после D3 ship + acceptance gate (контракт §13).

---

## 1. Context

D1 — substrate sub-phase, открывает Track 1 ("solo detection substrate"). Контракт уровня track'а — `2026-05-08-track-1-detection-substrate-contract.md`. Декомпозиция (§4 контракта): D1 capture → D2 FTS5+links → D3 detectors+structured MCP. Track 1 acceptance gate (§13 контракта) — UC1/UC3/UC4/UC5/UC6 work end-to-end.

**Зачем сейчас.** Сейчас все 3 Layer B collectors (Linear / GitHub / Slack) дропают content на этапе захвата:

| Сurface | Где дропается | Strict ADR-010 v1 |
|---|---|---|
| Linear | `LinearGraphQLProvider.swift:206-277` `IssueFragment` selection не запрашивает `description`; nested-comments fragment (line 414-465) не запрашивает `body` | "no body fields anywhere" |
| Slack | `SlackCollector.swift:72-73` + `:503-531` — `message.text` отбрасывается до payload assembly | "no message text" |
| GitHub | `GitHubCollector.swift:104-105` — commit message **truncated до first line** (subject only, всё после `\n` discarded); PR `body` / `issue_comment.body` / `pr_review_comment.body` не извлекаются из `payload` event'а | "no PR/comment bodies" |

Без on-device bodies нет substrate'а для D2 FTS5 keyword index и D3 паттерн-детекторов. UC1 ("что я делал в пятницу по auth?") требует topic-search по commit messages + Slack thread bodies + Linear ticket descriptions. UC4 ("почему вынесли OAuth refresh на сервер?") требует raw reasoning excerpts из Linear / Slack thread bodies.

**Privacy model уточнён в §6 контракта.** Bodies теперь allowed on-device (SQLCipher decrypted only by Agent / MCPServer / MenuBarApp), forbidden в любом data egress beyond same-device AI client. Track 1 не пишет в relay вообще; Track 2 будет писать только filtered structured payloads без bodies. Whitepaper sync — **отложен** до full Track 1 ship (§12 контракта); D1 не трогает leaf-docs.

**Текущее состояние codebase:**
- Phase 5.5.{A,B,C} stack landed (alpha.11 baseline). 1007 SPM tests, 21 SQLCipher tables (M001–M010 + presence_state M005). M010 `pending_invites` — последняя миграция; M011 next.
- `events.payload_json` — TEXT (JSON) column, schema-free → новые payload keys без миграции (`M001_Events.swift:14`).
- `RawEvent.payload: [String: String]` flat dict (`Signals/RawEvent.swift:6-23`) — NOT typed enum. Bodies хранятся как string values в payload dict.
- ShareEventTypeRegistry — 43 keys, без default-on/off изменений в D1.
- Existing atomic write pattern: `Database.writeEventsOffsetAndPresence` (`Database.swift:251-278`) — D1 reuses без изменений.
- Existing collectors используют `[String: String]` payload + json_extract в downstream SQL queries. ProdInsights `aiRatio` (`ProdInsights.swift:451-559`) — не зависит от Layer B payload shape; D1 не меняет Claude Code payload (downstream safe).

**Источники правды (priority при противоречии):**
1. `2026-05-08-track-1-detection-substrate-contract.md` §6, §7, §10 (D1-bound OQs).
2. Существующие patterns: `LinearGraphQLProvider.swift` (GraphQL fragment + snapshot pair), `GitHubAPIProvider.swift` (REST snapshot + per-event mapping), `SlackAPIProvider.swift` (per-channel batch + tier-aware rate limiting), `M010_PendingInvites.swift` (migration extension pattern).
3. ADR-010 §6 amendment: bodies on-device → yes, в relay → never.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| **`M011_EventKindIndex` migration** | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M011_EventKindIndex.swift` (new) | `extension DatabaseMigrator { mutating func registerMigration011EventKindIndex() }`. SQL: `CREATE INDEX IF NOT EXISTS idx_events_event_kind_ts ON events (json_extract(payload_json, '$.event_kind'), ts)`. Composite expression index, idempotent. Под D3 query path "events of kind X in period [a,b]". |
| **Migration registration** | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (edit) | Insert `migrator.registerMigration011EventKindIndex()` после M010 line ~48. |
| **`Schema.EventPayloadKeys`** | `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` (edit, new namespace) | Static String constants для new payload keys: `body`, `attachmentsJson`, `bodyTruncated`, `commentBodiesJson`, `threadRepliesJson`, `messagesJson`, `filesCount`, `additions`, `deletions`, `requestedReviewersJson`, `mentionCount`, `linkCount`. Single source of truth для collectors + D2/D3 query path. |
| **`AttachmentMeta` value type** | `Packages/LeafCore/Sources/LeafCore/Signals/AttachmentMeta.swift` (new) | `public struct AttachmentMeta: Codable, Sendable, Hashable { public let name: String; public let mime: String?; public let sizeBytes: Int? }`. Shared между Linear / GitHub / Slack snapshots. Codable для JSON-encode в `attachments_json` payload key. |
| **`BodyCap` truncation utility** | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Capture/BodyCap.swift` (new, **moat**) | `public enum BodyCap { public static func apply(_ body: String) -> (String, Bool) }`. Returns `(possiblyTruncatedBody, wasTruncated)`. Cap value (64KB) — moat constant. Sentinel `\n…[truncated:N]` где N = original byte count. |
| **`SlackBudgets` constants** | `Packages/LeafCorePrivate/Prod/Slack/SlackBudgets.swift` (new, **moat**) | `public enum SlackBudgets { public static let maxThreadsPerTick: Int; public static let maxRepliesPerThread: Int; public static let tier3RpsBudget: Int }`. Concrete values — moat. |
| **`PRBodyParser`** | `Packages/LeafCorePrivate/Prod/GitHub/PRBodyParser.swift` (new, **moat**) | `public enum PRBodyParser { public static func mentionCount(_ body: String) -> Int; public static func linkCount(_ body: String) -> Int; public static func inlineImageURLs(_ body: String) -> [String] }`. NSRegularExpression для `@user`, URL, `![alt](url)` markdown. Patterns — moat. |
| **`LinearIssueSnapshot` extension** | `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearGraphQLProvider.swift` (edit ~line 208-263) | Add `description: String?`, `comments: [LinearCommentBody]`, `attachments: [AttachmentMeta]`. Backward-compat init defaults (nil / empty array). Existing `commentCountInWindow` retained; computed from `comments.count` если comments non-empty, иначе fallback на existing count path. |
| **`LinearCommentBody`** | (внутри `LinearGraphQLProvider.swift`) | `public struct LinearCommentBody: Codable, Sendable, Hashable { commentID: String; createdAtMs: Int64; body: String }`. Replaces count-only path в IssueHistoryFragment selection. |
| **GraphQL fragment edits** | `LinearGraphQLProvider.swift` (edit) | Add `description` to issue selection (~line 220). Add `body` to nested-comments fragment (~line 432). Add `attachments(first: 10) { nodes { title, contentType, metadata } }` to issue selection (~line 240). |
| **`LinearCollector` payload mapping** | `Packages/LeafCore/Sources/LeafCore/Collectors/LinearCollector.swift` (edit) | После snapshot ingestion: payload merge `body` ← `BodyCap.apply(description ?? "").0`, `body_truncated` if applicable, `comment_bodies_json` ← `JSONEncoder().encode(comments)`, `attachments_json` ← `JSONEncoder().encode(attachments)`. Empty arrays → key omitted (existing convention). |
| **`GitHubEventSnapshot` extension** | `Packages/LeafCore/Sources/LeafCore/Integrations/GitHub/GitHubAPIProvider.swift` (edit ~line 103-140) | Add `body: String?`, `prMetadata: PRMetadata?`, `attachments: [AttachmentMeta]`. Backward-compat init defaults. |
| **`PRMetadata`** | (внутри `GitHubAPIProvider.swift`) | `public struct PRMetadata: Codable, Sendable, Hashable { filesCount: Int; additions: Int; deletions: Int; requestedReviewers: [String]; mentionCount: Int; linkCount: Int }`. Populated только для PR-flavored event_kinds. |
| **GitHub parser edits** | `GitHubAPIProvider.swift` (edit, parsing functions) | Read `payload.pull_request.{body, additions, deletions, changed_files, requested_reviewers[]}` для PR events. Read `payload.comment.body` для `issue_comment_authored` / `pr_review_comment_authored`. Compute `mentionCount` / `linkCount` через `PRBodyParser`. Compute `attachments` через `PRBodyParser.inlineImageURLs(body)` + (для `release_published` events) `payload.release.assets[]` mapping. |
| **`GitHubCollector` full commit message** | `Packages/LeafCore/Sources/LeafCore/Collectors/GitHubCollector.swift:104-105` (edit) | Stop discarding past `\n` — store full commit message (subject + body). |
| **`GitHubCollector` payload mapping** | `GitHubCollector.swift:498-535` (edit) | Extend reserved-keys guard с new keys. Payload merge: `body`, `body_truncated`, `attachments_json`, `files_count`, `additions`, `deletions`, `requested_reviewers_json`, `mention_count`, `link_count`. Apply `BodyCap` к `body` field. |
| **`SlackChannelMessageBatch`** | `Packages/LeafCore/Sources/LeafCore/Integrations/Slack/SlackAPIProvider.swift` (edit, replace existing model) | Replace `SlackChannelMessageCount` count-only model → `SlackChannelMessageBatch { messages: [SlackMessageRecord] }`. `SlackMessageRecord { ts: String; text: String; threadTs: String?; files: [SlackFileMeta] }`. Existing client-side filter `user == userID` сохраняется. |
| **`SlackFileMeta`** | (внутри `SlackAPIProvider.swift`) | `public struct SlackFileMeta: Codable, Sendable, Hashable { name: String; mimetype: String?; size: Int? }`. Replaces mime-bucket-only model. |
| **`fetchThreadReplies`** | `SlackAPIProvider.swift` (edit, new method) | `func fetchThreadReplies(accessToken: String, channelID: String, threadTs: String, ownerUserID: String, oldest: String?) async throws -> SlackThreadReplyBatch`. Calls `conversations.replies` (Tier 3, ~50/min). Returns parent + replies (filtered to own + threads where own already participated). Cursor-based via `oldest` param (Slack ts format). |
| **`SlackThreadReplyBatch`** | (внутри `SlackAPIProvider.swift`) | `public struct SlackThreadReplyBatch: Sendable { parent: SlackMessageRecord; replies: [SlackMessageRecord]; latestTs: String }`. |
| **`SlackCollector` thread fan-out** | `Packages/LeafCore/Sources/LeafCore/Collectors/SlackCollector.swift:503-531` (edit) | Stop dropping message.text at line 72-73 — embed per-message records into `messages_json` payload key on `slack_message_authored_aggregate`. After main message batch: dedupe `(channelID, threadTs)` from active threads, apply `SlackBudgets.maxThreadsPerTick` upper bound, call `fetchThreadReplies` per thread. Extend `slack_thread_reply_aggregate` payload: top-level `body` (parent message text) + `thread_replies_json` ← JSONEncoder().encode(replies). Per-thread cursor stored в `collector_offsets` (sourceID `slack:thread:<channelID>:<threadTs>`, type `String` per existing offset shape). |
| **Slack 429 graceful degrade** | `SlackCollector.swift` (edit) | On `Retry-After` header: log warning, sleep, continue with remaining budget. Threads not processed re-surface next tick. Per-thread cursor not advanced if fetch failed. |
| **Claude Code audit** | `Packages/LeafCore/Sources/LeafCore/Collectors/ClaudeCodeCollector.swift` + `Packages/LeafCorePrivate/Prod/Collectors/ClaudeCodeJSONLParser.swift` | **Verify-only:** confirm 4 hooks emit consistent payload keys, jsonl fallback parser aligns с current Claude Code session-file schema, ADR-010 sentinel tests green. Output — markdown audit note in PR description. **No code changes expected** unless gap surfaces. |
| **Tests — `M011EventKindIndexTests`** | `Packages/LeafCore/Tests/LeafCoreTests/Migrations/M011EventKindIndexTests.swift` (new) | 3 tests (§5.1). |
| **Tests — `EventPayloadKeysTests`** | `Packages/LeafCore/Tests/LeafCoreTests/EventPayloadKeysTests.swift` (new) | 1 stability test (§5.2). |
| **Tests — `BodyCapTests`** | `Packages/LeafCore/Tests/LeafCorePrivateTests/BodyCapTests.swift` (new, moat) | 5 tests (§5.3). |
| **Tests — `LinearGraphQLProviderTests` extension** | existing file (edit) | 4 new tests for description / comment.body / attachments fixture (§5.4). |
| **Tests — `LinearCollectorTests` extension** | existing file (edit) | 3 new tests for payload key population, attachments_json shape, BodyCap application (§5.5). |
| **Tests — `GitHubAPIProviderTests` extension** | existing file (edit) | 5 new tests for PR body, issue_comment, pr_review_comment, release.assets, prMetadata (§5.6). |
| **Tests — `GitHubCollectorTests` extension** | existing file (edit) | 4 new tests for payload key population, full commit message (no first-line truncation), attachments parsed from body, prMetadata mapping (§5.7). |
| **Tests — `SlackAPIProviderTests` extension** | existing file (edit) | 4 new tests for message text capture, conversations.replies fixture, file metadata, 429 retry (§5.8). |
| **Tests — `SlackCollectorTests` extension** | existing file (edit) | 4 new tests for body payload, thread fan-out budget, per-thread cursor, graceful degrade (§5.9). |
| **Tests — `ClaudeCodeCollectorCrossHookTests`** | `Packages/LeafCore/Tests/LeafCoreTests/ClaudeCodeCollectorCrossHookTests.swift` (new) | 1 cross-hook payload schema parity test (§5.10). |
| **Tests — `RelayBodyLeakageTests`** | `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` (new) | 3 tests assert bodies НЕ попадают в `presence_state` JSON (§5.11). Privacy regression — explicit acceptance gate per §6 контракта. |

### НЕ входит (явно отложено)

- **FTS5 virtual table `events_fts`** — D2.
- **`event_links` table + CrossSourceLinkGraph** — D2.
- **`decisions` / `open_questions` / `blockers` tables** — D3.
- **3 new high-level structured MCP tools** (`leaf_query_activity` / `leaf_get_decision` / `leaf_current_work`) — D3.
- **DecisionDetector / OpenQuestionDetector / BlockerDetector / WhereStoppedDeriver / AbsenceFlag** — D3.
- **ShareEventTypeRegistry expansion** (`decision_detected`, `open_question_opened`, etc.) — D3 регистрирует.
- **Whitepaper sync** (`leaf-docs/docs/memory-architecture/capture.md` + `privacy-security/what-we-dont-capture.md`) — отложен до Track 1 ship per §12 контракта.
- **Cursor / Windsurf / Continue.dev / Copilot / ChatGPT Desktop hooks** — out of scope Track 1 (§11 контракта).
- **AST symbols / SourceKit / tree-sitter** — out of scope Track 1 (§11).
- **Calendar deepening** (`meeting_title`, `attendees[]`) — out of scope Track 1 (§11).
- **Backfill старых events bodies** — write-forward only. Future optional admin command, не часть D1.
- **LLM Summarizer / embeddings / vector search** — out of scope Track 1 (§11).

---

## 3. Public API design

### 3.1 `M011_EventKindIndex.swift`

Mirror `M010_PendingInvites.swift` pattern:

```swift
import Foundation
import GRDB

public extension DatabaseMigrator {
    mutating func registerMigration011EventKindIndex() {
        registerMigration("011_event_kind_index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_events_event_kind_ts
                ON events (json_extract(payload_json, '$.event_kind'), ts)
            """)
        }
    }
}
```

Composite expression index supports D3 queries shape `WHERE json_extract(payload_json, '$.event_kind') = ? AND ts BETWEEN ? AND ?`. Index name pinned (`idx_events_event_kind_ts`) — referenced в Schema.swift constants. Idempotency via `IF NOT EXISTS`.

Registration in `Database.swift` migrator list:
```swift
migrator.registerMigration010PendingInvites()
migrator.registerMigration011EventKindIndex()  // NEW
```

### 3.2 `Schema.EventPayloadKeys`

Extend `Schema.swift` with new namespace:

```swift
public enum EventPayloadKeys {
    public static let body = "body"
    public static let bodyTruncated = "body_truncated"
    public static let attachmentsJson = "attachments_json"
    public static let commentBodiesJson = "comment_bodies_json"
    public static let threadRepliesJson = "thread_replies_json"
    public static let messagesJson = "messages_json"
    // GitHub PR metadata (Phase 4.8 carry-over)
    public static let filesCount = "files_count"
    public static let additions = "additions"
    public static let deletions = "deletions"
    public static let requestedReviewersJson = "requested_reviewers_json"
    public static let mentionCount = "mention_count"
    public static let linkCount = "link_count"
}
```

Existing payload key strings (`event_kind`, `actor_id`, etc.) уже разбросаны inline по collectors — D1 не консолидирует backward, только новые keys host'ятся. D2/D3 добавляют свои keys в эту же namespace.

### 3.3 `AttachmentMeta`

```swift
public struct AttachmentMeta: Codable, Sendable, Hashable {
    public let name: String
    public let mime: String?
    public let sizeBytes: Int?

    public init(name: String, mime: String? = nil, sizeBytes: Int? = nil) {
        self.name = name
        self.mime = mime
        self.sizeBytes = sizeBytes
    }
}
```

JSON shape per element: `{"name": "design.fig", "mime": "application/octet-stream", "size_bytes": 482133}`. Optional fields omitted via `JSONEncoder.OutputFormatting` (default — keep `null` для consistency with downstream FTS5 в D2). CodingKeys map `sizeBytes` → `"size_bytes"`.

### 3.4 `BodyCap` (moat)

```swift
// LeafCorePrivate/Prod/Capture/BodyCap.swift
public enum BodyCap {
    public static func apply(_ body: String) -> (body: String, truncated: Bool)
}
```

Implementation strategy (no concrete number в spec):
- Cap byte count `maxBytes` — `static let maxBytes: Int` (moat).
- Truncation: UTF-8 byte-aware (избежать split graphemes / multi-byte codepoint corruption — Foundation `String.utf8.prefix(_:)` + boundary correction).
- Sentinel: `"\n…[truncated:\(originalByteCount)]"` appended после truncated body.
- Returns `(truncatedString, true)` if cap exceeded; else `(input, false)`.

### 3.5 `SlackBudgets` (moat)

```swift
// LeafCorePrivate/Prod/Slack/SlackBudgets.swift
public enum SlackBudgets {
    public static let maxThreadsPerTick: Int
    public static let maxRepliesPerThread: Int
    public static let tier3RpsBudget: Int
    public static let perThreadHistoryWindowSeconds: Int
}
```

Concrete values — moat. Not in spec, not in whitepaper, not in shared/architecture.md. Tested via assertion that values are `>0` and that LeafCore code paths gate on these (test 5.9.2).

### 3.6 `PRBodyParser` (moat)

```swift
// LeafCorePrivate/Prod/GitHub/PRBodyParser.swift
public enum PRBodyParser {
    public static func mentionCount(_ body: String) -> Int
    public static func linkCount(_ body: String) -> Int
    public static func inlineImageURLs(_ body: String) -> [String]
}
```

Implementation regex'ы — moat. Tests pin counts on fixed-vector inputs (test 5.6.5).

### 3.7 Linear extensions

`LinearIssueSnapshot` (extending existing struct in `LinearGraphQLProvider.swift:208-263`):

```swift
public struct LinearIssueSnapshot: Sendable, Equatable {
    // ... existing fields (issueKey, title, status, project, ...)
    public let description: String?       // NEW
    public let comments: [LinearCommentBody]  // NEW
    public let attachments: [AttachmentMeta]  // NEW

    public init(/*existing args*/,
                description: String? = nil,
                comments: [LinearCommentBody] = [],
                attachments: [AttachmentMeta] = []) { ... }
}

public struct LinearCommentBody: Codable, Sendable, Hashable {
    public let commentID: String
    public let createdAtMs: Int64
    public let body: String
}
```

GraphQL fragment additions (`LinearGraphQLProvider.swift` ~line 220, ~line 240, ~line 432):
```graphql
issues(...) {
  nodes {
    id
    identifier
    title
    description       # NEW
    state { name type }
    project { id name }
    team { key }
    updatedAt
    completedAt
    attachments(first: 10) {  # NEW
      nodes {
        title
        contentType
        metadata
      }
    }
    history(first: 10, ...) {
      nodes {
        # ... existing fields
        comments {       # NEW (extend existing edge)
          nodes {
            id
            createdAt
            user { id }
            body         # NEW
          }
        }
      }
    }
  }
}
```

### 3.8 GitHub extensions

`GitHubEventSnapshot` (extending struct в `GitHubAPIProvider.swift:103-140`):

```swift
public struct GitHubEventSnapshot: Sendable, Equatable {
    // ... existing fields (eventID, eventKind, repoFullName, title, ...)
    public let body: String?                  // NEW
    public let prMetadata: PRMetadata?        // NEW (only for PR-flavored event_kinds)
    public let attachments: [AttachmentMeta]  // NEW

    public init(/*existing args*/,
                body: String? = nil,
                prMetadata: PRMetadata? = nil,
                attachments: [AttachmentMeta] = []) { ... }
}

public struct PRMetadata: Codable, Sendable, Hashable {
    public let filesCount: Int
    public let additions: Int
    public let deletions: Int
    public let requestedReviewers: [String]
    public let mentionCount: Int
    public let linkCount: Int
}
```

`/users/<login>/events` REST returns `payload.pull_request.{body, additions, deletions, changed_files, requested_reviewers[]}` directly — no extra fetch. Parse in existing event mapping function.

`release_published` events (Phase 4.7.A `event_kind`): map `payload.release.assets[]` → `[AttachmentMeta]` (each asset → `name` from `asset.name`, `mime` from `asset.content_type`, `sizeBytes` from `asset.size`).

For inline images в PR/comment bodies: `PRBodyParser.inlineImageURLs(body)` → `[String]` URLs → `AttachmentMeta(name: <derived from URL last path segment>, mime: <inferred from extension>, sizeBytes: nil)`.

### 3.9 Slack extensions

`SlackChannelMessageBatch` (replaces existing `SlackChannelMessageCount`):

```swift
public struct SlackChannelMessageBatch: Sendable, Equatable {
    public let channelID: String
    public let messages: [SlackMessageRecord]
    public let periodStartMs: Int64
    public let periodEndMs: Int64
    public let reactionsCount: Int
}

public struct SlackMessageRecord: Codable, Sendable, Hashable {
    public let ts: String       // Slack timestamp (e.g. "1234567890.123456")
    public let text: String
    public let threadTs: String?
    public let files: [SlackFileMeta]
}

public struct SlackFileMeta: Codable, Sendable, Hashable {
    public let name: String
    public let mimetype: String?
    public let size: Int?
}

public struct SlackThreadReplyBatch: Sendable, Equatable {
    public let parent: SlackMessageRecord
    public let replies: [SlackMessageRecord]
    public let latestTs: String  // for cursor advance
}
```

`fetchThreadReplies` signature:

```swift
func fetchThreadReplies(
    accessToken: String,
    channelID: String,
    threadTs: String,
    ownerUserID: String,
    oldest: String?
) async throws -> SlackThreadReplyBatch
```

Filters: replies where `user == ownerUserID` OR thread parent `user == ownerUserID`. Other-author replies in threads where own user participated — **included** (per UC4 — need full reasoning context). Per §6 контракта, on-device storage allowed; bodies never go to relay.

### 3.10 Per-thread cursor pattern

`collector_offsets` table existing pattern: `(collector_id, source_id) → offset (Int64 / String / etc.)`. New cursor entries:

- `collector_id = "slack_thread"` (или existing slack collector reuses with namespaced source)
- `source_id = "slack:thread:<channelID>:<threadTs>"`
- `offset` = latest reply Slack ts as String (e.g. "1234567890.123456")

Cursor advances only on successful fetch. On 429 / network failure, cursor stays — thread re-surfaces next tick.

### 3.11 Linear collector payload mapping

`LinearCollector.swift` (existing collector, extend snapshot → payload mapping):

```swift
let (cappedBody, bodyTruncated) = BodyCap.apply(snapshot.description ?? "")
var payload: [String: String] = [
    Schema.EventPayloadKeys.eventKind: "linear_issue_updated",
    // ... existing keys (issue_key, title, status, ...)
]

if !cappedBody.isEmpty {
    payload[Schema.EventPayloadKeys.body] = cappedBody
    if bodyTruncated { payload[Schema.EventPayloadKeys.bodyTruncated] = "true" }
}

if !snapshot.comments.isEmpty {
    let cappedComments = snapshot.comments.map { c in
        let (capped, _) = BodyCap.apply(c.body)
        return LinearCommentBody(commentID: c.commentID, createdAtMs: c.createdAtMs, body: capped)
    }
    payload[Schema.EventPayloadKeys.commentBodiesJson] = try jsonEncode(cappedComments)
}

if !snapshot.attachments.isEmpty {
    payload[Schema.EventPayloadKeys.attachmentsJson] = try jsonEncode(snapshot.attachments)
}
```

`jsonEncode` — local helper using `JSONEncoder` with sorted keys (для deterministic test fixtures).

### 3.12 GitHub collector payload mapping

`GitHubCollector.swift:498-535 makeEvent` — extend payload merging with same pattern. Reserved-keys guard (existing): expand с new keys to prevent metadata-slot shadow.

`GitHubCollector.swift:104-105` — remove first-line truncation:
```swift
// BEFORE: let subject = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
// AFTER:  let fullMessage = message
let (cappedFullMessage, truncated) = BodyCap.apply(fullMessage)
// ... merge into payload[.body]
```

### 3.13 Slack collector payload mapping + thread fan-out

`SlackCollector.swift:503-531 makeMessageEvent`:

```swift
// Stop dropping at line 72-73: capture text into per-message records.
// Aggregate event still emits count + period as before; per-message bodies
// embedded as JSON array (NOT top-level `body` key — aggregate carries N messages).
```

Decision (locked): **extend `slack_message_authored_aggregate`** — payload now carries `messages_json` (JSON array of `SlackMessageRecord` with each record's `text` inside). **No top-level `body` key** for this event_kind (multiple messages → no single body). Backward-compat: existing consumers reading `count` / `period_start_ms` / `period_end_ms` / `reactions_count` unaffected.

For **`slack_thread_reply_aggregate`** (different event_kind): payload carries top-level `body` (parent message text — deterministic, one parent per thread) + `thread_replies_json` (array of `SlackMessageRecord`).

Mapping summary per Slack event_kind:

| event_kind | Top-level `body` key | JSON array key |
|---|---|---|
| `slack_message_authored_aggregate` | — (no single body) | `messages_json` (array of `SlackMessageRecord`) |
| `slack_thread_reply_aggregate` | parent message text | `thread_replies_json` (array of replies) |
| `slack_file_uploaded_aggregate` | — | `attachments_json` (existing payload key, now richer per `SlackFileMeta`) |

Thread fan-out (after main batch processing):

```swift
let threadKeys = batch.messages.compactMap { msg in
    msg.threadTs.map { (channelID: batch.channelID, threadTs: $0) }
}.unique()

let bounded = threadKeys.prefix(SlackBudgets.maxThreadsPerTick)

for key in bounded {
    let cursor = try? db.read { db in
        try CollectorOffset.read(collectorID: "slack_thread",
                                  sourceID: "slack:thread:\(key.channelID):\(key.threadTs)", in: db)
    }
    do {
        let replies = try await provider.fetchThreadReplies(
            accessToken: token, channelID: key.channelID, threadTs: key.threadTs,
            ownerUserID: ownerID, oldest: cursor?.offset)
        // Build slack_thread_reply_aggregate event with body + thread_replies_json
        // Atomically write event + advance cursor via writeEventsOffsetAndPresence
    } catch RateLimitError.retryAfter(let secs) {
        try await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
        // Continue — cursor not advanced, thread re-surfaces next tick
        break  // exit loop, remaining threads next tick
    }
}
```

---

## 4. Wire format details (locked)

### 4.1 `body` payload key

- Type: UTF-8 plaintext String (Swift `String` value in `[String: String]` payload dict).
- **Used only for events с deterministic single body:** `linear_issue_updated` (issue.description), GitHub PR/issue_comment/pr_review_comment events (single comment body), `slack_thread_reply_aggregate` (parent message text), `commit_pushed` (full commit message — subject + body, no first-line truncation).
- **NOT used** для `slack_message_authored_aggregate` (multiple messages → no single body; bodies live в `messages_json`).
- Encoding into `events.payload_json`: handled by existing `JSONEncoder` on `RawEvent` write (`Database.swift:1320-1354 make(from:)` — payload encoded as JSON object via `JSONEncoder()`).
- Empty bodies → key omitted (consistent with existing convention `GitHubCollector.swift:510-515`).
- Hard cap applied at collector boundary via `BodyCap.apply`. Truncated bodies have sentinel `\n…[truncated:N]` appended (N = original byte count).
- `body_truncated` payload key — String `"true"` if cap fired; key omitted otherwise.

### 4.2 `attachments_json` payload key

- Type: String (JSON array serialization of `[AttachmentMeta]`).
- Empty array → key omitted.
- Per-element shape: `{"name": "<filename>", "mime": "<mime/null>", "size_bytes": <int/null>}`. `JSONEncoder` with sorted keys для test determinism.

### 4.3 `comment_bodies_json` payload key (Linear)

- String (JSON array of `[LinearCommentBody]`).
- Per-element: `{"commentID": "<linear-comment-uuid>", "createdAtMs": <int>, "body": "<utf8-string>"}`.

### 4.4 `thread_replies_json` payload key (Slack)

- String (JSON array of `[SlackMessageRecord]`).
- Per-element: `{"ts": "<slack-ts>", "text": "<utf8>", "threadTs": "<slack-ts/null>", "files": [<SlackFileMeta>...]}`.

### 4.4.1 `messages_json` payload key (Slack `slack_message_authored_aggregate`)

- String (JSON array of `[SlackMessageRecord]`) — per-message records in this tick window для данного channel.
- Each `text` field cap'ируется через `BodyCap.apply` independently. If any message truncated — `body_truncated` payload key emitted with value `"true"` (aggregate-level — at least one message hit cap).

### 4.5 GitHub PR metadata payload keys

- `files_count`, `additions`, `deletions`, `mention_count`, `link_count`: String (decimal Int representation, parseable via `Int(_:)`).
- `requested_reviewers_json`: String (JSON array of GitHub login strings: `["alice", "bob"]`).

### 4.6 Per-thread cursor format

- `collector_offsets.collector_id` = `"slack_thread"` (new namespace)
- `source_id` = `"slack:thread:<channelID>:<threadTs>"` (e.g. `"slack:thread:C0123:1234567890.123456"`)
- `offset_value` = latest reply Slack ts as String

### 4.7 M011 expression index

```sql
CREATE INDEX IF NOT EXISTS idx_events_event_kind_ts
ON events (json_extract(payload_json, '$.event_kind'), ts);
```

Composite (event_kind, ts). SQLite supports expression indexes since 3.9 (we use bundled SQLCipher 4.x). Query optimizer matches `WHERE json_extract(payload_json, '$.event_kind') = ? AND ts BETWEEN ? AND ?`. D3 query path will use this.

---

## 5. Test plan

### 5.1 `M011EventKindIndexTests` (3 tests)

1. `testM011_CreatesIndex` — open DB через `Database.openForWrite(at:..., config: .weakDefaults, encryption: .deterministicTest)`, query `sqlite_master WHERE type='index' AND name='idx_events_event_kind_ts'` → assert exists, sql column matches expected DDL.
2. `testM011_IsIdempotentOnReopen` — open, close, reopen — миграции re-run без crash.
3. `testM011_FullSequenceRunsCleanly` — open fresh DB → assert все M001–M011 миграции applied (`grdb_migrations` lists `011_event_kind_index`).

### 5.2 `EventPayloadKeysTests` (1 test)

1. `testKeyStability` — assert `Schema.EventPayloadKeys.body == "body"`, `bodyTruncated == "body_truncated"`, etc. Pin all 12 string values. Catches accidental rename.

### 5.3 `BodyCapTests` (5 tests, in LeafCorePrivate test target)

1. `testApply_PassesThroughShortBody` — input "hello world" → returns `("hello world", false)`.
2. `testApply_TruncatesLongBody` — input of `maxBytes + 100` ASCII chars → returns truncated string ending in `\n…[truncated:N]`, `truncated == true`.
3. `testApply_HandlesUTF8Boundaries` — input включающий multi-byte codepoints (emoji + кириллица) которые попадают на cap boundary → returned string не содержит partial codepoint (no malformed UTF-8).
4. `testApply_EmptyInput` — input "" → returns `("", false)`.
5. `testApply_ExactlyAtBoundary` — input ровно `maxBytes` UTF-8 bytes → returns `(input, false)` (cap fires только при strict exceed).

### 5.4 `LinearGraphQLProviderTests` extension (4 tests)

1. `testParse_PopulatesIssueDescription` — recorded GraphQL response с `description: "Refactor OAuth refresh"` → snapshot.description == "Refactor OAuth refresh".
2. `testParse_PopulatesCommentBodies` — fixture с history.nodes[].comments → snapshot.comments contains parsed bodies.
3. `testParse_PopulatesAttachments` — fixture с attachments.nodes → snapshot.attachments contains AttachmentMeta with title/mime/size.
4. `testParse_HandlesNullDescription` — fixture с `description: null` → snapshot.description == nil. No crash.

### 5.5 `LinearCollectorTests` extension (3 tests)

1. `testTick_PopulatesBodyPayloadKey` — fixture provider returns snapshot с description → after performTick(), event row payload contains `body` key with description value.
2. `testTick_AttachmentsJSONShape` — snapshot с 2 attachments → payload[`attachments_json`] decodes to array of 2 AttachmentMeta.
3. `testTick_AppliesBodyCap` — snapshot с very long description (> cap) → event payload contains truncated `body` + `body_truncated == "true"`.

### 5.6 `GitHubAPIProviderTests` extension (5 tests)

1. `testParse_PullRequestEvent_PopulatesBody` — fixture `/events` response с PR pull_request.body → snapshot.body matches.
2. `testParse_PullRequestEvent_PopulatesPRMetadata` — fixture с pull_request.{additions: 50, deletions: 10, changed_files: 3, requested_reviewers: [{login: "alice"}]} → snapshot.prMetadata == PRMetadata(filesCount: 3, additions: 50, deletions: 10, requestedReviewers: ["alice"], mentionCount: ..., linkCount: ...).
3. `testParse_IssueCommentAuthored_PopulatesBody` — fixture с payload.comment.body → snapshot.body matches.
4. `testParse_PullRequestReviewComment_PopulatesBody` — fixture с pr_review_comment payload → snapshot.body matches.
5. `testParse_ReleasePublished_PopulatesAssets` — fixture release event с release.assets[] → snapshot.attachments contains entries для each asset с name/mime/size.

### 5.7 `GitHubCollectorTests` extension (4 tests)

1. `testTick_FullCommitMessage_NotTruncatedToFirstLine` — provider returns commit с message "Subject\n\nBody paragraph" → event payload[`body`] == full string (including \n + body).
2. `testTick_PRMetadataPayloadKeys` — provider returns PR snapshot → event payload contains `files_count`, `additions`, `deletions`, `requested_reviewers_json`, `mention_count`, `link_count`.
3. `testTick_InlineImagesParsedFromBody` — PR body containing `![alt](https://user-images.githubusercontent.com/123/image.png)` → event payload[`attachments_json`] contains entry with name=`image.png`, mime starting `image/`.
4. `testTick_ReservedKeysGuard` — manually-set metadata containing `body`/`additions` keys does NOT shadow new D1 fields (collector overrides metadata for reserved keys).

### 5.8 `SlackAPIProviderTests` extension (4 tests)

1. `testFetchHistory_CapturesMessageText` — fixture `conversations.history` → SlackMessageRecord.text matches.
2. `testFetchThreadReplies_ParsesParentAndReplies` — fixture `conversations.replies` → SlackThreadReplyBatch contains parent + N replies.
3. `testFetchFilesUploaded_CapturesNameAndSize` — fixture с files[].{name, mimetype, size} → SlackFileMeta populated correctly (replaces mime-bucket-only model).
4. `testFetchThreadReplies_429RetryAfter` — mock 429 response с `Retry-After: 2` → throws `RateLimitError.retryAfter(2)`. (Sleep handling tested at collector layer.)

### 5.9 `SlackCollectorTests` extension (4 tests)

1. `testTick_MessagesJSON_ForAggregate` — provider returns batch с 2 messages → `slack_message_authored_aggregate` event payload contains `messages_json` (parsed array of 2 `SlackMessageRecord` with `text` populated). NO top-level `body` key (locked per §3.13).
2. `testTick_ThreadFanOut_BoundedByBudget` — fixture с N > maxThreadsPerTick threads → only `maxThreadsPerTick` threads fetched (assertable via fetchThreadReplies call count).
3. `testTick_PerThreadCursorAdvances` — first tick fetches replies, cursor saved; second tick uses oldest = saved cursor (assertable via mock).
4. `testTick_429GracefulDegrade` — provider throws `RateLimitError` on thread N — collector logs, sleeps, breaks loop. Cursor NOT advanced for failed thread. Other threads' cursors preserved if processed before failure.

### 5.10 `ClaudeCodeCollectorCrossHookTests` (1 test)

1. `testCrossHookPayloadSchemaParity` — synthetic jsonl input covering all 4 hook types (PostToolUse / SessionStart / SessionEnd / UserPromptSubmit) → assert each emitted event has consistent set of payload keys (`session_id`, `cwd`, `git_branch`, `event_kind`); tool_use events additionally have `tool_name`. ADR-010 sentinel: assert no `text` / `thinking` / `input` / `content` keys present.

### 5.11 `RelayBodyLeakageTests` (3 tests)

1. `testEventBodyDoesNotLeakIntoPresenceState_Linear` — write Linear RawEvent с `body` payload key → run через existing `writeEventsOffsetAndPresence` with presence non-nil → read `presence_state.state_json` → assert body string NOT contained.
2. `testEventBodyDoesNotLeakIntoPresenceState_GitHub` — same for GitHub PR body.
3. `testEventBodyDoesNotLeakIntoPresenceState_Slack` — same for Slack message text + thread replies.

**Total new tests:** 33. Baseline 1007 → 1040 после D1 (acceptable range).

---

## 6. Test target conventions

- **Framework:** XCTest (mirror existing). No Swift Testing macros.
- **DB tests:** mirror Phase 5.5.A pattern — temp dir в `setUp` через `FileManager.default.temporaryDirectory.appendingPathComponent("leaf-D1-\(UUID().uuidString)", isDirectory: true)`; `tearDown` cleans. `Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)`.
- **Provider tests:** pure XCTestCase, fixture JSON в `Tests/.../Fixtures/<provider>/<scenario>.json` (mirror existing fixture pattern в repo).
- **Collector tests:** `MockLinearProvider` / `MockGitHubProvider` / `MockSlackProvider` (existing types в test target) — extend with new fixture-returning closures.
- **LeafCorePrivate tests:** `BodyCapTests` lives in `Packages/LeafCore/Tests/LeafCorePrivateTests/`. Existing test target wired in `Package.swift`.

---

## 7. Acceptance criteria

D1 считается closed когда:

1. `swift test --package-path Packages/LeafCore` — green, count = 1040 (или ±5 как baseline drift).
2. `xcodebuild -scheme LeafCore -configuration Debug build` — SUCCESS.
3. `xcodebuild -scheme LeafCorePrivate -configuration Debug build` — SUCCESS.
4. `xcodebuild -scheme Leaf -configuration Debug build` — SUCCESS.
5. `xcodebuild -scheme LeafAgent -configuration Debug build` — SUCCESS.
6. `xcodebuild -scheme LeafMCP -configuration Debug build` — SUCCESS.
7. **Bodies реально захватываются end-to-end** для всех 4 источников — fixture-provider integration test per surface проходит (тесты §5.5, 5.7, 5.9 + Claude Code regression остаётся green).
8. **M011 applied** — expression index visible via `sqlite_master`.
9. **Won't-list compliance** — `RelayBodyLeakageTests` green (§5.11). Privacy regression — explicit acceptance gate per §6 контракта.
10. Branch `feature/track-1-D1-capture-extension` пушнут на origin. **Не merged в main** — stack под D2/D3, merge коллективно после Track 1 ship.
11. Independent code review (Stage 6 workflow) — APPROVED или APPROVED-WITH-NITS (no blockers).
12. `current-state.md` обновлён в финальном commit (отдельный `docs(shared): Phase Track-1 D1 landed`).

**НЕ acceptance criteria для D1:**
- Whitepaper sync (`leaf-docs/docs/memory-architecture/capture.md` + `privacy-security/what-we-dont-capture.md`) — отложен до Track 1 ship per §12 контракта.
- UC1/UC3/UC4/UC5/UC6 working end-to-end — это **Track 1 acceptance gate** (§13 контракта), требует D2 + D3.
- New high-level MCP tools — D3.

---

## 8. Out of scope для D1 (carry-overs)

| Excluded | Reserved for |
|---|---|
| FTS5 virtual table `events_fts` + reindex strategy | D2 |
| `event_links` table + CrossSourceLinkGraph implementation | D2 |
| `decisions` / `open_questions` / `blockers` tables | D3 |
| 3 new high-level structured MCP tools | D3 |
| 5 detector types + reuse pattern | D3 |
| ShareEventTypeRegistry expansion (`decision_detected` etc.) | D3 |
| Whitepaper sync | Track 1 ship (post-D3) |
| Cursor / Windsurf / Continue.dev / Copilot / ChatGPT Desktop hooks | Future track (out of Track 1) |
| AST symbols / SourceKit / tree-sitter | Future track (out of Track 1) |
| Calendar deepening (`meeting_title`, `attendees[]`) | Future track (out of Track 1) |
| Backfill старых events bodies | Future optional admin command |
| LLM Summarizer / embeddings / vector search | Future track |
| `leaf_query_team` MCP tool + cross-device E2E summary distribution | Track 2 |
| Slack-bot surface (`/leaf` slash command) | Track 2 |
| Native UI redesign (decisions/open-questions/blockers panels) | Post-Track-1 |

---

## 9. Risks + mitigations

| Risk | Mitigation |
|---|---|
| **`payload_json` row size growth** — bodies могут раздуть DB | `BodyCap` 64KB hard cap (moat); WAL checkpoint discipline (15 min / 4MB) уже existing — без изменений. Manual smoke check `du -h ~/Library/Application Support/Leaf/events.sqlite` before/after week of usage. |
| **Slack `conversations.replies` rate-limit exhaustion** under "all active threads" scope | `SlackBudgets.maxThreadsPerTick` upper bound; per-thread cursor → unprocessed threads re-surface; 429 handler sleeps + breaks loop; не блокирует другие collector ticks. |
| **GitHub `/events` REST 5000/hr rate-limit** под расширенным parsing | D1 не добавляет extra REST fetches — `pull_request.body` + `additions/deletions/changed_files/requested_reviewers` уже в existing event payload. Net rate-limit footprint unchanged. |
| **`json_extract` expression index не используется query planner'ом** — possible SQLite 3.9 limitation | Test 5.1.1 verifies index existence; D3 query path tests will assert `EXPLAIN QUERY PLAN` использует `idx_events_event_kind_ts` (D3 spec deliverable). Если планировщик не подцепит — fallback на materialized column в M012 (defer to D3). |
| **UTF-8 boundary corruption в `BodyCap`** — split на multi-byte codepoint | Test 5.3.3 covers; implementation использует `String.utf8.prefix(_:)` + boundary correction (find last valid UTF-8 byte ≤ cap). |
| **Backward-compat для existing `slack_thread_reply_aggregate` consumers** | D1 extends (не replaces) payload — existing keys (`count`, `period_start_ms`, `period_end_ms`) preserved. New keys (`body`, `thread_replies_json`) — additive. ShareEventTypeRegistry stays 43 keys. |
| **Claude Code jsonl schema drift** — recent CC updates могут добавить fields | Audit checks current `~/.claude/projects/*.jsonl` snapshot vs parser. ADR-010 sentinel tests catch leakage of new body-bearing fields. If gap surfaces — small fix patch in same D1 commit. |
| **`AttachmentMeta` sharing breaks if any provider needs custom field** | D1 keeps shared type minimal (name / mime / sizeBytes). If future provider needs e.g. `download_url` — extend Codable как optional, не breaking. |
| **Inline image URL parser false positives** в PR/comment bodies | `PRBodyParser.inlineImageURLs` conservative regex (only `![alt](url)` markdown shape, scheme http/https). Test 5.7.3 fixed-vector pin. |
| **JSON encoding determinism** for fixture tests | `JSONEncoder` with `outputFormatting = .sortedKeys` для `attachments_json` / `comment_bodies_json` / etc. Tests pin on sorted-keys output. |
| **Schema constants conflict** if future migrations add `event_kind` column | M011 builds index on JSON expression, не на column. If future migration promotes `event_kind` to column, D1 index can be dropped/replaced cleanly (no FK / no data loss). |

---

## 10. Verification

```bash
cd ~/Desktop/Leaf/leaf/Packages/LeafCore && swift test
# Expect: 1040 tests pass (1007 baseline + 33 new D1 tests)

cd ~/Desktop/Leaf/leaf
xcodebuild -scheme LeafCore        -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafCorePrivate -configuration Debug build  # SUCCESS
xcodebuild -scheme Leaf            -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafAgent       -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafMCP         -configuration Debug build  # SUCCESS
```

**Manual smoke (post-merge of D1 to feature/track-1-detection-substrate):** запустить LeafAgent в debug на Mac разработчика с подключёнными OAuth (Linear / GitHub / Slack), дать tick'ам отработать ~30 мин, затем:

```bash
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" \
  "SELECT json_extract(payload_json, '$.event_kind'),
          substr(json_extract(payload_json, '$.body'), 1, 80),
          json_extract(payload_json, '$.body_truncated')
   FROM events
   WHERE ts > strftime('%s', 'now', '-1 hour') * 1000
     AND signal_type = 'action'
   ORDER BY ts DESC LIMIT 20;"
# Ожидаемо: bodies populated для linear_issue_updated / github_pr_* / slack_message_authored_aggregate / slack_thread_reply_aggregate.
```

**Privacy spot-check:**

```bash
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" \
  "SELECT provider, state_json FROM presence_state;"
# Manual visual inspect: state_json содержит ТОЛЬКО counts/transitions/timestamps,
# никакого raw body text, никаких commit messages, никаких Slack messages.
```

**Pre-push:** `/pre-push-leaf` (D1 публикует public-safe constants — payload key strings, M011 SQL DDL, AttachmentMeta value type. Implementation moat — `BodyCap` cap value, `SlackBudgets` numbers, `PRBodyParser` regex'ы — все в `LeafCorePrivate`).

---

## 11. Dependencies on prior phases

- **M005 `presence_state`** (Phase 4.7.A) — D1 RelayBodyLeakageTests uses existing `writeEventsOffsetAndPresence` atomic write pattern.
- **M010 `pending_invites`** (Phase 5.5.A) — last migration перед M011. M011 register call inserts after M010 line ~48.
- **`Database.writeEventsOffsetAndPresence`** (Phase 4.7.B) — existing atomic write used by D1 thread fan-out + body-bearing event writes.
- **`RawEvent.payload: [String: String]`** (Phase 1) — D1 uses existing flat-dict shape без модификации.
- **`SlackAPIProvider.fetchFilesUploaded`** (Phase 4.7.B) — extended (mime-bucket-only → full file metadata) under D1.
- **`GitHubAPIProvider.fetchMyOpenPRs`** (Phase 4.7.B) — referenced as bounded set surface; D1 NOT extends it (no extra REST per PR).
- **`LinearGraphQLProvider` `IssueHistoryFragment`** (Phase 4.6.B + 4.7.C) — D1 extends с `body` to nested-comments fragment.
- **`ClaudeCodeCollector` + `ClaudeCodeJSONLParser`** (Phase 2.3) — D1 audits; no shape changes expected.
- **ADR-010 §6 amendment** (Track 1 contract) — D1 enforces refined boundary on-device-yes / relay-no.

---

## 12. Commit decomposition

Per plan, 7 atomic commits sequential:

1. `feat(db): add M011 expression index on payload.event_kind` — M011 + Schema constants registration + idempotency test (§5.1).
2. `feat(payload): introduce EventPayloadKeys + AttachmentMeta + BodyCap moat` — Schema.swift extension + AttachmentMeta value type + LeafCorePrivate BodyCap; foundation, no behavior change. Tests §5.2 + §5.3.
3. `feat(linear): capture issue.description + comment.body + attachment metadata` — GraphQL fragment edits + snapshot extension + collector mapping. Tests §5.4 + §5.5.
4. `feat(github): capture PR/issue/review-comment bodies + Phase 4.8 PR metrics + attachments` — snapshot extension + parser changes + full commit message + body URL inline image parser + release.assets + collector mapping. Tests §5.6 + §5.7.
5. `feat(slack): capture message.text + conversations.replies fan-out + file metadata` — batch shape change + thread fan-out + per-thread cursor + budget moat + collector mapping + 429 handler. Tests §5.8 + §5.9.
6. `chore(claude-code): D1 hook completeness audit` — review note + cross-hook consistency test (§5.10). Or fix patch if gap surfaces.
7. `test(privacy): assert bodies do not leak into presence_state` — RelayBodyLeakageTests (§5.11). Explicit регрессия для §6 контракта; final acceptance gate.

**Order rationale:** foundation (1, 2) перед callers; Linear/GitHub/Slack независимы (можно review параллельно); Claude Code audit standalone; privacy regression — final acceptance gate. Each commit must pass `swift test` and `xcodebuild` build для всех 5 schemes.

---
