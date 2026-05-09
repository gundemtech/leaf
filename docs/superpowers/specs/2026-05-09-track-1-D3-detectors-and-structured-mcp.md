# Track 1 / D3 — Detectors + structured MCP tools

**Status:** Draft → Active after user review.
**Track contract:** `docs/superpowers/specs/2026-05-08-track-1-detection-substrate-contract.md`
**Prior sub-phases:** `2026-05-09-track-1-D1-capture-extension.md`, `2026-05-09-track-1-D2-fts-and-link-graph.md`
**Branch:** `feature/track-1-D3-detectors-and-structured-mcp` off `feature/track-1-D2-fts-and-link-graph`.
**Baseline:** D2 ship — 1108 SPM tests, M001..M013, EventsFullTextStore + EventLinksStore + LinkDerivers injection + atomic writeEventAndDerived helper.

---

## 1. Context

D3 closes Track 1: turns captured bodies (D1) and the keyword + link graph (D2) into **semantic facts** (decisions, open questions, blockers, where-stopped digests) and exposes them via **3 high-level structured MCP tools** that compose the entire Track 1 substrate (events + FTS + links + detector outputs).

Pattern-based, **zero LLM**. AI client (Claude Code / Cursor) reads the structured JSON response and formulates the natural-language answer itself. Track 2 will extend the same detector outputs to team distribution; Track 1 stops at single-device.

### 1.1 Use cases unblocked

Per contract §2 fitness function, D3 unblocks **UC1 / UC3 / UC4 / UC5 / UC6** end-to-end (UC2 / UC7 stay in Track 2).

| UC | Tool | Composition path |
|---|---|---|
| **UC1** "что я делал в пятницу по auth?" | `leaf_query_activity` | period + filter (FTS) → events + linked entities + decisions |
| **UC3** "что менялось в `/payments` за 2 недели?" | `leaf_query_activity` | period + filter → events + Linear ticket descriptions via `event_links` |
| **UC4** "почему мы вынесли OAuth refresh на сервер?" | `leaf_get_decision` | topic → FTS → decision + reasoning excerpt + linked impl events |
| **UC5** "что мне знать до ревью PR #142?" | `leaf_query_activity` (scope=PR) | PR metadata + commits + linked Linear/Slack + absence_flag |
| **UC6** "что мы решили по бэкапам?" | `leaf_get_decision` | same as UC4. Slack-bot surface — Track 2 |

Track 1 acceptance gate (contract §13) requires manual smoke of these 5 UCs on user's own working data after D3 ship.

### 1.2 Privacy invariant carried forward

Bodies are stored on-device in SQLCipher (D1). FTS + link graph derive on-device (D2). Detector excerpts derive on-device (D3). **None of these surfaces leak into `presence_state.state_json`** — Track 2 will filter structured payloads (counts + buckets + structured metadata) without bodies. Privacy regression test in D3 extends D2's `RelayBodyLeakageTests` with 4 detector-excerpt assertions.

### 1.3 Contract amendment

Contract §5.2 specified `ALTER TABLE sessions ADD where_stopped_excerpt TEXT NULLABLE`. The `sessions` table does not exist in substrate (Derived Insights Engine computes sessions on-the-fly; no persisted aggregate). Creating `sessions` table only for WhereStopped output = scope creep. **D3 amends §5.2** (per §14 living-doc process): replaces with dedicated `where_stopped_log` table — minimal, focused. Patch text in §3.4 below.

---

## 2. Scope

### Входит

- **5 detectors** (pattern-based, zero LLM):
  - `DecisionDetector` — per-event regex over Slack/Linear/GitHub bodies → `decisions` table.
  - `OpenQuestionDetector` — per-event question-pattern match → `open_questions` table; resolution flow attaches `resolved_by_event_id` when a `DecisionDetector` hit shares context (Slack thread / Linear issue / GitHub PR).
  - `BlockerPatternDetector` — per-event "blocked on" / "stuck" / "заблокирован" pattern over Slack/Linear bodies → `blockers` table (kind = `pattern_blocked_on`).
  - `LinearStuckScanner` — idle-scheduler scan over events for open Linear issues without recent `linear_status_transition` → `blockers` (kind = `linear_stuck`).
  - `WhereStoppedDeriver` — idle-scheduler end-of-day digest → `where_stopped_log` row.
  - `AbsenceFlag` — **computed at query time** inside `QueryEngine.queryActivity` when scope contains a PR with `requested_reviewers`. No table.

- **5 new tables** in migration `M014_DetectionTables`:
  - `decisions(id PK, event_id UNIQUE → events, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms)` + index on detected_at_ms.
  - `open_questions(id PK, event_id UNIQUE → events, question_excerpt, alternatives_json, slack_thread_ts NULLABLE, linear_issue_ref NULLABLE, github_pr_ref NULLABLE, resolved_by_event_id NULLABLE → events, opened_at_ms, resolved_at_ms NULLABLE)` + 4 partial indexes (unresolved, slack, linear, pr).
  - `blockers(id PK, target_kind, target_ref, blocker_kind, blocker_excerpt NULLABLE, detected_by_event_id NULLABLE → events, started_at_ms, resolved_at_ms NULLABLE, resolved_by_event_id NULLABLE → events)` + partial unique index on (target_kind, target_ref) WHERE resolved_at_ms IS NULL + plain index on (target_kind, target_ref).
  - `where_stopped_log(id PK, generated_at_ms, anchor_event_id NULLABLE → events, excerpt, wip_signals_json)` + index on generated_at_ms.
  - `detector_offsets(detector_kind PK, cursor_event_id, last_run_at_ms)` — pre-seeded with 3 rows: `decision`, `open_question`, `blocker_pattern`.

- **`DetectorPipeline`** orchestrator (LeafCore public): two static methods — `runIncremental(moat:, in:)` (post-collector-flush, per-event cursor) and `runScheduled(moat:, nowMs:, in:)` (idle scheduler — LinearStuck + WhereStopped).

- **`DetectorMoat` injection struct** (LeafCore public, mirrors `LinkDerivers` boundary): protocol-typed fields for 6 detector roles + `.publicSubstrate` no-op default. `prodDetectorMoat()` factory in LeafCorePrivate.

