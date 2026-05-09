# Track 1 / D2 — FTS5 keyword index + cross-source link graph

**Status:** Draft (2026-05-09). Second sub-phase of Track 1 stack.
**Owner:** Dmitrii.
**Stack:** branches off `feature/track-1-D1-capture-extension` (off `feature/track-1-detection-substrate` off `main`). **НЕ merged в main** — D1 → D2 → D3 sequential, merge стэка в `main` коллективно после D3 ship + acceptance gate (контракт §13).

---

## 1. Context

D2 — substrate sub-phase, делает captured bodies (D1) запрашиваемыми по теме + материализует cross-source ассоциации в граф. Контракт уровня track'а — `2026-05-08-track-1-detection-substrate-contract.md` (§8). Декомпозиция (§4 контракта): D1 capture → D2 FTS5+links → D3 detectors+structured MCP.

**Зачем сейчас.** D1 (alpha.11) пишет bodies в `events.payload_json` через ключи `body` / `comment_bodies_json` / `thread_replies_json` / `messages_json` (`Schema.EventPayloadKeys`). Без FTS5 нет O(log n) topic search ("что я делал по auth?") — D3 detectors + `leaf_query_activity` MCP tool (UC1/UC3/UC4/UC5/UC6) полагаются на keyword filter поверх bodies. Без `event_links` граф LinearIDExtractor matches остаются metadata-only — UC4 ("почему вынесли OAuth refresh на сервер?") + UC5 ("что мне знать до ревью PR #142?") требуют JOIN от commit/Slack body → linked Linear issue / PR.

**Privacy stance** (контракт §6 amendment): bodies on-device — yes, в relay — never. D2 не пишет в relay вообще — Track 2 будет писать только filtered structured payloads без bodies. FTS5 derived index + event_links живут в той же encrypted SQLCipher DB. RelayBodyLeakageTests (§4.11) — explicit regression gate.

**Текущее состояние codebase (post-D1, alpha.11 baseline):**
- 1055 SPM tests, 21 SQLCipher tables (M001–M011). M011 expression index `idx_events_event_kind_ts` — ready под D3 query path.
- `events.payload_json` (TEXT JSON column) — D1 ключи `body`, `body_truncated`, `comment_bodies_json`, `thread_replies_json`, `messages_json`, `attachments_json`, `requested_reviewers_json`, `mention_count`, `link_count`, `additions`, `deletions`, `files_count`.
- `LinearIDExtractor.extract(text:knownPrefixes:)` (`Integrations/Linear/LinearIDExtractor.swift`) — pure, returns first match. `LinearIDPrefixCache` actor — TTL-cached prefix set.
- `Database.writeEventsOffsetAndPresence` (`DB/Database.swift:252-278`) — atomic write. Two more entry points: `write(_ event:)` (line 71-80), `write(_ events:)` (line 82-93).
- M011 registered @ `Database.swift:49` после M010. M012/M013 встанут сразу после.
- GRDB 7.10.0-sqlcipher fork (`gundemtech/GRDB.swift-sqlcipher`) — FTS5 enabled.

**Источники правды (priority при противоречии):**
1. `2026-05-08-track-1-detection-substrate-contract.md` §6, §8, §10 (D2-bound OQs OQ-3, OQ-4).
2. Existing patterns: `M011_EventKindIndex.swift` (migration extension), `PendingInvitesStore` (store style), `LinearIDExtractor` (pure extractor pattern).
3. ADR-010 §6 amendment: bodies on-device → yes, в relay → never.

**Contract amendment (§14 living document).** §8.2 пинит схему `event_links(from_event_id, to_event_id, link_kind TEXT, confidence REAL)`. D2 заменяет `to_event_id` на `target_kind TEXT NOT NULL` + `target_ref TEXT NOT NULL`. Reasoning: target часто ещё не существует как event на устройстве (Linear update прилетит через polling позже / referenced PR может быть чужим). External-ref keying — lossless. Resolution to event_id — at query time JOIN.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| **`M012_EventsFTS` migration** | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M012_EventsFTS.swift` (new) | `extension DatabaseMigrator { mutating func registerMigration012EventsFTS() }`. Creates `events_fts` FTS5 virtual table (contentless, tokenizer `unicode61 remove_diacritics 2 tokenchars '_-'`). Idempotent via `IF NOT EXISTS`. |
| **`M013_EventLinks` migration** | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M013_EventLinks.swift` (new) | Creates `event_links` table + reverse-lookup index `idx_event_links_target`. |
| **Migration registration** | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (edit) | Insert `migrator.registerMigration012EventsFTS()` + `migrator.registerMigration013EventLinks()` после M011 line ~49. |
| **`Schema.EventsFTS`** | `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` (edit) | Public table/column constants `tableName`, `body`, `bodyKind`, `eventID`. |
| **`Schema.EventLinks`** | `Schema.swift` (edit) | Public table/column constants `tableName`, `fromEventID`, `linkKind`, `targetKind`, `targetRef`, `confidence`, `createdAtMs`, `indexTarget`. |
| **`Schema.BodyKinds`** | `Schema.swift` (edit, new namespace) | Public string constants для 8 body_kind values (`commitMsg`, `linearDesc`, `linearComment`, `slackMsg`, `slackThreadParent`, `slackThreadReply`, `ghPR`, `ghIssueComment`, `ghPRReviewComment`). |
| **`Schema.LinkKinds`** | `Schema.swift` (edit, new namespace) | Public string constants для 5 link_kind values (`linearIDInText`, `branchNameLinearRef`, `prURLInSlack`, `prNumberHashRef`, `reviewerAssigned`). |
| **`Schema.TargetKinds`** | `Schema.swift` (edit, new namespace) | Public string constants для target_kind values (`linearIssue`, `githubPR`, `githubUser`). |
| **`EventsFullTextStore`** | `Packages/LeafCore/Sources/LeafCore/DB/EventsFullTextStore.swift` (new) | Public `enum EventsFullTextStore` с двумя static функциями: `indexEvent(eventID:signalType:bundleID:payload:in:)` и `search(query:period:limit:in:)`. Mirror `PendingInvitesStore` style. |
| **`EventLinksStore`** | `Packages/LeafCore/Sources/LeafCore/DB/EventLinksStore.swift` (new) | Public `enum EventLinksStore` с `deriveLinks(eventID:ts:payload:knownLinearPrefixes:in:)`, `eventsLinkingTo(targetKind:targetRef:period:in:)`, `linksFrom(eventID:in:)`. |
| **`EventLink` value type** | `Packages/LeafCore/Sources/LeafCore/Signals/EventLink.swift` (new) | `public struct EventLink: Codable, Sendable, Hashable` — `fromEventID`, `linkKind`, `targetKind`, `targetRef`, `confidence`, `createdAtMs`. |
| **`LinearIDExtractor.extractAll`** | `Integrations/Linear/LinearIDExtractor.swift` (edit) | New sibling method `static func extractAll(text:knownPrefixes:) -> [String]` — returns ordered + deduped matches. Existing `extract` (first-match) untouched. |
| **`LinkConfidence`** | `Packages/LeafCorePrivate/Prod/Detection/LinkConfidence.swift` (new, **moat**) | `public enum LinkConfidence` со static `Double` константами per link_kind (`linearIDInText`, `branchNameLinearRef`, `prURLInSlack`, `prNumberHashRef`, `reviewerAssigned`). Concrete numeric values — moat (heuristic tuning). Tests pin via inequality. |
| **`BranchNameLinearParser`** | `Packages/LeafCorePrivate/Prod/Detection/BranchNameLinearParser.swift` (new, **moat**) | `public enum BranchNameLinearParser` с `static func extract(branch:knownPrefixes:) -> String?`. Regex pattern — moat. |
| **`PRURLParser`** | `Packages/LeafCorePrivate/Prod/Detection/PRURLParser.swift` (new, **moat**) | `public enum PRURLParser` с `static func extract(text:) -> [String]` — returns canonical `owner/repo/pull/N` refs. Regex — moat. |
| **`PRHashRefParser`** | `Packages/LeafCorePrivate/Prod/Detection/PRHashRefParser.swift` (new, **moat**) | `public enum PRHashRefParser` с `static func extract(text:) -> [String]` — returns `#N` refs. Regex — moat. |
| **`Database.writeEventAndDerived`** | `DB/Database.swift` (edit, new private helper) | `private static func writeEventAndDerived(_ event: RawEvent, knownLinearPrefixes: Set<String>, in db: GRDB.Database) throws -> Int64`. Inserts EventRecord, calls `EventsFullTextStore.indexEvent`, calls `EventLinksStore.deriveLinks`. Returns event id. |
| **`Database.write` refactor** | `DB/Database.swift` (edit lines 71-80, 82-93, 252-278) | All three write paths (`write(_:)`, `write(_:[RawEvent])`, `writeEventsOffsetAndPresence`) refactored to call `writeEventAndDerived` inside same `pool.write {}` transaction. |
| **`writeEventsOffsetAndPresence` API extension** | `DB/Database.swift` (edit signature) | Add `knownLinearPrefixes: Set<String> = []` parameter (defaulted, backward-compat). Default empty → graceful no-op за no-Linear-aware callers. |
| **Tests — `M012EventsFTSTests`** | `Packages/LeafCore/Tests/LeafCoreTests/Migrations/M012EventsFTSTests.swift` (new) | 3 tests (§4.1). |
| **Tests — `M013EventLinksTests`** | `Packages/LeafCore/Tests/LeafCoreTests/Migrations/M013EventLinksTests.swift` (new) | 3 tests (§4.2). |
| **Tests — `EventsFullTextStoreTests`** | `Packages/LeafCore/Tests/LeafCoreTests/EventsFullTextStoreTests.swift` (new) | 8 tests (§4.3). |
| **Tests — `EventsFullTextStoreTokenizerTests`** | `Packages/LeafCore/Tests/LeafCorePrivateTests/EventsFullTextStoreTokenizerTests.swift` (new, moat target) | 4 tokenizer config tests (§4.4). |
| **Tests — `EventLinksStoreTests`** | `Packages/LeafCore/Tests/LeafCoreTests/EventLinksStoreTests.swift` (new) | 10 tests (§4.5). |
| **Tests — `LinearIDExtractorAllTests`** | existing `LinearIDExtractorTests.swift` (edit) | 3 new tests for `extractAll` (§4.6). |
| **Tests — `BranchNameLinearParserTests`** | `Packages/LeafCore/Tests/LeafCorePrivateTests/BranchNameLinearParserTests.swift` (new, moat) | 4 tests (§4.7). |
| **Tests — `PRURLParserTests`** | `Packages/LeafCore/Tests/LeafCorePrivateTests/PRURLParserTests.swift` (new, moat) | 3 tests (§4.8). |
| **Tests — `PRHashRefParserTests`** | `Packages/LeafCore/Tests/LeafCorePrivateTests/PRHashRefParserTests.swift` (new, moat) | 3 tests (§4.9). |
| **Tests — `DatabaseWriteAndDeriveIntegrationTests`** | `Packages/LeafCore/Tests/LeafCoreTests/DatabaseWriteAndDeriveIntegrationTests.swift` (new) | 4 tests (§4.10). |
| **Tests — `RelayBodyLeakageTests` extension** | existing `RelayBodyLeakageTests.swift` (edit) | 3 new privacy regression tests (§4.11). |

### НЕ входит (явно отложено)