- **6 detector protocols + 6 hit value types** (LeafCore public). All detection regex/threshold logic in LeafCorePrivate impls.

- **`QueryEngine`** (LeafCore public) — three methods composing events + decisions + open_questions + blockers + links + absence_flags + result-set budget enforcement.

- **3 high-level MCP tools** (LeafMCP) wired into `MCPServer`:
  - `leaf_query_activity(period, filter)` → `QueryActivityResponse`.
  - `leaf_get_decision(topic, period?)` → `GetDecisionResponse`.
  - `leaf_current_work()` → `CurrentWorkResponse`.

  Coexist with existing 12 low-level tools — total 15.

- **Result-set budget**: SQL `LIMIT 200` on events fetch + post-serialize byte budget 64KB; if overrun, drop oldest events one-by-one and re-serialize, set `truncation_note`.

- **Schema versioning**: `schema_version: "1.0"` top-level field in every QueryEngine response.

- **5 new `ShareEventTypeKey` registry entries** (default OFF, per contract §5.3): `decision_detected`, `open_question_opened`, `open_question_resolved`, `blocker_started`, `blocker_resolved`. Track 1 only registers — Track 2 wires into relay broadcast filter.

- **Privacy regression**: `RelayBodyLeakageTests` extended with 4 new tests (decision / open_question / blocker / where_stopped excerpts must not leak into `presence_state`) plus 1 cross-table walk test.

### НЕ входит (явно отложено)

- LLM Summarizer (Apple FM / Ollama / BYOK Anthropic / BYOK OpenAI) — future track. D3 returns structured JSON; AI client narrates.
- Embedding index / vector search — future track. FTS5 keyword search + link graph is the Track 1 substrate.
- AST symbol extraction from FSEvents — future track.
- AI-tool diversity beyond Claude Code (Cursor v1.7+ hooks, Windsurf, Continue.dev, Copilot, ChatGPT Desktop) — future track.
- Calendar deepening (`meeting_title`, `attendees[]`) — future track.
- `leaf_query_team` MCP tool + cross-device E2E summary distribution — Track 2.
- Slack-bot surface (`/leaf` slash command for UC6) — Track 2.
- Native UI redesign to surface decisions / open questions / blockers as first-class panels — post-Track-1 (decided after dogfooding D3).
- Layer C connectors (Notion, Figma, Jira, Gmail) — V1.5+.
- `sessions` table (contract §5.2 amended; see §3.4 below).
- Auto-mapping `team_members.github_login ↔ slack_user_id` — v1.1; D3 uses fuzz match against captured Slack identifiers (OQ-9 resolution).

---

## 3. Public API design

### 3.1 `M014_DetectionTables.swift`

Single migration, 5 tables, 8 indexes (1 plain + 4 partial unique/partial filtered + 3 plain). Pre-seeds `detector_offsets` with 3 rows for per-event detectors.

```sql
CREATE TABLE decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL UNIQUE
        REFERENCES events(id) ON DELETE CASCADE,
    topic_keywords_json TEXT NOT NULL,
    reasoning_excerpt TEXT NOT NULL,
    confidence REAL NOT NULL,
    detected_at_ms INTEGER NOT NULL
);
CREATE INDEX idx_decisions_detected_at ON decisions(detected_at_ms);

CREATE TABLE open_questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL UNIQUE
        REFERENCES events(id) ON DELETE CASCADE,
    question_excerpt TEXT NOT NULL,
    alternatives_json TEXT,
    slack_thread_ts TEXT,
    linear_issue_ref TEXT,
    github_pr_ref TEXT,
    resolved_by_event_id INTEGER
        REFERENCES events(id) ON DELETE SET NULL,
    opened_at_ms INTEGER NOT NULL,
    resolved_at_ms INTEGER
);
CREATE INDEX idx_open_questions_unresolved ON open_questions(resolved_at_ms)
    WHERE resolved_at_ms IS NULL;
CREATE INDEX idx_open_questions_slack ON open_questions(slack_thread_ts)
    WHERE slack_thread_ts IS NOT NULL;
CREATE INDEX idx_open_questions_linear ON open_questions(linear_issue_ref)
    WHERE linear_issue_ref IS NOT NULL;
CREATE INDEX idx_open_questions_pr ON open_questions(github_pr_ref)
    WHERE github_pr_ref IS NOT NULL;

CREATE TABLE blockers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_kind TEXT NOT NULL,
    target_ref TEXT NOT NULL,
    blocker_kind TEXT NOT NULL,
    blocker_excerpt TEXT,
    detected_by_event_id INTEGER
        REFERENCES events(id) ON DELETE SET NULL,
    started_at_ms INTEGER NOT NULL,
    resolved_at_ms INTEGER,
    resolved_by_event_id INTEGER
        REFERENCES events(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX idx_blockers_open ON blockers(target_kind, target_ref)
    WHERE resolved_at_ms IS NULL;
CREATE INDEX idx_blockers_target ON blockers(target_kind, target_ref);

CREATE TABLE where_stopped_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    generated_at_ms INTEGER NOT NULL,
    anchor_event_id INTEGER
        REFERENCES events(id) ON DELETE SET NULL,
    excerpt TEXT NOT NULL,
    wip_signals_json TEXT
);
CREATE INDEX idx_where_stopped_generated_at ON where_stopped_log(generated_at_ms);

CREATE TABLE detector_offsets (
    detector_kind TEXT PRIMARY KEY,
    cursor_event_id INTEGER NOT NULL DEFAULT 0,
    last_run_at_ms INTEGER NOT NULL DEFAULT 0
);
INSERT INTO detector_offsets (detector_kind) VALUES
    ('decision'), ('open_question'), ('blocker_pattern');
```

Registered in `Database.swift` migrator chain after M013: `migrator.registerMigration014DetectionTables()`.

### 3.2 Hit value types (LeafCore public, `LeafCore/Detection/HitTypes.swift`)

```swift
public struct DecisionHit: Sendable, Equatable {
    public let topicKeywords: [String]
    public let reasoningExcerpt: String
    public let confidence: Double
    public init(topicKeywords: [String], reasoningExcerpt: String, confidence: Double)
}

public struct OpenQuestionHit: Sendable, Equatable {
    public let questionExcerpt: String
    public let alternatives: [String]?
    public init(questionExcerpt: String, alternatives: [String]?)
}

public struct BlockerPatternHit: Sendable, Equatable {
    public let blockerExcerpt: String
    public init(blockerExcerpt: String)
}

public struct LinearStuckHit: Sendable, Equatable {
    public let issueRef: String
    public let lastStatusTransitionAtMs: Int64
    public init(issueRef: String, lastStatusTransitionAtMs: Int64)
}

public struct WhereStoppedOutput: Sendable, Equatable, Codable {
    public let excerpt: String
    public let wipSignals: WipSignals
    public let anchorEventID: Int64?
    public init(excerpt: String, wipSignals: WipSignals, anchorEventID: Int64?)
}

public struct WipSignals: Sendable, Equatable, Codable {
    public let commitWip: Bool
    public let ciFailing: Bool
    public let midEdit: Bool
    public init(commitWip: Bool, ciFailing: Bool, midEdit: Bool)
}

public struct SlackIdentifier: Sendable, Equatable {
    public let userID: String
    public let displayName: String?
    public let realName: String?
    public init(userID: String, displayName: String?, realName: String?)
}

public struct AbsenceFlag: Sendable, Equatable, Codable {
    public let prRef: String
    public let reviewerLogin: String
    public let designChoiceExcerpt: String
    public let lastThreadActivityMs: Int64
    public init(prRef: String, reviewerLogin: String,
                designChoiceExcerpt: String, lastThreadActivityMs: Int64)
}
```

### 3.3 Detector protocols (LeafCore public, `LeafCore/Detection/Protocols.swift`)

```swift
import GRDB

public protocol DecisionDetectorProtocol: Sendable {
    func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit?
}

public protocol OpenQuestionDetectorProtocol: Sendable {
    func detect(body: String, kind: BodyKind) -> OpenQuestionHit?
}

public protocol BlockerPatternDetectorProtocol: Sendable {
    func detect(body: String, kind: BodyKind) -> BlockerPatternHit?
}

public protocol LinearStuckScannerProtocol: Sendable {
    var stuckDays: Int { get }
    func currentlyStuck(in db: GRDB.Database, nowMs: Int64) throws -> [LinearStuckHit]
}

public protocol WhereStoppedDeriverProtocol: Sendable {
    var idleSeconds: Int { get }
    func derive(in db: GRDB.Database,
                sinceMs: Int64,
                untilMs: Int64) throws -> WhereStoppedOutput?
}

public protocol AbsenceMatcherProtocol: Sendable {
    /// Returns the matched Slack identifier or nil if no confident match.
    func match(githubLogin: String,
               slackIdentifiers: [SlackIdentifier]) -> SlackIdentifier?
}
```

### 3.4 `DetectorMoat` injection struct + public substrate (LeafCore public, `LeafCore/Detection/DetectorMoat.swift`)

```swift
public struct DetectorMoat: Sendable {
    public let decision: any DecisionDetectorProtocol
    public let openQuestion: any OpenQuestionDetectorProtocol
    public let blockerPattern: any BlockerPatternDetectorProtocol
    public let linearStuck: any LinearStuckScannerProtocol
    public let whereStopped: any WhereStoppedDeriverProtocol
    public let absence: any AbsenceMatcherProtocol

    public init(decision: any DecisionDetectorProtocol,
                openQuestion: any OpenQuestionDetectorProtocol,
                blockerPattern: any BlockerPatternDetectorProtocol,
                linearStuck: any LinearStuckScannerProtocol,
                whereStopped: any WhereStoppedDeriverProtocol,
                absence: any AbsenceMatcherProtocol)

    public static let publicSubstrate = DetectorMoat(
        decision: NoOpDecisionDetector(),
        openQuestion: NoOpOpenQuestionDetector(),
        blockerPattern: NoOpBlockerPatternDetector(),
        linearStuck: NoOpLinearStuckScanner(),
        whereStopped: NoOpWhereStoppedDeriver(),
        absence: ExactMatchAbsence()
    )
}

// All in same file:
public struct NoOpDecisionDetector: DecisionDetectorProtocol {
    public init() {}
    public func detect(body: String, kind: BodyKind, eventTsMs: Int64) -> DecisionHit? { nil }
}
public struct NoOpOpenQuestionDetector: OpenQuestionDetectorProtocol {
    public init() {}
    public func detect(body: String, kind: BodyKind) -> OpenQuestionHit? { nil }
}
public struct NoOpBlockerPatternDetector: BlockerPatternDetectorProtocol {
    public init() {}
    public func detect(body: String, kind: BodyKind) -> BlockerPatternHit? { nil }
}

public struct NoOpLinearStuckScanner: LinearStuckScannerProtocol {
    public init() {}
    public var stuckDays: Int { Int.max }   // effectively disabled
    public func currentlyStuck(in db: GRDB.Database, nowMs: Int64) throws -> [LinearStuckHit] { [] }
}

public struct NoOpWhereStoppedDeriver: WhereStoppedDeriverProtocol {
    public init() {}
    public var idleSeconds: Int { Int.max }
    public func derive(in db: GRDB.Database,
                       sinceMs: Int64, untilMs: Int64) throws -> WhereStoppedOutput? { nil }
}

public struct ExactMatchAbsence: AbsenceMatcherProtocol {
    public init() {}
    public func match(githubLogin: String,
                      slackIdentifiers: [SlackIdentifier]) -> SlackIdentifier? {
        slackIdentifiers.first(where: { $0.userID == githubLogin })
    }
}
```

`Database.write*` write paths get a defaulted parameter `detectors: DetectorMoat = .publicSubstrate`. Existing call sites compile unchanged (mirrors D2 `LinkDerivers` rollout).

### 3.5 `DetectorPipeline` (LeafCore public, `LeafCore/Detection/DetectorPipeline.swift`)