- **`decisions` / `open_questions` / `blockers` tables** — D3.
- **3 high-level structured MCP tools** (`leaf_query_activity` / `leaf_get_decision` / `leaf_current_work`) — D3.
- **5 detector types** (`DecisionDetector` / `OpenQuestionDetector` / `BlockerDetector` / `WhereStoppedDeriver` / `AbsenceFlag`) — D3.
- **`reviewer_to_thread_participant` link materialization** — D3 computes on-the-fly для UC5; D2 не пишет в `event_links`. Если потом понадобится материализация — D3 amend контракт.
- **`file_path_match` link_kind** — D2 не имеет per-commit file lists в payload (D1 captures `files_count` Int только; full file path list требует extra `/repos/.../commits/<sha>` REST fetch under rate-limit). Defer до future track или D3 если потребуется (FSEvents path matching standalone).
- **ShareEventTypeRegistry expansion** (`decision_detected` etc.) — D3 регистрирует.
- **Whitepaper sync** — отложен до Track 1 ship per §12 контракта.
- **Backfill старых events bodies → FTS** — write-forward only. Optional admin command `RebuildFTS5(from:to:)` в LeafCorePrivate можно surface'ить через MCP debug — но не часть D2 acceptance gate.
- **`snippet()` / `highlight()` ranking helpers** — contentless mode не support'ит. D3 fetch'ает body из events.payload_json для excerpts (всё равно нужно для structured response).
- **Cursor / Windsurf / Continue.dev / Copilot / ChatGPT Desktop hooks** — out of scope Track 1.
- **AST symbols / SourceKit / tree-sitter** — out of scope Track 1.
- **Embedding index / vector search** — future track per контракт §11.

---

## 3. Public API design

### 3.1 `M012_EventsFTS.swift`

```swift
import Foundation
import GRDB

public extension DatabaseMigrator {
    mutating func registerMigration012EventsFTS() {
        registerMigration("012_events_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
                    body,
                    body_kind UNINDEXED,
                    event_id UNINDEXED,
                    tokenize = "unicode61 remove_diacritics 2 tokenchars '_-'",
                    content = ''
                )
                """)
        }
    }
}
```

Contentless mode (`content = ''`) — body не дублируется в FTS internal tables. Tokenizer `unicode61` — Unicode-aware с removing diacritics + treating `_` and `-` as token chars (snake_case + kebab-case identifiers).

### 3.2 `M013_EventLinks.swift`

```swift
public extension DatabaseMigrator {
    mutating func registerMigration013EventLinks() {
        registerMigration("013_event_links") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS event_links (
                    from_event_id INTEGER NOT NULL,
                    link_kind     TEXT    NOT NULL,
                    target_kind   TEXT    NOT NULL,
                    target_ref    TEXT    NOT NULL,
                    confidence    REAL    NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (from_event_id, link_kind, target_ref)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_event_links_target
                ON event_links (target_kind, target_ref)
                """)
        }
    }
}
```

`from_event_id` — logical FK to `events.id` (no SQL FOREIGN KEY per repo convention — Schema.swift comments §76, §86). Composite PK dedupes per-event-per-target. Reverse index — D3 query path "events linked to LEAF-127".

### 3.3 `Schema` extensions

```swift
extension Schema {
    public enum EventsFTS {
        public static let tableName = "events_fts"
        public static let body = "body"
        public static let bodyKind = "body_kind"
        public static let eventID = "event_id"
    }

    public enum EventLinks {
        public static let tableName = "event_links"
        public static let fromEventID = "from_event_id"
        public static let linkKind = "link_kind"
        public static let targetKind = "target_kind"
        public static let targetRef = "target_ref"
        public static let confidence = "confidence"
        public static let createdAtMs = "created_at_ms"
        public static let indexTarget = "idx_event_links_target"
    }

    public enum BodyKinds {
        public static let commitMsg = "commit_msg"
        public static let linearDesc = "linear_desc"
        public static let linearComment = "linear_comment"
        public static let slackMsg = "slack_msg"
        public static let slackThreadParent = "slack_thread_parent"
        public static let slackThreadReply = "slack_thread_reply"
        public static let ghPR = "gh_pr"
        public static let ghIssueComment = "gh_issue_comment"
        public static let ghPRReviewComment = "gh_pr_review_comment"
    }

    public enum LinkKinds {
        public static let linearIDInText = "linear_id_in_text"
        public static let branchNameLinearRef = "branch_name_linear_ref"
        public static let prURLInSlack = "pr_url_in_slack"
        public static let prNumberHashRef = "pr_number_hash_ref"
        public static let reviewerAssigned = "reviewer_assigned"
    }

    public enum TargetKinds {
        public static let linearIssue = "linear_issue"
        public static let githubPR = "github_pr"
        public static let githubUser = "github_user"
    }
}
```

### 3.4 `EventsFullTextStore`

```swift
public enum EventsFullTextStore {
    /// Body extraction + FTS5 row insertion. Called inside same pool.write {}
    /// transaction as event insert. No-op if event has no body-bearing payload keys.
    public static func indexEvent(
        eventID: Int64,
        signalType: String,
        bundleID: String,
        payload: [String: String],
        in db: GRDB.Database
    ) throws

    /// FTS5 keyword search. Returns DISTINCT event IDs ranked by BM25,
    /// filtered by inclusive ts range. Limit applied after dedup.
    public static func search(
        query: String,
        period: ClosedRange<Int64>,
        limit: Int = 100,
        in db: GRDB.Database
    ) throws -> [Int64]
}
```

**Body extraction logic** (private helper inside store):

| Trigger | Output |
|---|---|
| `payload[.body]` non-empty + `payload.event_kind == "linear_issue_updated"` | 1 row, body_kind=`linear_desc` |
| `payload[.body]` non-empty + event_kind starts with `gh_pr_` (incl. opened/edited/closed/merged variants) | 1 row, body_kind=`gh_pr` |
| `payload[.body]` non-empty + event_kind == `gh_issue_comment_authored` | 1 row, body_kind=`gh_issue_comment` |
| `payload[.body]` non-empty + event_kind == `gh_pr_review_comment_authored` | 1 row, body_kind=`gh_pr_review_comment` |
| `payload[.body]` non-empty + event_kind == `commit_pushed` | 1 row, body_kind=`commit_msg` |
| `payload[.body]` non-empty + event_kind == `slack_thread_reply_aggregate` | 1 row, body_kind=`slack_thread_parent` |
| `payload[.commentBodiesJson]` decodes to `[LinearCommentBody]` | N rows, body_kind=`linear_comment` each |
| `payload[.threadRepliesJson]` decodes to `[SlackMessageRecord]` | N rows, body_kind=`slack_thread_reply` each |
| `payload[.messagesJson]` decodes to `[SlackMessageRecord]` | N rows, body_kind=`slack_msg` each |

Skip empty bodies. Failed JSON decode → log + skip (graceful — should not happen but resilient).

**Insert SQL:**
```sql
INSERT INTO events_fts (event_id, body_kind, body) VALUES (?, ?, ?);
```
N rows per event.

**Search SQL:**
```sql
SELECT DISTINCT events_fts.event_id
FROM events_fts
JOIN events ON events.id = events_fts.event_id
WHERE events_fts MATCH ?
  AND events.ts BETWEEN ? AND ?
ORDER BY rank
LIMIT ?;
```

`MATCH` narrows via FTS5 first; JOIN filters by ts. SQLite query planner handles fine. Recipe is documented FTS5 idiom.

### 3.5 `EventLinksStore`

```swift
public enum EventLinksStore {
    public static func deriveLinks(
        eventID: Int64,
        ts: Int64,
        payload: [String: String],
        knownLinearPrefixes: Set<String>,
        in db: GRDB.Database
    ) throws

    public static func eventsLinkingTo(
        targetKind: String,
        targetRef: String,
        period: ClosedRange<Int64>?,
        in db: GRDB.Database
    ) throws -> [Int64]

    public static func linksFrom(
        eventID: Int64,
        in db: GRDB.Database
    ) throws -> [EventLink]
}
```

**Derivation table:**

| Source body / payload field | Extractor | link_kind | target_kind | target_ref shape |
|---|---|---|---|---|
| Any body (commit_msg / linear_desc / linear_comment / slack_msg / slack_thread_parent / slack_thread_reply / gh_pr / gh_issue_comment / gh_pr_review_comment) | `LinearIDExtractor.extractAll(text:knownPrefixes:)` | `linear_id_in_text` | `linear_issue` | `"LEAF-127"` |
| `payload.event_kind == "commit_pushed"` + `payload.branch` | `BranchNameLinearParser.extract(branch:knownPrefixes:)` | `branch_name_linear_ref` | `linear_issue` | `"LEAF-127"` |
| Slack body (slack_msg / slack_thread_parent / slack_thread_reply) | `PRURLParser.extract(text:)` | `pr_url_in_slack` | `github_pr` | `"owner/repo/pull/123"` |
| Slack body | `PRHashRefParser.extract(text:)` | `pr_number_hash_ref` | `github_pr` | `"#123"` |
| `payload.requested_reviewers_json` (gh_pr events) | iterate logins | `reviewer_assigned` | `github_user` | login string |

**Insert SQL:**
```sql
INSERT OR IGNORE INTO event_links
    (from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms)
VALUES (?, ?, ?, ?, ?, ?);
```
`OR IGNORE` идемпотентно при PK conflict.

**`eventsLinkingTo` SQL:**
```sql
SELECT DISTINCT el.from_event_id
FROM event_links el
JOIN events e ON e.id = el.from_event_id
WHERE el.target_kind = ? AND el.target_ref = ?
  AND e.ts BETWEEN ? AND ?
ORDER BY e.ts DESC
LIMIT 200;
```
Period optional — без него skip JOIN/BETWEEN.

### 3.6 `EventLink` value type

```swift
public struct EventLink: Codable, Sendable, Hashable {
    public let fromEventID: Int64
    public let linkKind: String
    public let targetKind: String
    public let targetRef: String
    public let confidence: Double
    public let createdAtMs: Int64

    public init(
        fromEventID: Int64,
        linkKind: String,
        targetKind: String,
        targetRef: String,
        confidence: Double,
        createdAtMs: Int64
    )
}
```

### 3.7 `LinearIDExtractor.extractAll`

```swift
public extension LinearIDExtractor {
    /// Returns ALL Linear ID matches (ordered by appearance, deduped).
    /// Distinct from `extract(text:knownPrefixes:)` which returns first match only.
    /// Empty `knownPrefixes` → []. No matches → [].
    static func extractAll(text: String, knownPrefixes: Set<String>) -> [String]
}
```

Existing `extract` semantics untouched (no caller break). Implementation iterates same `pattern.matches(in:options:range:)` → filters by prefix whitelist → dedupes preserving order.

### 3.8 `LinkConfidence` (moat)

```swift
// LeafCorePrivate/Prod/Detection/LinkConfidence.swift
public enum LinkConfidence {
    public static let linearIDInText: Double
    public static let branchNameLinearRef: Double
    public static let prURLInSlack: Double
    public static let prNumberHashRef: Double
    public static let reviewerAssigned: Double
}
```

Concrete numeric values — moat (heuristic tuning). Not in spec, not in whitepaper. Tests pin via inequality (`> 0.0`, `<= 1.0`, ordered relative to each other if needed).

### 3.9 Parser API (moat)