```swift
public enum DetectorPipeline {
    /// Per-event cursor pass. Called by Agent after writeEventsOffsetAndPresence.
    /// Reads new events since cursor, applies decision/open_question/blocker_pattern detectors,
    /// writes detector tables, advances cursors. Then runs open-question resolution flow:
    /// for each new decision event, find unresolved open_questions sharing context
    /// (Slack thread / Linear issue / GitHub PR) and set resolved_by_event_id.
    /// Bounded — partial indexes make resolution lookup cheap.
    public static func runIncremental(
        moat: DetectorMoat,
        in pool: DatabasePool
    ) throws

    /// Idle scheduler pass. Called by Agent timer when collector idle for moat.idleSeconds.
    /// Runs LinearStuckScanner (re-emit + auto-resolve) + WhereStoppedDeriver (1 row append).
    public static func runScheduled(
        moat: DetectorMoat,
        nowMs: Int64,
        in pool: DatabasePool
    ) throws
}
```

**Resolution flow** inside `runIncremental`, in the same `pool.write {}` transaction as detector writes (issued after detector INSERTs but before transaction commit):
1. Gather decision events emitted in this pass.
2. For each decision event E: derive context refs — `slack_thread_ts` via `json_extract(events.payload_json, '$.thread_ts')`; `linear_issue_refs` via `EventLinksStore.linksFrom(E.id)` filtered to `target_kind = 'linear_issue'`; `github_pr_refs` via same call filtered to `target_kind = 'github_pr'`.
3. `SELECT id FROM open_questions WHERE resolved_at_ms IS NULL AND (slack_thread_ts = ? OR linear_issue_ref IN (?...) OR github_pr_ref IN (?...))`.
4. `UPDATE open_questions SET resolved_by_event_id=E.id, resolved_at_ms=E.ts_ms WHERE id IN (matches)`.

All detector INSERTs + resolution UPDATEs land in one transaction; cursor advance happens last so failure in any step rolls back atomically.

### 3.6 `QueryEngine` (LeafCore public, `LeafCore/MCP/QueryEngine.swift`)

```swift
public struct QueryEngine: Sendable {
    public init(dbURL: URL,
                dbConfig: DatabaseConfig,
                dbEncryption: EncryptionOptions?,
                detectorMoat: DetectorMoat)

    public func queryActivity(period: PeriodSpec,
                              filter: String?) throws -> QueryActivityResponse

    public func getDecision(topic: String,
                            period: PeriodSpec?) throws -> GetDecisionResponse

    public func currentWork(nowMs: Int64) throws -> CurrentWorkResponse
}
```

Engine opens `DatabasePool` for read connection (same pattern as existing 12 tools). DetectorMoat is needed only for AbsenceMatcher (computed at query time inside `queryActivity`).

**Composition flow `queryActivity`**:
1. Resolve event-id set: filter present → `EventsFullTextStore.search(filter, period, limit: 200)`; else `events WHERE ts BETWEEN ? AND ? ORDER BY ts DESC LIMIT 200`.
2. Project events: decode `payload_json`, build `[ActivityEvent]` (event_id, ts, signal_type, bundle_id, event_kind, body_excerpt capped at N chars (moat — `BodyExcerptCap`), body_truncated).
3. `decisions WHERE event_id IN (eventIDs) OR detected_at_ms BETWEEN ? AND ?`.
4. `open_questions WHERE event_id IN (eventIDs) OR opened_at_ms BETWEEN ? AND ?`.
5. `blockers WHERE started_at_ms BETWEEN ? AND ? OR resolved_at_ms BETWEEN ? AND ?`.
6. `event_links WHERE from_event_id IN (eventIDs)`.
7. Absence flag computation: for each `gh_pr_*` event with `requested_reviewers_json` populated, fetch linked Slack thread events via `eventsLinkingTo(targetKind: "github_pr", targetRef: prRef)`, collect `SlackIdentifier`s from those events' payloads, call `detectorMoat.absence.match(reviewerLogin, slackIdentifiers)`. If `nil` (no match) → emit `AbsenceFlag` with most recent thread activity ts.
8. `JSONEncoder.encode(QueryActivityResponse(...))` → measure UTF-8 byte count → if > 64KB: drop oldest event from `events[]`, re-encode; repeat until ≤ 64KB; set `truncationNote = .init(reason: "byte_budget", originalCount: N0, returnedCount: N1, oldestReturnedTsMs: ...)`.
9. Return.

Similar composition for `getDecision` (FTS over `reasoning_excerpt` and topic match) and `currentWork` (latest event projection — bundle_id, branch from latest commit_pushed payload, file from latest AX window event, in-progress Linear ticket from latest issue_updated, last commit, current open_questions where resolved IS NULL, current blockers, latest where_stopped_log row if same-day).

### 3.7 Codable response types (LeafCore public, `LeafCore/MCP/QueryEngineTypes.swift`)