```swift
// LeafCorePrivate/Prod/Detection/BranchNameLinearParser.swift
public enum BranchNameLinearParser {
    public static func extract(branch: String, knownPrefixes: Set<String>) -> String?
}

// LeafCorePrivate/Prod/Detection/PRURLParser.swift
public enum PRURLParser {
    public static func extract(text: String) -> [String]  // canonical "owner/repo/pull/N"
}

// LeafCorePrivate/Prod/Detection/PRHashRefParser.swift
public enum PRHashRefParser {
    public static func extract(text: String) -> [String]  // "#N"
}
```

Regex patterns — moat. Tests pin behavior on fixed-vector inputs.

### 3.10 `Database.writeEventAndDerived` private helper + write path refactor

```swift
private static func writeEventAndDerived(
    _ event: RawEvent,
    knownLinearPrefixes: Set<String>,
    in db: GRDB.Database
) throws -> Int64 {
    var record = try EventRecord.make(from: event)
    try record.insert(db)
    let eventID = record.id!

    try EventsFullTextStore.indexEvent(
        eventID: eventID,
        signalType: event.signalType.rawValue,
        bundleID: event.bundleID,
        payload: event.payload,
        in: db
    )

    try EventLinksStore.deriveLinks(
        eventID: eventID,
        ts: event.timestampMs,
        payload: event.payload,
        knownLinearPrefixes: knownLinearPrefixes,
        in: db
    )

    return eventID
}
```

**Public API extension** на `Database`:

```swift
public func writeEventsOffsetAndPresence(
    _ events: [RawEvent],
    offset: CollectorOffset,
    presence: (provider: PresenceStateWriter.Provider,
               state: [String: Any],
               derivedMode: String?)?,
    knownLinearPrefixes: Set<String> = [],  // NEW
    nowMs: Int64
) throws
```

`knownLinearPrefixes` defaulted к empty — backward-compat. Existing callers compile unchanged. Linear-aware collectors (Linear / GitHub / Slack) snapshot prefixes pre-tick через `LinearIDPrefixCache.currentPrefixes()` (`await`) и передают snapshot в `pool.write {}` (sync).

`write(_:)` и `write(_:[RawEvent])` overloads: добавлены defaulted `knownLinearPrefixes: Set<String> = []` parameter, refactor'ятся через `writeEventAndDerived`.

---

## 4. Test plan

**Total: 48 new tests.** Baseline 1055 → ~1103 после D2.

### 4.1 `M012EventsFTSTests` (3 tests)

1. `testM012_CreatesVirtualTable` — open DB → query `sqlite_master WHERE name='events_fts'` → assert row exists, sql contains `fts5(`, `unicode61`, `remove_diacritics 2`, `tokenchars '_-'`, `content=''`.
2. `testM012_IsIdempotentOnReopen` — open, close, reopen — no crash.
3. `testM012_FullSequenceRunsCleanly` — fresh DB → assert M001–M013 все applied (`grdb_migrations` lists `012_events_fts`).

### 4.2 `M013EventLinksTests` (3 tests)

1. `testM013_CreatesTable` — assert columns + composite PK + reverse index `idx_event_links_target` exist via `sqlite_master` + `pragma table_info`.
2. `testM013_IsIdempotentOnReopen`.
3. `testM013_FullSequenceRunsCleanly`.

### 4.3 `EventsFullTextStoreTests` (8 tests)

1. `testIndexEvent_LinearIssueDescription` — RawEvent с event_kind=linear_issue_updated + body="OAuth refactor" → 1 FTS row, body_kind=linear_desc.
2. `testIndexEvent_LinearCommentBodies_FanOut` — payload с comment_bodies_json массив 3 → 3 FTS rows body_kind=linear_comment + 1 desc row.
3. `testIndexEvent_SlackMessagesAggregate_FanOut` — messages_json 5 messages → 5 rows body_kind=slack_msg, NO top-level row.
4. `testIndexEvent_SlackThreadReply_ParentPlusReplies` — slack_thread_reply_aggregate event с body + thread_replies_json 2 → 1 row slack_thread_parent + 2 rows slack_thread_reply.
5. `testIndexEvent_GitHubPRBody` — gh_pr_opened/edited event с body → 1 row body_kind=gh_pr.
6. `testIndexEvent_NoBody_NoOp` — RawEvent без body keys → 0 FTS rows, no error.
7. `testSearch_BM25Ranking_OrdersByRelevance` — 3 events с убывающей term frequency → search returns ordered IDs (highest-rank first).
8. `testSearch_PeriodFilterExcludesOutOfRange` — 2 events с different ts; search в narrow period → returns only one.

### 4.4 `EventsFullTextStoreTokenizerTests` (4 tests, LeafCorePrivate test target)

1. `testTokenizer_MatchesSnakeCase` — body containing `oauth_refresh` matches both `oauth_refresh` and `oauth` queries.
2. `testTokenizer_MatchesKebabCase` — `auth-refresh` similar.
3. `testTokenizer_DiacriticsRemoved` — `café` matches `cafe`.
4. `testTokenizer_RuEnMix` — query `аутентификация` matches body containing it; `auth` matches body containing `auth`.

### 4.5 `EventLinksStoreTests` (10 tests)