```swift
public struct PeriodSpec: Codable, Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
}

public struct QueryActivityResponse: Codable, Sendable {
    public let schemaVersion: String  // "1.0"
    public let period: PeriodSpec
    public let filter: String?
    public let events: [ActivityEvent]
    public let decisionsInPeriod: [DecisionView]
    public let openQuestions: [OpenQuestionView]
    public let blockers: [BlockerView]
    public let links: [LinkView]
    public let absenceFlags: [AbsenceFlag]
    public let truncationNote: TruncationNote?
}

public struct GetDecisionResponse: Codable, Sendable {
    public let schemaVersion: String
    public let decision: DecisionDetail?
    public let relatedEvents: [ActivityEvent]
    public let truncationNote: TruncationNote?
}

public struct CurrentWorkResponse: Codable, Sendable {
    public let schemaVersion: String
    public let currentApp: String?
    public let currentBranch: String?
    public let currentFile: String?
    public let inProgressLinearTicket: LinearTicketRef?
    public let lastCommit: CommitRef?
    public let currentOpenQuestions: [OpenQuestionView]
    public let currentBlockers: [BlockerView]
    public let whereStopped: WhereStoppedOutput?
}

public struct ActivityEvent: Codable, Sendable {
    public let eventID: Int64
    public let tsMs: Int64
    public let signalType: String
    public let bundleID: String?
    public let eventKind: String?
    public let bodyExcerpt: String?
    public let bodyTruncated: Bool
}

public struct DecisionView: Codable, Sendable {
    public let id: Int64
    public let eventID: Int64
    public let topicKeywords: [String]
    public let reasoningExcerpt: String
    public let confidence: Double
    public let detectedAtMs: Int64
}

public struct DecisionDetail: Codable, Sendable {
    public let decision: DecisionView
    public let originatingEvent: ActivityEvent
    public let linksToImplementation: [LinkView]
}

public struct OpenQuestionView: Codable, Sendable {
    public let id: Int64
    public let eventID: Int64
    public let questionExcerpt: String
    public let alternatives: [String]?
    public let slackThreadTS: String?
    public let linearIssueRef: String?
    public let githubPRRef: String?
    public let resolvedByEventID: Int64?
    public let openedAtMs: Int64
    public let resolvedAtMs: Int64?
}

public struct BlockerView: Codable, Sendable {
    public let id: Int64
    public let targetKind: String
    public let targetRef: String
    public let blockerKind: String
    public let blockerExcerpt: String?
    public let detectedByEventID: Int64?
    public let startedAtMs: Int64
    public let resolvedAtMs: Int64?
    public let resolvedByEventID: Int64?
}

public struct LinkView: Codable, Sendable {
    public let fromEventID: Int64
    public let linkKind: String
    public let targetKind: String
    public let targetRef: String
    public let confidence: Double
}

public struct LinearTicketRef: Codable, Sendable {
    public let issueRef: String
    public let title: String?       // from latest event payload
    public let stateName: String?
}

public struct CommitRef: Codable, Sendable {
    public let sha: String?
    public let message: String?
    public let branch: String?
    public let pushedAtMs: Int64?
}

public struct TruncationNote: Codable, Sendable {
    public let reason: String       // "byte_budget" | "event_count"
    public let originalCount: Int
    public let returnedCount: Int
    public let oldestReturnedTsMs: Int64?
}
```

### 3.8 3 MCP tool wires (LeafMCP, `LeafMCP/Tools/`)

`QueryActivityTool.swift`, `GetDecisionTool.swift`, `CurrentWorkTool.swift`. Each:

```swift
public struct QueryActivityTool: ToolHandler {
    public static let definition: ToolDefinition = .init(
        name: "leaf_query_activity",
        description: "Composes timeline + decisions + open questions + links + absence flags for a period, optionally filtered by FTS keyword. Returns structured JSON; AI client narrates.",
        inputSchema: /* JSON schema: period (required, {start_ms, end_ms}), filter (optional string) */
    )
    public func handle(_ params: ToolCallParams,
                       context: ToolContext) -> JSONRPCResult {
        // 1. Decode params into PeriodSpec + optional filter
        // 2. Open QueryEngine with injected dbURL/dbConfig/dbEncryption/detectorMoat
        // 3. Call queryEngine.queryActivity(period:filter:)
        // 4. JSONEncoder.encode(response)
        // 5. Wrap encoded bytes as JSONRPC tool result
    }
}
```

`MCPServer.swift` `MCPMain.main`:
- Instantiate `queryActivityTool / getDecisionTool / currentWorkTool` with same `dbURL/dbConfig/dbEncryption` as existing 12 tools.
- DetectorMoat for QueryEngine: `prodDetectorMoat()` под `#if LEAF_PROD`, else `.publicSubstrate`.
- Add 3 entries to `tools/list` definitions array (12 → 15).
- Add 3 entries to `tools/call` registry mapping (12 → 15).

### 3.9 Moat impls (LeafCorePrivate, `LeafCorePrivate/Prod/Detection/`)

All detection regex / thresholds / fuzz-match parameters live here. **No regex strings or threshold values in LeafCore.**

- `ProdDecisionDetector.swift` — pattern catalogue (en + ru), confidence per pattern category, excerpt window.
- `ProdOpenQuestionDetector.swift` — question-mark patterns, alternative connectors, alternatives extraction.
- `ProdBlockerPatternDetector.swift` — "blocked on" / "stuck on" / "заблокирован" / etc.
- `ProdLinearStuckScanner.swift` — `stuckDays` constant, status-filter logic (which Linear `WorkflowState.type` values count as stuck-eligible).
- `ProdWhereStoppedDeriver.swift` — `idleSeconds` constant, excerpt building (latest commit subject / Linear ticket title / file basename).
- `ProdAbsenceMatcher.swift` — Levenshtein threshold N, fuzz-match strategy (case-insensitive substring + Levenshtein over username / displayName / realName).
- `ProdDetectorMoat.swift` — factory that wires all 6 prod impls.
- `BodyExcerptCap.swift` — char cap for `ActivityEvent.bodyExcerpt` and `decisions.reasoning_excerpt`.

### 3.10 `ShareEventTypeKey` registry expansion

`Share/ShareEventTypeRegistry.swift`:

```swift
// MARK: - Phase Track-1 D3 — semantic detection facts (this commit)
case decisionDetected = "decision_detected"
case openQuestionOpened = "open_question_opened"
case openQuestionResolved = "open_question_resolved"
case blockerStarted = "blocker_started"
case blockerResolved = "blocker_resolved"
```

`ShareEventTypeDefaults.all` adds 5 entries with `defaultEnabled: false` (semantic facts must be opt-in per contract §5.3). Total registry 33 → 38.

### 3.11 Agent integration (`LeafAgent/Agent.swift`)

Two integration points:
1. **Post-collector-flush hook**: after `writeEventsOffsetAndPresence` returns, call `try DetectorPipeline.runIncremental(moat: detectorMoat, in: pool)`. Detector failure logs warning but does not throw — collector tick remains green even if detector pass errors (decoupled from primary write path). Detector errors must be observable in logs.
2. **Idle scheduler**: existing Agent timer extended with `runScheduled` invocation when no events for `detectorMoat.whereStopped.idleSeconds`. Single timer fires both LinearStuck and WhereStopped (sequential within one `pool.write {}`).