1. `testDeriveLinks_LinearIDInText_Match` — body "Working on LEAF-127", knownPrefixes={"LEAF"} → 1 row (linear_id_in_text, linear_issue, "LEAF-127", confidence == LinkConfidence.linearIDInText).
2. `testDeriveLinks_LinearIDInText_AllMatches` — body "fixes LEAF-127 and LEAF-200" → 2 rows.
3. `testDeriveLinks_LinearIDInText_UnknownPrefixIgnored` — body "BAD-99", knownPrefixes={"LEAF"} → 0 rows.
4. `testDeriveLinks_BranchName_FeatureLinear` — payload.branch="feature/LEAF-127-foo" → branch_name_linear_ref row.
5. `testDeriveLinks_PRURLInSlack` — Slack body "see https://github.com/owner/repo/pull/42" → pr_url_in_slack row, target_ref="owner/repo/pull/42".
6. `testDeriveLinks_PRHashRef` — Slack body "blocked on #PR-42" → pr_number_hash_ref row, target_ref="#42".
7. `testDeriveLinks_RequestedReviewers_FanOut` — payload.requested_reviewers_json='["alice","bob"]' → 2 rows reviewer_assigned/github_user.
8. `testDeriveLinks_NoBody_NoOp` — RawEvent без bodies → 0 rows.
9. `testDeriveLinks_DuplicateInsertIgnored` — same event re-derived → INSERT OR IGNORE keeps single row.
10. `testEventsLinkingTo_FiltersByPeriod` — 2 events linking LEAF-127 в разные ts; period filter returns subset.

### 4.6 `LinearIDExtractorAllTests` (3 tests, extends existing `LinearIDExtractorTests.swift`)

1. `testExtractAll_MultipleMatches_OrderedDedup` — text "LEAF-127 and LEAF-200 and LEAF-127" → ["LEAF-127","LEAF-200"].
2. `testExtractAll_EmptyKnownPrefixes_ReturnsEmpty`.
3. `testExtractAll_NoMatches_ReturnsEmpty`.

### 4.7 `BranchNameLinearParserTests` (4 tests, LeafCorePrivate moat)

1. `testExtract_FeaturePrefix` — "feature/LEAF-127-foo" + {"LEAF"} → "LEAF-127".
2. `testExtract_FixPrefix` — "fix/LEAF-200" → "LEAF-200".
3. `testExtract_PlainBranch` — "LEAF-300-something" → "LEAF-300".
4. `testExtract_UnknownPrefix_Nil` — "feature/BAD-99" + {"LEAF"} → nil.

### 4.8 `PRURLParserTests` (3 tests, LeafCorePrivate)

1. `testExtract_StandardURL` — "see https://github.com/owner/repo/pull/42" → ["owner/repo/pull/42"].
2. `testExtract_MultipleURLs_AllReturned`.
3. `testExtract_NonGitHubURL_Ignored` — "https://example.com/pull/42" → [].

### 4.9 `PRHashRefParserTests` (3 tests, LeafCorePrivate)

1. `testExtract_HashPrefix` — "#PR-42" → ["#42"].
2. `testExtract_ParenthesizedForm` — "(PR #123)" → ["#123"].
3. `testExtract_BareNumberIgnored` — "issue 42" → [] (precision over recall).

### 4.10 `DatabaseWriteAndDeriveIntegrationTests` (4 tests, end-to-end)

1. `testWrite_IndexesAndLinks_Atomically` — `db.write(rawEvent)` где payload имеет body + Linear ID → after write: events row + events_fts row + event_links row все present в same DB snapshot.
2. `testWriteBatch_AllEventsIndexed` — `db.write([e1, e2, e3])` → 3 events_fts rows derived.
3. `testWriteEventsOffsetAndPresence_FullPipeline` — atomic write через 4.7.B path → events + offset + presence_state + events_fts + event_links все updated в single transaction.
4. `testWriteEventsOffsetAndPresence_FailureRollsBackAll` — inject failure (e.g. invalid presence state с не-encodable value) → assert events_fts + event_links rows NOT inserted (transaction atomicity preserved).

### 4.11 `RelayBodyLeakageTests` extension (3 tests)

1. `testEventLinksTargetRef_DoesNotLeakIntoPresenceState` — write event с Linear ID → event_links row создаётся → assert "LEAF-127" target_ref string NOT present в `presence_state.state_json`.
2. `testFTSBodies_DoNotLeakIntoPresenceState` — event с body "secret reasoning" → events_fts row exists → assert body string NOT в `presence_state.state_json`.
3. `testCrossDatabaseIsolation_FTSAndEventLinks_NotInPresenceFlow` — `writeEventsOffsetAndPresence` → presence captures only structured fields (counts/transitions/timestamps); FTS body texts + link target_refs не появляются в presence write.

---

## 5. Test target conventions

- **Framework:** XCTest. No Swift Testing macros.
- **DB tests:** mirror Phase 5.5 / D1 pattern — temp dir в `setUp` через `FileManager.default.temporaryDirectory.appendingPathComponent("leaf-D2-\(UUID().uuidString)", isDirectory: true)`; `tearDown` cleans. `Database.openForWrite(at:..., config: .weakDefaults, encryption: .deterministicTest)`.
- **Store tests:** unit-level — open DB, write fixtures via store API, assert via direct SQL `Row.fetchOne(db, sql:)`.
- **Tokenizer tests:** в LeafCorePrivate target — позволяет direct FTS5 query patterns без exposing internals.
- **Parser tests (moat):** XCTestCase в LeafCorePrivate target. Fixed-vector inputs.
- **Integration tests:** через public `Database.write(_:)` / `Database.writeEventsOffsetAndPresence(_:offset:presence:knownLinearPrefixes:nowMs:)` API.

---

## 6. Acceptance criteria

D2 closed когда:

1. `swift test --package-path Packages/LeafCore` green, count = ~1103 (±5 baseline drift).
2. `xcodebuild -scheme LeafCore -configuration Debug build` SUCCESS.
3. `xcodebuild -scheme LeafCorePrivate -configuration Debug build` SUCCESS.
4. `xcodebuild -scheme Leaf -configuration Debug build` SUCCESS.
5. `xcodebuild -scheme LeafAgent -configuration Debug build` SUCCESS.
6. `xcodebuild -scheme LeafMCP -configuration Debug build` SUCCESS.
7. **M012 + M013 applied** — `events_fts` virtual table + `event_links` table + `idx_event_links_target` index visible через `sqlite_master`.
8. **End-to-end pipeline working** — `Database.write(_:)` writes event + FTS5 rows + event_links rows atomically (test 4.10.1).
9. **Privacy regression green** — `RelayBodyLeakageTests` extensions (tests 4.11.1-3): bodies + target_refs не leak'аются в `presence_state`.
10. Branch `feature/track-1-D2-fts-and-link-graph` (off `feature/track-1-D1-capture-extension`) пушнут на origin. **Не merged в main** — стэк под D3, merge коллективно после Track 1 ship + acceptance gate (контракт §13).
11. Independent code review (Stage 6 workflow) — APPROVED или APPROVED-WITH-NITS.
12. `current-state.md` обновлён в финальном commit (отдельный `docs(shared): Phase Track-1 D2 landed`).

**НЕ acceptance criteria для D2:**
- Whitepaper sync — отложен до Track 1 ship per контракт §12.
- UC1/UC3/UC4/UC5/UC6 working end-to-end — Track 1 acceptance gate (§13 контракта), требует D3.
- 3 high-level structured MCP tools — D3.
- Detector implementations (DecisionDetector etc.) — D3.

---

## 7. Out of scope для D2 (carry-overs)