### 3.12 Contract amendment patch (separate PR to track contract)

Patch to `docs/superpowers/specs/2026-05-08-track-1-detection-substrate-contract.md` §5.2:

```diff
-| `sessions` | Add `wip_signals JSON`, `where_stopped_excerpt TEXT NULLABLE` | D3 |
+| `where_stopped_log` (NEW) | New table `(id PK, generated_at_ms, anchor_event_id NULLABLE → events, excerpt TEXT, wip_signals_json JSON)`. Replaces planned `sessions` extension — `sessions` table not present in substrate; D3 introduces dedicated log to keep scope minimal | D3 |
```

Submitted alongside D3 final commit, per §14 amendment process.

---

## 4. Test plan

Target: ~85-100 new tests, raising SPM count 1108 → ~1195-1210.

### 4.1 `M014DetectionTablesTests` (5 tests, LeafCoreTests)
- `testMigrationCreatesAllFiveTables` — sqlite_master assertions.
- `testPartialUniqueIndexBlockersOpen` — two open blockers same target = INSERT fails; resolved + open same target = OK.
- `testForeignKeyCascadeOnEventsDelete` — delete event → decisions/open_questions/blockers/where_stopped_log rows gone or SET NULL per spec.
- `testDetectorOffsetsPreSeeded` — 3 rows present after migration.
- `testIdempotentReRun` — running migration twice is no-op.

### 4.2 `DetectorMoatPublicSubstrateTests` (6 tests, LeafCoreTests)
- `testPublicSubstrate_DecisionReturnsNil`, `testPublicSubstrate_OpenQuestionReturnsNil`, `testPublicSubstrate_BlockerPatternReturnsNil`, `testPublicSubstrate_LinearStuckReturnsEmpty`, `testPublicSubstrate_WhereStoppedReturnsNil`, `testPublicSubstrate_ExactMatchAbsence`.

### 4.3 `DetectorPipelineIncrementalTests` (12 tests, LeafCoreTests, fixture moat)
- `testCursorAdvancesPastProcessedEvents`.
- `testInsertOrIgnoreOnReRun` — re-run with same cursor → no duplicate rows.
- `testDecisionWriteForEachBodyKind` (9 body kinds — parametric).
- `testOpenQuestionWriteCapturesContextRefs` — slack_thread_ts/linear_issue_ref/github_pr_ref populated from event payload + event_links.
- `testBlockerPatternWritePopulatesDetectedByEventID`.
- `testResolutionFlow_SlackThread` — open question + decision in same `thread_ts` → resolved.
- `testResolutionFlow_LinearIssue` — open question (Slack) + decision (Linear comment) linked via LEAF-NN → resolved.
- `testResolutionFlow_GitHubPR` — open question + decision linked via PR → resolved.
- `testResolutionFlow_NoMatch_LeavesUnresolved`.
- `testBackfillAfterCursorReset` — DELETE detector_offsets row → re-run processes from id=0.
- `testDetectorFailureDoesNotPoisonTransaction` — fixture moat throws → detector tables left untouched, cursor not advanced, write path remains green.

### 4.4 `DetectorPipelineScheduledTests` (5 tests, LeafCoreTests)
- `testLinearStuckEmitsBlocker`.
- `testLinearStuckAutoResolvesWhenStatusChanges` — issue with prior `linear_status_transition` event after blocker started → resolved_at_ms set.
- `testNoDoubleEmitOnSameRun`.
- `testWhereStoppedAppendsRowWithIdleAnchor`.
- `testWhereStoppedRespectsIdleSeconds` — events within idle window → no emit.

### 4.5 `QueryEngineQueryActivityTests` (10 tests, LeafCoreTests)
- `testWithFilter_RoutesThroughFTS`.
- `testWithoutFilter_ReturnsRecentEventsInPeriod`.
- `testSQLLimit200_HardCap`.
- `testByteBudget64KB_TrimsOldestEvents`.
- `testTruncationNoteOnTrim`.
- `testDecisionsInPeriodComposition`.
- `testOpenQuestionsComposition`.
- `testBlockersComposition`.
- `testLinksComposition`.
- `testAbsenceFlagComputation_FuzzMatchSucceedsAndFails`.

### 4.6 `QueryEngineGetDecisionTests` (5 tests, LeafCoreTests)
- `testTopicMatchUsesFTSOverReasoningExcerpts`.
- `testReturnsNilWhenNoMatch`.
- `testRelatedEventsViaLinks`.
- `testPeriodFilterScoping`.
- `testRanksByConfidenceTieBrokenByRecency`.

### 4.7 `QueryEngineCurrentWorkTests` (8 tests, LeafCoreTests)
- `testCurrentApp_FromLatestNSWorkspaceEvent`.
- `testCurrentBranch_FromLatestCommitPushed`.
- `testCurrentFile_FromLatestAXWindow`.
- `testInProgressLinearTicket_FromLatestIssueUpdated`.
- `testLastCommit_FromLatestCommitPushed`.
- `testCurrentOpenQuestions_FiltersResolved`.
- `testCurrentBlockers_FiltersResolved`.
- `testWhereStopped_LatestSameDayOnly`.

### 4.8 `MCPToolDefinitionTests` (3 tests, LeafMCPTests)
- `testQueryActivityToolDefinitionMatchesSchema`.
- `testGetDecisionToolDefinitionMatchesSchema`.
- `testCurrentWorkToolDefinitionMatchesSchema`.

### 4.9 `MCPToolHandleTests` (6 tests, LeafMCPTests, stub QueryEngine)
- `testQueryActivityHandleDispatch`.
- `testGetDecisionHandleDispatch`.
- `testCurrentWorkHandleDispatch`.
- `testParamDecodeErrors_QueryActivity` (missing period).
- `testParamDecodeErrors_GetDecision` (missing topic).
- `testJSONEncodingPreservesSchemaVersion`.

### 4.10 `RelayBodyLeakageTests` extension (5 tests)
- `testDecisionExcerpt_DoesNotLeakIntoPresenceState`.
- `testOpenQuestionExcerpt_DoesNotLeakIntoPresenceState`.
- `testBlockerExcerpt_DoesNotLeakIntoPresenceState`.
- `testWhereStoppedExcerpt_DoesNotLeakIntoPresenceState`.
- `testCrossDatabaseIsolation_DetectionTablesAndPresence` — sentinel walk через все detector tables в одной транзакции, assert presence_state.state_json clean.

### 4.11 `ShareEventTypeRegistryD3Tests` (2 tests, LeafCoreTests)
- `testFiveD3KeysRegistered_TotalIs38`.
- `testAllD3KeysDefaultOff`.

### 4.12 LeafCorePrivate moat tests (~30 tests, LeafCorePrivateTests)
- `ProdDecisionDetectorTests` — known-good corpus (en + ru), known-bad corpus, FP rate sanity.
- `ProdOpenQuestionDetectorTests` — alternative extraction, no-question rejection.
- `ProdBlockerPatternDetectorTests` — pattern coverage.
- `ProdLinearStuckScannerTests` — stuckDays threshold accuracy, status filter logic, auto-resolve.
- `ProdWhereStoppedDeriverTests` — excerpt construction, WIP signal detection.
- `ProdAbsenceMatcherTests` — Levenshtein threshold, substring match, no-match.
- `BodyExcerptCapTests`.
- `ProdDetectorMoatTests` — factory wires all 6.

### 4.13 Integration `D3EndToEndTests` (3 tests, LeafCoreTests)
- `testCollectorFlushTriggersDetectorPipeline_DecisionEmitted`.
- `testIdleSchedulerEmitsLinearStuckAndWhereStopped`.
- `testQueryActivityComposesAcrossAllDetectorOutputs`.

---

## 5. Test target conventions

- LeafCoreTests own all public-API tests (protocols, pipeline orchestration, QueryEngine composition, schema migration, registry).
- LeafCorePrivateTests own moat impl tests (regex catalogues, thresholds, fuzz matchers).
- LeafMCPTests own tool-definition + handle wiring tests with stub QueryEngine.
- All existing test fixtures (`weakDefaults` config, in-memory DB, raw event builders) reused — no new fixture infrastructure.
- Fixture detector moat impls (LeafCoreTests-private types) for pipeline tests — emit deterministic hits for sentinel bodies, return empty for everything else.

---

## 6. Acceptance criteria

D3 is **shipped to feature branch** when:

1. M014 migration created + registered + visible в `sqlite_master` post-migrate (5 tables, 8 indexes, 3 pre-seeded detector_offsets rows).
2. All 6 detector protocols + 6 hit value types + DetectorMoat injection + 6 NoOp/ExactMatch public-substrate impls in LeafCore.
3. DetectorPipeline `runIncremental` + `runScheduled` implemented with cursor advancement, idempotent re-run, and resolution flow.
4. QueryEngine + 3 MCP tool wires + Codable response types + 64KB byte-budget enforcement + truncation_note shape.
5. All 6 prod moat impls in LeafCorePrivate (regex / threshold / fuzz match — all values gitignored as part of LeafCorePrivate).
6. ProdDetectorMoat factory wires all 6.
7. Agent integration: post-flush incremental hook + idle scheduler invocation.
8. ShareEventTypeKey registry 33 → 38, all new keys default OFF.
9. RelayBodyLeakageTests extended with 5 new tests, all pass.
10. SPM tests pass (target ~1195-1210).
11. All xcodebuild schemes green per existing project convention (D2 baseline: 5/5 — `Leaf`, `LeafAgent`, `LeafCore`, `LeafCorePrivate`, `LeafMCP`).
12. Schema versioning `"1.0"` in every QueryEngine response (asserted in test).
13. Final shared-memory commit `docs(shared): Phase Track-1 D3 landed — current-state update`.
14. Contract §5.2 amendment patch ready as separate commit (or PR to contract file).

D3 is **NOT merged to `main`** — Track 1 acceptance gate (contract §13) requires manual smoke for UC1/UC3/UC4/UC5/UC6 on user's working data via MCP, then collective merge of stack `D1 → D2 → D3` + whitepaper sync per contract §12.

---

## 7. Out of scope для D3 (carry-overs)

- LLM Summarizer (future track).
- Embedding index / vector search (future track).
- AST symbol extraction (future track).
- AI-tool diversity beyond Claude Code (future track).
- Calendar deepening (future track).
- `leaf_query_team` MCP tool + Slack-bot surface (Track 2).
- Native UI panels for decisions / open questions / blockers (post-Track-1).
- `team_members.github_login` ↔ `slack_user_id` explicit mapping (v1.1) — D3 uses fuzz match only.
- `sessions` table creation (contract §5.2 amended).
- Track 1 acceptance gate manual smoke (post-D3 ship, separate session).
- Whitepaper sync (deferred until Track 1 ships per contract §12).

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Detector regex on hot collector path adds latency | Detectors run in **separate** transaction post-flush, not in `writeEventAndDerived`. Failure logged but does not block collector. |
| Resolution flow N+M query explosion | Bounded by partial indexes (`idx_open_questions_unresolved` + slack/linear/pr partials). Resolution iterates only unresolved questions × decision events emitted in current pass — typically 0..few. |
| Byte budget enforcement requires JSON re-encode | Acceptable cost — payloads ≤ 64KB ≤ 200 events ≤ small. Worst case: 200 → re-encode N times. Single-digit ms. |
| Fuzz matcher false positives | Levenshtein threshold tuned via LeafCorePrivate constant; tests assert known-good cases. False match → wrong "no reply from X" flag — annoying but not data corruption. |
| LinearStuckScanner status-filter logic dependent on Linear API state semantics | Status filter encapsulated in moat impl; if Linear evolves, change is local. |
| Migration M014 on populated DB | Migration only adds new tables — no ALTERs on existing tables. Forward-compatible. Tested via two-pass migration test. |
| Schema version drift between Track 1 / Track 2 | `schema_version` field present from day 1; Track 2 bumps via semver. AI clients can branch on version. |
| Detector pattern coverage gaps (en+ru) | Iterative — moat patterns expand as user encounters misses during dogfooding. No D3 ship-block on FP rate metric. |
| `where_stopped_log` dedup on overlapping idle windows | WhereStopped only writes if last entry is > 6h old — encoded in scheduled pass logic. Test asserts. |