| Excluded | Reserved for |
|---|---|
| `decisions` / `open_questions` / `blockers` tables | D3 |
| 3 high-level structured MCP tools | D3 |
| 5 detector types + reuse pattern | D3 |
| `reviewer_to_thread_participant` link materialization | D3 (computed on-the-fly for UC5) |
| `file_path_match` link_kind | Future (requires per-commit file lists capture) |
| ShareEventTypeRegistry expansion (`decision_detected` etc.) | D3 |
| `snippet()` / `highlight()` ranking helpers | Out of scope (contentless mode не support'ит); D3 fetches body from events for excerpts |
| Backfill старых events bodies → FTS | Future optional admin command |
| Whitepaper sync | Track 1 ship (post-D3) |
| Cursor / Windsurf / Continue.dev / Copilot / ChatGPT Desktop hooks | Future track |
| AST symbols / SourceKit / tree-sitter | Future track |
| Calendar deepening | Future track |
| LLM Summarizer / embeddings / vector search | Future track |
| `leaf_query_team` MCP tool + cross-device E2E | Track 2 |
| Slack-bot surface (`/leaf` slash command) | Track 2 |
| Native UI redesign (decisions/open-questions/blockers panels) | Post-Track-1 |

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| **FTS5 row growth** — multi-row fan-out для Slack aggregates × 5 messages × 64KB cap | Hard cap уже в D1 (BodyCap 64KB). Multi-row design accepts bounded inflation. WAL checkpoint discipline (15 min / 4MB existing, без изменений). Manual smoke `du -h ~/Library/Application\ Support/Leaf/events.sqlite` before/after week. |
| **Tokenizer config syntax не parse'ится SQLite/SQLCipher** — `tokenchars '_-'` quoting edge case | Test 4.1.1 verifies sql DDL stored matches expected; tests 4.4.1-4 verify behavior. If parse fails — migration не зарегистрируется, тесты сразу упадут. |
| **`MATCH ?` query syntax** — FTS5 query language имеет собственный синтаксис, user input может содержать invalid characters | `EventsFullTextStore.search` принимает raw query string; production caller (D3 leaf_query_activity) wraps в `"\(query)*"` или escapes. D2 не осуществляет sanitization — это D3 concern. Тесты используют known-safe queries. |
| **`knownLinearPrefixes` snapshot stale** — Linear cache TTL 1 час; новые team prefixes за это окно не linked | Acceptable — `LinearIDPrefixCache.invalidate()` доступен на reconnect. Most-active prefixes stable. Worst case — events linked retroactively через optional admin RebuildFTS5 command (deferred). |
| **`writeEventAndDerived` performance regression** — N FTS rows + M link rows per event | Profiled через test 4.10.2 (batch 3 events). Aggregate cost: ~10 SQL inserts per Slack-thread event worst case. На typical tick 5-50 events → < 100ms. Если regression hit'ает — fallback на async queue, но контракт §8.1 prefers sync ("FTS5 inserts are cheap"). |
| **Transaction atomicity break** — implementer случайно вынесет FTS sync ИЗ pool.write | Test 4.10.4 — failure injection asserts rollback. Refactor disciplined: single private helper called from all 3 paths. |
| **`LinearIDExtractor.extract` callers depend on first-match semantics** | New `extractAll` method added как sibling, `extract` untouched. Zero behavioral diff для existing callers. |
| **`PRHashRefParser` false positives** — `#42` matches issue numbers и version tags | Conservative regex (только `#PR-NNN` или `(PR #NNN)` shapes — leading "PR" required). Test 4.9.3 pin'ит "issue 42" → [] (precision over recall). |
| **D3 schema drift** — D3 захочет `to_event_id` resolved column в event_links | Living document amendment. Текущий design (target_ref TEXT) lossless — D3 может resolve at query time via JOIN или add cached `to_event_id` NULLABLE column в новой migration без data loss. |
| **JSON decode failure в body extraction** — corrupt payload | Graceful — log + skip, no FTS rows для that key. Event row still inserted. Impact: missed indexing для one event, не crash. |

---

## 9. Verification

```bash
cd ~/Desktop/Leaf/leaf/Packages/LeafCore && swift test
# Expect: ~1103 tests pass (1055 baseline + 48 new D2 tests)

cd ~/Desktop/Leaf/leaf
xcodebuild -scheme LeafCore        -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafCorePrivate -configuration Debug build  # SUCCESS
xcodebuild -scheme Leaf            -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafAgent       -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafMCP         -configuration Debug build  # SUCCESS
```

**Manual smoke** (post-merge of D2 to feature/track-1-detection-substrate):

```bash
# FTS5 keyword search
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" \
  "SELECT body_kind, event_id
   FROM events_fts
   WHERE events_fts MATCH 'auth*'
   LIMIT 10;"
# Expect: rows with body_kind ∈ {commit_msg, linear_desc, linear_comment, slack_msg, ...}.

# event_links graph
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" \
  "SELECT link_kind, target_kind, target_ref, confidence
   FROM event_links
   ORDER BY created_at_ms DESC LIMIT 20;"
# Expect: linear_id_in_text → linear_issue → LEAF-NN, branch_name_linear_ref similar,
# pr_url_in_slack → github_pr → owner/repo/pull/N для real Slack work с PR linking.

# Reverse-lookup: events linking to specific issue
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" \
  "SELECT DISTINCT el.from_event_id
   FROM event_links el
   WHERE el.target_kind='linear_issue' AND el.target_ref='LEAF-NN';"
```

**Privacy spot-check:**

```bash
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" \
  "SELECT provider, state_json FROM presence_state;"
# Manual visual: state_json содержит ТОЛЬКО counts/transitions/timestamps.
# Никаких body снippet'ов. Никаких "LEAF-NN" target_ref'ов.

# Cross-table privacy check
sqlite3 "$HOME/Library/Application Support/Leaf/events.sqlite" <<'SQL'
.mode column
SELECT 'fts_count' AS metric, COUNT(*) FROM events_fts
UNION ALL SELECT 'links_count', COUNT(*) FROM event_links
UNION ALL SELECT 'events_count', COUNT(*) FROM events;
SQL
# Sanity check: fts_count ≥ events_count (multi-row fan-out)
# links_count ≤ events_count × 3 (typical: most events have 0-2 links)
```

**Pre-push:** `/pre-push-leaf` — D2 публикует public-safe substrate (M012/M013 SQL DDL, EventsFullTextStore + EventLinksStore API, EventLink struct, 9 body_kind values, 5 link_kind values, 3 target_kind values). Implementation moat (`LinkConfidence` numeric values, parser regex'ы) — все в LeafCorePrivate.

---

## 10. Dependencies on prior phases

- **D1 capture extension** (alpha.11) — D2 reads payload keys `body`, `comment_bodies_json`, `thread_replies_json`, `messages_json`, `requested_reviewers_json`. Без D1 — empty bodies → no-op FTS rows + no link rows.
- **`Schema.EventPayloadKeys`** (D1) — D2 reads via these constants для body extraction.
- **`Database.writeEventsOffsetAndPresence`** (Phase 4.7.B) — D2 extends signature с `knownLinearPrefixes` parameter.
- **`LinearIDExtractor.extract` + `LinearIDPrefixCache`** (Phase 4.7.A) — D2 extends extractor с `extractAll` sibling, reads cache snapshot.
- **GRDB 7.10.0-sqlcipher fork** (`gundemtech/GRDB.swift-sqlcipher`) — FTS5 enabled. No Package.swift changes.
- **M011 expression index `idx_events_event_kind_ts`** (D1) — D2 не использует напрямую, но D3 query path (using events_fts + event_kind filter) будет использовать оба.
- **ADR-010 §6 amendment** (Track 1 contract) — bodies on-device → yes, в relay → never. D2 enforces через RelayBodyLeakageTests.

---

## 11. Commit decomposition

6 atomic commits, sequential per TDD discipline (each commit passes `swift test` + xcodebuild всех 5 schemes):

1. **`feat(db): add M012 events_fts virtual table migration`** — M012 file + Database.swift registration + Schema.EventsFTS + Schema.BodyKinds constants + 3 tests (§4.1). Foundation, no callers.
2. **`feat(db): add M013 event_links table migration`** — M013 file + Database.swift registration + Schema.EventLinks + Schema.LinkKinds + Schema.TargetKinds constants + 3 tests (§4.2). Foundation.
3. **`feat(fts): introduce EventsFullTextStore + body extraction pipeline`** — `EventsFullTextStore.swift` + body fan-out logic + 8 store tests (§4.3) + 4 tokenizer tests (§4.4). Pure store level, не wired в Database.
4. **`feat(links): introduce EventLinksStore + LinkConfidence + parsers (moat)`** — `EventLinksStore.swift` + `EventLink` value type + `LinearIDExtractor.extractAll` + `LinkConfidence` (LeafCorePrivate) + `BranchNameLinearParser` / `PRURLParser` / `PRHashRefParser` (LeafCorePrivate) + 10+3+4+3+3 tests (§4.5–4.9). Pure store level.
5. **`feat(db): wire FTS5 + event_links into atomic write paths`** — refactor `Database.write(_:)`, `Database.write(_ events:)`, `Database.writeEventsOffsetAndPresence` через shared `writeEventAndDerived` private helper. Add `knownLinearPrefixes: Set<String> = []` parameter (defaulted, backward-compat). 4 integration tests (§4.10).
6. **`test(privacy): assert bodies + link target_refs do not leak into presence_state`** — extend `RelayBodyLeakageTests` (3 tests, §4.11). Final acceptance gate per контракт §6.

**Order rationale:**
- Migrations first (1, 2) — schema готова до callers.
- Pure stores next (3, 4) — изолированные unit'ы, легко review независимо. Порядок 3→4 condition: FTS store не depends на link store; обратное тоже верно.
- Wire-in (5) — integration commit, refactor existing 3 write paths. Все unit tests существующих stores уже green к этой точке.
- Privacy regression (6) — final gate, отдельный commit для visibility.

Each commit must pass `swift test` and `xcodebuild` build для всех 5 schemes.

---