---

## 9. Verification

Pre-implementation (validate substrate):

```bash
cd /Users/ddemidov/Desktop/Leaf/leaf
git status                             # confirm clean working tree on D2 baseline
swift test --package-path Packages/LeafCore 2>&1 | tail -5  # 1108 tests pass
xcodebuild -scheme Leaf -destination "platform=macOS" build 2>&1 | tail -10  # green
```

Post-implementation (acceptance):

```bash
# All SPM tests
swift test --package-path Packages/LeafCore 2>&1 | tail -10
# Expect: ~1195-1210 tests pass (1108 baseline + ~85-100 new D3 tests)

# All xcodebuild schemes green (5 schemes per D2 baseline)
for scheme in Leaf LeafAgent LeafCore LeafCorePrivate LeafMCP; do
    xcodebuild -scheme "$scheme" -destination "platform=macOS" build 2>&1 | tail -3
done

# Migration M014 visible in real DB
sqlite3 ~/Library/Application\ Support/Leaf/events.sqlite ".schema decisions open_questions blockers where_stopped_log detector_offsets"
# Expect: all 5 tables visible with declared columns + indexes

# 5 ShareEventTypeKey added (registry 38)
swift test --package-path Packages/LeafCore --filter ShareEventTypeRegistryD3Tests

# Privacy regression
swift test --package-path Packages/LeafCore --filter RelayBodyLeakageTests

# Manual MCP smoke
# Run agent + MCP server, attach Claude Code, invoke leaf_query_activity with period of last 7 days,
# verify structured JSON response with schema_version="1.0", events, decisions, open_questions,
# blockers, links, absence_flags, truncation_note (or null).
```

Track 1 acceptance gate (after D3 ship to feature branch — separate session):

```bash
# UC1: invoke leaf_query_activity in Claude Code with filter="auth"
# UC3: invoke leaf_query_activity with filter="payments" period=2 weeks
# UC4: invoke leaf_get_decision topic="OAuth refresh"
# UC5: invoke leaf_query_activity scope=PR-NN
# UC6: invoke leaf_get_decision topic="бэкапы"
# Each — coherent JSON within budget; Claude Code formulates sensible narrative within 3s.
```

---

## 10. Dependencies on prior phases

- **D1** — bodies (`payload.body`, `comment_bodies_json`, `thread_replies_json`, `messages_json`) consumed by detectors; `requested_reviewers_json` consumed by AbsenceFlag; `BodyKind` enum from D2 used by detector protocols.
- **D2** — `EventsFullTextStore.search` used by `QueryEngine.queryActivity` filter path and `getDecision` topic match; `EventLinksStore.eventsLinkingTo` used by AbsenceFlag and resolution flow; `LinearIDExtractor.extractAll` reused for `open_questions.linear_issue_ref` extraction; atomic `writeEventAndDerived` write path extended with optional detector hook (defaulted parameter).
- **Phase 4.6.B** — `linear_status_transition` event_kind consumed by `LinearStuckScanner` for "last status change" lookup.
- **Phase 4.7.A** — `linked_linear_id` metadata on commits consumed by resolution flow context derivation.
- **Phase 4.7.B** — `linked_github_pr_count` / `linked_slack_message_count` payload fields consumed by resolution flow PR-context derivation.
- **Phase 4.10.B** — AX `window_title` / `browser_url` payload fields consumed by `WhereStoppedDeriver` for current-file inference.
- **MCP server** (existing 12 tools) — pattern reused for tool definition + handle dispatch + DB injection; LeafMCPProtocol unchanged.

---

## 11. Commit decomposition

Sequential, atomic per commit, mirrors D2 discipline.

1. **`feat(db): M014 detection tables migration`** — migration file, registration, schema tests (5 tests). No detector logic, no pipeline.
2. **`feat(detection): hit types + detector protocols + DetectorMoat publicSubstrate`** — value types, protocols, NoOp impls, public substrate, public-substrate tests (6 tests).
3. **`feat(detection): DetectorPipeline.runIncremental + per-event detector writes`** — cursor advancement, INSERT OR IGNORE, integration into `writeEventsOffsetAndPresence` write path with defaulted moat parameter. Pipeline tests (12 tests).
4. **`feat(detection): open-question resolution flow`** — when decision emits, find shared-context unresolved questions and update. Resolution tests (3 of the pipeline tests).
5. **`feat(detection): DetectorPipeline.runScheduled — LinearStuck + WhereStopped`** — idle scheduler integration. Scheduled tests (5 tests).
6. **`feat(mcp): QueryEngine + Codable response types`** — engine struct, three methods, response types with schema_version. QueryEngine tests (10 + 5 + 8 = 23 tests).
7. **`feat(mcp): 3 high-level tool wires + MCPServer registration`** — tool definitions, handlers, `MCPMain` extension to register 3 tools. Tool tests (3 + 6 = 9 tests).
8. **`feat(share): registry +5 D3 keys (default OFF)`** — registry expansion, defaults entries, registry tests (2 tests).
9. **`feat(agent): post-flush incremental hook + idle scheduler invocation`** — Agent.swift integration, end-to-end tests (3 tests).
10. **`feat(detection): LeafCorePrivate prod moat impls + ProdDetectorMoat factory`** — 6 prod impls + factory + LeafCorePrivate moat tests (~30 tests). Files in gitignored `LeafCorePrivate/Prod/Detection/`.
11. **`test(privacy): assert detector excerpts do not leak into presence_state`** — RelayBodyLeakageTests extension (5 tests).
12. **`docs: Track 1 contract §5.2 amendment — where_stopped_log replaces sessions extension`** — single edit to contract file.
13. **`docs(shared): Phase Track-1 D3 landed — current-state update`** — final commit, current-state.md update.

Total ~13 commits. Subagent-driven sequential, fresh subagent per commit, two-stage review (spec compliance + code quality) after each. Mirrors D2 discipline.
