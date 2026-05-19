# Track-9 T2 — Linear INBOX feeder (`linear_comment_authored_to_me` + workspace_slug + `linear_issue_url`)

**Status:** APPROVED (Stage 3, awaiting user spec-review gate).
**Track-9 master design:** [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md).
**Branch:** `feature/track-9-substrate` (off `feature/phase-8-1-substrate` `e659b9e5`, currently at T1 tip `07a88bc0`).
**Ship classification:** Substrate-only, silent — UI без изменений, INBOX rows fade in только когда `linear_comment_authored_to_me` ShareEventTypeKey toggled ON в Privacy → Share Controls (default OFF per ADR-020).

---

## 1. Scope

**In scope:**

1. **New event_kind `linear_comment_authored_to_me`** — per-issue aggregate sibling to existing Phase 4.7.A `linear_comment_authored`. Emitted when other actors authored comments on viewer-touched issues during polling window.
2. **`LinearIssueSnapshot.incomingCommentCount: Int = 0`** — defaulted Sendable+Hashable preserved. Provider tallies comments where `user.id != viewer.id` during GraphQL parse.
3. **GraphQL extension** — `LeafPoll` viewer block adds `organization { urlKey }` scalar (zero new HTTP, piggyback existing call).
4. **`LinearCollector` workspace_slug cache** — actor-state field populated at first successful viewer fetch; persists across ticks until process restart.
5. **`presence_state.linear.workspace_slug`** — new JSON dict key on existing presence composite (no schema migration; `presence_state.state_json` JSON-blob shape).
6. **Parser-boundary `linear_issue_url` composition** — `https://linear.app/{workspace_slug}/issue/{issue_key}` payload field on new event_kind. Optional — omitted when slug not yet cached (cold first tick).
7. **`makeCommentToMeEvent(issue:periodEndMs:workspaceSlug:)`** — new RawEvent factory in `LinearCollector`, sibling to `makeCommentEvent`. Payload: `source, event_kind, issue_key, team_key, to_me_count_in_window, period_end_ms, linear_issue_url?`.
8. **`ShareEventTypeRegistry`** +1 entry: `linearCommentAuthoredToMe = "linear_comment_authored_to_me"`, default OFF. Registry 195 → 196.
9. **`ActivityFeedMapper.mapLinear`** +1 case for `linear_comment_authored_to_me` (mirror existing `linear_comment_authored` row shape, label differs).
10. **`EventKindIcon`** +1 SF Symbol mapping (`bubble.left.fill` candidate — confirm in plan).
11. **`DispatchCoverageTests` parity fence** — enumeration includes new event_kind across all 4 aspects (registry / defaults / icon / mapper allowlist).
12. **`ProdInsights+InboxItems.queryCommentsOnMyWork`** (LeafCorePrivate moat) — replace `return []` stub with Linear branch reading `linear_comment_authored_to_me` events from cutoff window. T3 later adds GitHub branch to same method.
13. **Sentinel-injection regression test** — `testEventBodyDoesNotLeakIntoPresenceState_LinearCommentToMe` in `RelayBodyLeakageTests` (public). Asserts `LEAKED_SENTINEL_LINEAR_T2` injected into `comments[i].body` never reaches `events.payload_json`, `presence_state.state_json`, or `linear_issue_url` field.

**Hard exclusion (out of T2 — carried to other phases):**

- **4.7.C router event INBOX routing** (`linear_assignee_changed` bucket=to_self, `linear_priority_changed` to_priority=1, `linear_label_added` label_name=blocked, `linear_project_update_authored` health=red) — **deferred to T8**. Reason: requires new `InboxKind` cases per scope lock #3 ("+5-7 new InboxKind cases" — T8 owns enum delta). See §1.1 deviation note.
- **@-mention detection** — Linear's `Notification` GraphQL query is the right path (server-side authoritative mention list); body-parse via `@<user-uuid>` regex is brittle (Linear's markup format may shift, no stable spec). Carry post-Track-9.
- **`linear_issue_url` on other linear_* event_kinds** (status transitions / priority / label / project updates) — T8 if deriver coverage demands.
- **Multi-workspace handling** — `integrations` table PK is `provider` single-row (Phase 4.7.A constraint at `Schema.swift:60`); T2 single workspace_slug assumption. Multi-workspace lift OQ post-Track-9.
- T5 YOU·NOW branch deriver / T6 hybrid pills / T7 WHERE STOPPED depth / T8 InboxKind expansion / T9 Analytics UI — separate phases per master design.
- UI surface changes (HomeView, InboxBlock, Settings) — none. Existing Privacy → Share Controls auto-lists new registry entry. No new toggle row implementation needed.

### 1.1 Deviation from Track-9 master spec §4 T2

Master spec line 159:
> Linear assignee→to_self / priority→Urgent / label→blocked / project health red — events captured Phase 4.7.C, add `ProdInsights+InboxItems` routing (no new event_kinds).

**T2 does not implement this routing.** Reason: existing `InboxKind` cases (`reviewRequest` / `commentOnMyWork` / `mention` / `openQuestion` / `blocker`) have no semantic fit for assignee/priority/label/project-health transitions. Mapping all four to `.commentOnMyWork` would corrupt the kind taxonomy. Master spec scope lock #3 (line 30) explicitly says **T8 owns** "+5-7 new InboxKind cases" — adding cases like `.assignedToMe` / `.priorityRaised` / `.labeledBlocked` / `.projectHealthDegraded` belongs there.

**T2 scope finalized:** Linear `linear_comment_authored_to_me` substrate + routing into existing `.commentOnMyWork` kind only. 4.7.C router events remain captured (Phase 4.7.C ship preserved) but unrouted until T8.

Master spec §4 T2 line 159 to be amended in T10 wrap; T2 spec is the authoritative implementation contract.

---

## 2. Decisions taken (Stage 2 brainstorm output)

| # | Question | Decision | Rationale |
|---|---|---|---|
| D-1 | `linear_comment_authored_to_me` shape | **Per-issue aggregate sibling event_kind** | Preserves Phase 4.7.A invariant (single row per issue per tick). `to_me_count_in_window: Int` payload field mirrors existing `count_in_window`. No per-comment row expansion. |
| D-2 | Filter rule | **`actor.id != viewer.id`** (incoming) on Phase 4.7.A-batched viewer-touched issues | Issues already filtered to assignedToMe∪createdByMe via existing GraphQL `filter:{or:[{activity:{...isMe:eq:true}},{creator:{isMe:eq:true}}]}`. Discriminator = comments by OTHERS within that batch. **Mentioned detection dropped** — see §1.1. |
| D-3 | `LinearIssueSnapshot` extension | Add **`incomingCommentCount: Int = 0`** trailing-default | Defaulted init param preserves all existing call-sites + Sendable+Hashable auto-synth. Mirror T1 `xcode_active_doc_changed.line` Optional-default precedent (zero blast radius). |
| D-4 | Provider tally | **Parser iteration in `ProdLinearGraphQLProvider`** (moat) — count comments where `userID != viewerID` | Provider already iterates per-comment user.id for existing `commentCountInWindow` filter. Mirror loop, opposite predicate. Single pass increment. Phase 4.7.A invariant: comments connection already includes `user { id }`. |
| D-5 | `linear_issue_url` payload field | **Composed at LinearCollector parser boundary** using cached workspace_slug | Single composition point. Optional (omitted when slug cached=nil, cold-tick degrade). Mirrors T1 D-4 Optional payload pattern. |
| D-6 | workspace_slug provisioning | **Piggyback `organization { urlKey }` into existing LeafPoll viewer block** | Zero new HTTP. Cached in `LinearCollector` actor state at first successful fetch. Persists across ticks until process restart. |
| D-7 | Cold-tick before workspace_slug cached | **Emit `linear_comment_authored_to_me` without `linear_issue_url` field** | Graceful degrade — sibling event_kind still ships; InboxItems deriver checks for url presence; rows without url get nil sourceURL (existing pattern). Single tick window. |
| D-8 | `presence_state.linear.workspace_slug` write | **Add to existing `buildLinearPresenceState` composite dict** | JSON dict key, no schema change. UI / downstream readers consume. |
| D-9 | ShareEventTypeKey delta | **+1 entry** `linearCommentAuthoredToMe`, default OFF | Confirmed by master spec §5.3 row T2. Registry 195 → 196. |
| D-10 | `ProdInsights+InboxItems.queryCommentsOnMyWork` routing | **Replace `return []` stub with Linear branch** (LeafCorePrivate moat) | T3 later adds GitHub branch to same method. (kind, issue_key) aggregation across ticks via SUM(to_me_count_in_window). |
| D-11 | InboxItem field mapping | `kind=.commentOnMyWork` / `severity=.muted` / `title="<issue_key>"` / `sourceMeta="Linear · <issue_key>"` / `sourceURL=URL(linear_issue_url)` (or nil) / `aggregatedCount=SUM` / `createdAtMs=MAX(period_end_ms)` | Severity `.muted` — comments informational, not urgent (mockup §3 INBOX styling). `.warn`/`.danger` reserved for blockers/questions. Title surfaces issue key, sourceMeta gives provider context. |
| D-12 | 4.7.C router event routing | **Deferred to T8** — see §1.1 | T8 owns InboxKind expansion. |
| D-13 | Sentinel-injection test | **1 dedicated test** `testEventBodyDoesNotLeakIntoPresenceState_LinearCommentToMe` in `RelayBodyLeakageTests` | Inject `LEAKED_SENTINEL_LINEAR_T2` into `comments[i].body`. Assert sentinel absent from `events.payload_json`, `presence_state.linear.state_json`, AND `linear_issue_url` field. Pattern parity with T1 + Track-3 D1..D3 + Track-6 P1..P5. |
| D-14 | DispatchCoverageTests parity fence | **Update existing fence** (test #20 — Linear enumeration) — add `linear_comment_authored_to_me` to all 4 aspect arrays | No new fence test, extend existing. |
| D-15 | EventKindIcon | **+1 SF Symbol mapping** `bubble.left.fill` | Confirm icon choice in plan vs. `text.bubble` / `quote.bubble`. |
| D-16 | ActivityFeedMapper | **+1 case in `mapLinear` switch** — same row shape as `linear_comment_authored`, label "Comment to you (N)" vs existing "Your comments (N)" | Mirror existing Linear comment row precedent for cell layout. |
| D-17 | Migrations | **0 new SQLCipher migrations.** Total tables preserved (M001-M018 + M024 + M026 + M027 = 31 baseline) | Master spec §5.2: M028 is T7's where_stopped_log column addition, not T2. |
| D-18 | MCP tools | **0 new tools.** | Confirmed by master spec §5.5. |
| D-19 | Settings UI | **None.** Privacy → Share Controls auto-lists registry entry. | No code change in `SystemObserversSettingsSection` / `PrivacyControlsSection`. |
| D-20 | Tests in public LeafCoreTests vs LeafCorePrivateTests moat | Sentinel-injection test → **public** `RelayBodyLeakageTests`. Provider classification logic test (`ProdLinearGraphQLProvider` mock GraphQL response → asserts `incomingCommentCount`) → **moat** `LeafCorePrivateTests`. Snapshot round-trip + InboxItem assembly tests → **moat** (`ProdInsights+InboxItems` lives there). Collector emission test (no moat dep) → **public** `LinearCollectorTests`. | Pattern parity with T1 split. |

---

## 3. Architecture

### 3.1 Component map

```
Agent process
├── LinearCollector (LeafCore/Collectors, public)
│   ├── actor state: workspaceSlug: String? — cached at first successful viewer fetch
│   ├── existing flow:
│   │   ├── Provider.fetch(since:) → LinearBatch { issues, transitions, ... }
│   │   ├── issues.filter { commentCountInWindow > 0 }.map { makeCommentEvent(...) }
│   │   └── buildLinearPresenceState(...) → presence_state.linear write
│   ├── NEW: issues.filter { incomingCommentCount > 0 }.map { makeCommentToMeEvent(...) }
│   │   └── payload includes "linear_issue_url" iff workspaceSlug != nil
│   └── NEW: workspaceSlug populated from batch.workspaceSlug + written to presence dict
│
├── ProdLinearGraphQLProvider (LeafCorePrivate moat)
│   ├── LeafPoll query: viewer { id ... } — ADD `organization { urlKey }`
│   ├── parser: iterate comments, increment commentCountInWindow when user.id == viewerID
│   └── NEW: same loop, increment incomingCommentCount when user.id != viewerID
│
MenuBarApp / MCP processes (read-only)
└── ProdInsights+InboxItems.queryCommentsOnMyWork (LeafCorePrivate moat)
    ├── existing: return []
    └── NEW: SQL → fetch linear_comment_authored_to_me events from cutoff window
        ├── (kind, issue_key) aggregation → SUM(to_me_count_in_window), MAX(period_end_ms)
        └── synth InboxItem with sourceURL = URL(linear_issue_url) or nil
```

### 3.2 Data flow

```
LinearBatch (LinearGraphQLProvider output)
├── workspaceSlug: String?       ← NEW, from organization { urlKey }
├── viewerId: String              ← existing
└── issues: [LinearIssueSnapshot]
    └── per-issue: incomingCommentCount: Int   ← NEW (defaulted)

LinearCollector.run(...)
├── if let slug = batch.workspaceSlug { self.workspaceSlug = slug }
├── for each issue where incomingCommentCount > 0:
│   ├── compose linearIssueURL: workspaceSlug != nil ? "https://linear.app/{slug}/issue/{key}" : nil
│   └── emit RawEvent(event_kind: "linear_comment_authored_to_me", payload: { ..., linear_issue_url?: })
└── buildLinearPresenceState(..., workspaceSlug: self.workspaceSlug)
    └── linearPresence["workspace_slug"] = self.workspaceSlug ?? ""
```

### 3.3 GraphQL extension (LeafPoll viewer block)

Existing (ProdLinearGraphQLProvider.swift:~1581):
```graphql
viewer {
  id
  assignedIssues(...)
  teams(first: 5) { ... }
  initiatives(first: 10) { ... }
}
```

After T2:
```graphql
viewer {
  id
  organization { urlKey }   # NEW — single scalar, ~1 complexity point
  assignedIssues(...)
  teams(first: 5) { ... }
  initiatives(first: 10) { ... }
}
```

`LinearTokenResponse.swift:43` already references the `viewer { id organization { id name urlKey } }` shape (for OAuth response parsing). Extension to LeafPoll is the polling-tick mirror — cached at provider boundary.

**Cost:** +1 complexity point per LeafPoll page (within existing 75-pt budget cap; trivial).

### 3.4 Classification logic (ProdLinearGraphQLProvider)

Current `commentCountInWindow` tally (Phase 4.7.A):

```swift
var myComments = 0
for comment in issueNode.comments.nodes {
    if let createdAt = parseISO8601(comment.createdAt),
       createdAt > effectiveSince,
       comment.user.id == viewerID {
        myComments += 1
    }
}
// snapshot.commentCountInWindow = myComments
```

T2 extension — same loop, second predicate:

```swift
var myComments = 0
var incomingComments = 0
for comment in issueNode.comments.nodes {
    guard let createdAt = parseISO8601(comment.createdAt),
          createdAt > effectiveSince else { continue }
    if comment.user.id == viewerID {
        myComments += 1
    } else {
        incomingComments += 1
    }
}
// snapshot.commentCountInWindow = myComments       (existing semantic preserved)
// snapshot.incomingCommentCount = incomingComments (NEW)
```

Single-pass, zero new HTTP, zero new GraphQL fragments.

### 3.5 `linear_issue_url` composition (LinearCollector)

```swift
static func makeCommentToMeEvent(
    issue: LinearIssueSnapshot,
    periodEndMs: Int64,
    workspaceSlug: String?
) -> RawEvent {
    var payload: [String: String] = [
        "source": "linear",
        "event_kind": "linear_comment_authored_to_me",
        "issue_key": issue.issueKey,
        "team_key": issue.teamKey,
        "to_me_count_in_window": String(issue.incomingCommentCount),
        "period_end_ms": String(periodEndMs),
    ]
    if let slug = workspaceSlug, !slug.isEmpty {
        payload["linear_issue_url"] = "https://linear.app/\(slug)/issue/\(issue.issueKey)"
    }
    return RawEvent(
        timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
        signalType: .action,
        bundleID: nil,
        payload: payload
    )
}
```

**ADR-010 boundary:** `linear_issue_url` composed ONLY from `workspace_slug` (org metadata, public-safe) + `issue_key` (self-authored label, public-safe). NEVER comments/body/title/description text flows into URL. Sentinel-injection test guards.

### 3.6 InboxItem assembly (ProdInsights+InboxItems moat)

```swift
private func queryCommentsOnMyWork(cutoffMs: Int64) throws -> [InboxItem] {
    let rows: [(String, Int, Int64, String?)] = try database.readSQL { db in
        try Row.fetchAll(
            db,
            sql: """
                SELECT
                    json_extract(payload_json, '$.issue_key') AS issue_key,
                    SUM(CAST(json_extract(payload_json, '$.to_me_count_in_window') AS INTEGER)) AS total,
                    MAX(CAST(json_extract(payload_json, '$.period_end_ms') AS INTEGER)) AS latest_ms,
                    MAX(json_extract(payload_json, '$.linear_issue_url')) AS issue_url
                FROM events
                WHERE signal_type = 'action'
                  AND json_extract(payload_json, '$.event_kind') = 'linear_comment_authored_to_me'
                  AND CAST(json_extract(payload_json, '$.period_end_ms') AS INTEGER) >= ?
                GROUP BY json_extract(payload_json, '$.issue_key')
                ORDER BY latest_ms DESC
                """,
            arguments: [cutoffMs]
        ).map { /* tuple */ }
    }
    return rows.map { (key, total, latestMs, urlStr) in
        InboxItem(
            id: "linearCommentToMe:\(key)",
            kind: .commentOnMyWork,
            severity: .muted,
            title: key,
            sourceMeta: "Linear · \(key)",
            sourceURL: urlStr.flatMap { URL(string: $0) },
            aggregatedCount: total,
            createdAtMs: latestMs
        )
    }
}
```

`json_extract` pattern matches sibling moat files (T1 `ProdInsights+LastCommit.swift` precedent — `json_extract(payload_json, '$.event_kind') = 'gh_commit_pushed'`).

### 3.7 ActivityFeedMapper extension

`Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift` mapLinear switch gets new case:

```swift
case "linear_comment_authored_to_me":
    let key = payload["issue_key"] ?? "?"
    let count = Int(payload["to_me_count_in_window"] ?? "0") ?? 0
    return ActivityFeedEntry(
        timestamp: timestamp,
        icon: EventKindIcon.icon(for: "linear_comment_authored_to_me"),
        label: "Linear: comment to you on \(key) (\(count))",
        category: .layerB,
        eventKind: "linear_comment_authored_to_me"
    )
```

Allowlist-only payload reads (`issue_key`, `to_me_count_in_window`) — no `linear_issue_url` read (URL stays in event row, not surfaced in Activity tab).

---

## 4. Implementation surface

### 4.1 Files touched

**Public (committed to leaf repo):**

| File | Change | Approx LOC |
|---|---|---|
| `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearGraphQLProvider.swift` | Add `LinearIssueSnapshot.incomingCommentCount: Int = 0` field + init param + `LinearBatch.workspaceSlug: String?` field | +6 |
| `Packages/LeafCore/Sources/LeafCore/Collectors/LinearCollector.swift` | Actor state `workspaceSlug: String?`; new `makeCommentToMeEvent(...)` factory; emission loop addition; `buildLinearPresenceState` extension to write `workspace_slug` dict key | +45 |
| `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | +1 enum case `linearCommentAuthoredToMe = "linear_comment_authored_to_me"` | +1 |
| `Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift` | +1 case in `mapLinear` switch | +12 |
| `Packages/LeafCore/Sources/LeafCore/Insights/EventKindIcon.swift` | +1 SF Symbol mapping | +1 |
| `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` | +1 sentinel test | +45 |
| `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` | +1 entry in Linear enumeration arrays (all 4 aspects) | +4 |
| `Packages/LeafCore/Tests/LeafCoreTests/LinearCollectorTests.swift` (or similar) | +2 tests: emission round-trip + workspace_slug graceful-degrade | +60 |

**LeafCorePrivate moat (local, gitignored, not pushed):**

| File | Change | Approx LOC |
|---|---|---|
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/ProdLinearGraphQLProvider.swift` | LeafPoll viewer block `+organization { urlKey }`; parser tallies `incomingCommentCount`; `LinearBatch.workspaceSlug` assignment | +20 |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+InboxItems.swift` | Replace `queryCommentsOnMyWork` stub `return []` with SQL query + InboxItem assembly | +35 (vs −1 stub) |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/ProdLinearGraphQLProviderTests.swift` | +2 tests: mock GraphQL response → assert `incomingCommentCount` tally + `workspaceSlug` parse | +50 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsInboxItemsTests.swift` | +2 tests: fixture DB → assert (kind, issue_key) aggregation + sourceURL synthesis | +60 |

**Estimated total LOC delta:** ~340 lines (public ~170 + moat ~170), 0 file deletions, 0 renames.

### 4.2 Atomic commit decomposition (preview — finalized in Stage 4 plan)

Tentative 8 commits (1 spec docs + 7 atomic feat/test):

1. `docs(track-9-T2): spec — Linear INBOX feeder` (this file)
2. `feat(track-9-T2): LinearIssueSnapshot +incomingCommentCount field` (defaulted, snapshot round-trip test)
3. `feat(track-9-T2): LinearBatch +workspaceSlug field` (defaulted, batch round-trip test)
4. `feat(track-9-T2): ProdLinearGraphQLProvider organization{urlKey} + classification` (moat, local tests)
5. `feat(track-9-T2): LinearCollector workspaceSlug cache + presence dict write` (collector round-trip)
6. `feat(track-9-T2): LinearCollector makeCommentToMeEvent factory + emission` (public tests, sentinel)
7. `feat(track-9-T2): ShareEventTypeRegistry +1 + ActivityFeedMapper +1 + EventKindIcon +1 + DispatchCoverageTests` (parity fences green)
8. `feat(track-9-T2): ProdInsights+InboxItems queryCommentsOnMyWork Linear branch` (moat, local InboxItem assembly test)
9. `test(track-9-T2): sentinel-injection regression test in RelayBodyLeakageTests`

Finalized commit order in Stage 4 plan (`writing-plans` skill).

---

## 5. Tests

### 5.1 Provider classification (moat)

```swift
// ProdLinearGraphQLProviderTests.swift (moat)
func test_incomingCommentCount_tallyByActorMismatch() throws {
    let viewerID = "viewer-uuid-AAA"
    let mockResponse = mockLinearResponseWithComments([
        ("comment1", viewerID, "1715900000000"),     // my comment
        ("comment2", "other-user-BBB", "1715900100000"), // incoming
        ("comment3", "other-user-CCC", "1715900200000"), // incoming
    ])
    let batch = try parser.parseLeafPoll(mockResponse, viewerID: viewerID, effectiveSince: 1715800000000)
    let issue = batch.issues.first!
    XCTAssertEqual(issue.commentCountInWindow, 1)    // viewer's
    XCTAssertEqual(issue.incomingCommentCount, 2)    // others'
}

func test_workspaceSlug_parsedFromOrganization() throws {
    let mockResponse = mockLinearResponseWithOrg(urlKey: "my-team")
    let batch = try parser.parseLeafPoll(mockResponse, viewerID: "v1", effectiveSince: 0)
    XCTAssertEqual(batch.workspaceSlug, "my-team")
}
```

### 5.2 Collector emission (public)

```swift
// LinearCollectorTests.swift (public)
func test_makeCommentToMeEvent_payloadShape() {
    let issue = LinearIssueSnapshot(
        issueKey: "LEA-200", title: "X", status: "In Progress",
        project: "", teamKey: "LEA", updatedAtMs: 1715900000000,
        incomingCommentCount: 3
    )
    let event = LinearCollector.makeCommentToMeEvent(
        issue: issue, periodEndMs: 1715900500000, workspaceSlug: "my-team"
    )
    XCTAssertEqual(event.payload["event_kind"], "linear_comment_authored_to_me")
    XCTAssertEqual(event.payload["issue_key"], "LEA-200")
    XCTAssertEqual(event.payload["to_me_count_in_window"], "3")
    XCTAssertEqual(event.payload["linear_issue_url"], "https://linear.app/my-team/issue/LEA-200")
}

func test_makeCommentToMeEvent_omitsURL_whenSlugNil() {
    let issue = LinearIssueSnapshot(/* ... */, incomingCommentCount: 2)
    let event = LinearCollector.makeCommentToMeEvent(
        issue: issue, periodEndMs: 0, workspaceSlug: nil
    )
    XCTAssertNil(event.payload["linear_issue_url"])
}
```

### 5.3 InboxItem assembly (moat)

```swift
// ProdInsightsInboxItemsTests.swift (moat)
func test_queryCommentsOnMyWork_LinearBranch_aggregatesByIssueKey() throws {
    // Insert 3 linear_comment_authored_to_me events for LEA-200 + 1 for LEA-201
    // Expect 2 InboxItems: LEA-200 aggregatedCount=SUM, LEA-201 aggregatedCount=1
}

func test_queryCommentsOnMyWork_sourceURL_synthesized_fromPayload() throws {
    // Insert event with linear_issue_url payload
    // Expect InboxItem.sourceURL == URL("https://linear.app/foo/issue/LEA-200")
}
```

### 5.4 Sentinel-injection regression (public)

```swift
// RelayBodyLeakageTests.swift
func testEventBodyDoesNotLeakIntoPresenceState_LinearCommentToMe() throws {
    let db = try Database.openForWrite(...)
    let sentinel = "LEAKED_SENTINEL_LINEAR_T2"
    let bodyText = "padding-prefix-" + sentinel + "-padding-suffix"
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    // Construct event mirroring linear_comment_authored_to_me shape with sentinel-bearing
    // payload positions that the parser MIGHT (incorrectly) populate
    let event = RawEvent(
        timestamp: Date(),
        signalType: .action,
        bundleID: nil,
        payload: [
            "source": "linear",
            "event_kind": "linear_comment_authored_to_me",
            "issue_key": "LEA-200",
            "team_key": "LEA",
            "to_me_count_in_window": "1",
            "period_end_ms": String(nowMs),
            "linear_issue_url": "https://linear.app/my-team/issue/LEA-200",
            // attempt-leak slots:
            Schema.EventPayloadKeys.body: bodyText,
        ]
    )
    let presenceState: [String: Any] = ["workspace_slug": "my-team", "started_issues_count": 1]
    try db.writeEventsOffsetAndPresence(
        [event],
        offset: makeOffset(...),
        presence: (provider: .linear, state: presenceState, derivedMode: nil),
        nowMs: nowMs
    )

    try db.readSQL { rawDB in
        let row = try Row.fetchOne(rawDB, sql: "SELECT state_json FROM presence_state WHERE provider='linear'")
        let stateJSON = (row?["state_json"] as String?) ?? ""
        XCTAssertFalse(stateJSON.isEmpty, "presence_state.linear row should exist")
        XCTAssertFalse(
            stateJSON.contains(sentinel),
            "T2 sentinel '\(sentinel)' MUST NOT appear in presence_state.linear.state_json")

        // Also verify linear_issue_url field in events row is sanitized
        let eventRow = try Row.fetchOne(rawDB, sql: "SELECT payload_json FROM events WHERE json_extract(payload_json, '$.event_kind') = 'linear_comment_authored_to_me'")
        let payloadJSON = (eventRow?["payload_json"] as String?) ?? ""
        // Find linear_issue_url field and assert sentinel absent from its value
        // (URL field is structured — workspace_slug + issue_key only)
        XCTAssertTrue(payloadJSON.contains("linear_issue_url"))
        // Extract just the url value and verify sanitization
        // (full assertion: sentinel-free in url field — body field may still carry sentinel
        // but the URL field must be sanitized)
        // Implementation pattern matches RelayBodyLeakageTests:42-75 Linear test
    }
}
```

### 5.5 DispatchCoverageTests parity fence

Existing test #20 enumerates Linear event_kinds × 4 aspects (registry / defaults / icon / mapper). Add `"linear_comment_authored_to_me"` to all 4 arrays. Test asserts every kind appears in every aspect — fails if T2 forgets any one.

### 5.6 Per-step TDD discipline

Per `superpowers:test-driven-development`:
1. Write test (red).
2. Run test, confirm fails for the right reason.
3. Implement minimum code to pass.
4. Run test, confirm passes.
5. Commit.

Sequential per commit decomposition (no batching).

---

## 6. ADR-010 privacy walkback

Per master spec §6 invariant #4 (T2):
> `linear_issue_url` (T2) — composed URL from `workspace_slug` + `issue_key`; no body / title / mention text. Sentinel injects `LEAKED_SENTINEL_LINEAR_T2` into adjacent comment body; assert URL field never contains body fragment.

T2 walkback enumeration:

1. **`linear_issue_url`** — composed from 2 sources only: cached `workspaceSlug` (from `organization.urlKey`, org metadata) + `issue.issueKey` (self-authored, public-safe per LinearIssueSnapshot doc line 246-247). Composition function is pure string interpolation with hard-coded URL prefix `https://linear.app/`. No `comments[].body`, `title`, `description`, `mention text` ever reaches composition. Sentinel test §5.4 guards.

2. **`incomingCommentCount` payload field (`to_me_count_in_window`)** — integer count, no text leak surface.

3. **`workspace_slug` in `presence_state.linear`** — string slug, public org metadata. Same field shipped in LinearTokenResponse for Settings UI display (line 42-44 doc). Not new privacy surface, just new placement.

4. **Provider classification loop (incomingCommentCount tally)** — reads only `comment.user.id` (UUID, opaque to InboxItem layer). No body/title text read during tally. ADR-010 boundary preserved.

5. **`ProdInsights+InboxItems.queryCommentsOnMyWork` Linear branch** — reads only `issue_key`, `to_me_count_in_window`, `period_end_ms`, `linear_issue_url` payload fields. Does NOT read `Schema.EventPayloadKeys.body` (D1 FTS body field) or any other body capture. Sentinel test §5.4 confirms.

**Privacy walkback grep AC (Stage 7 gate):**
```
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body" \
  Packages/LeafCore/Sources/LeafCore/Collectors/LinearCollector.swift \
  Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearGraphQLProvider.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift
# Expected: 0 hits in T2-touched file scope
```

---

## 7. Verification gates (Stage 7 explicit checks)

Per `superpowers:verification-before-completion`:

1. **5/5 xcodebuild schemes Debug build SUCCESS** (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. **SPM tests green** — XCTest + Swift-Testing combined, 0 failures, recorded skipped count vs. T1 baseline 2869 (expected net new ~9: 2 provider + 2 collector + 2 inbox + 1 snapshot round-trip + 1 sentinel + 1 dispatch fence).
3. **`just check-tokens` 3-tier clean** — BASE + MIGRATION + RETIRED.
4. **Privacy walkback grep** (§6 AC) — 0 hits.
5. **Sentinel-injection test** `testEventBodyDoesNotLeakIntoPresenceState_LinearCommentToMe` green.
6. **DispatchCoverageTests** #20 still green with new entry.
7. **HomeView.swift LOC unchanged** (T2 substrate-only, no UI touch).
8. **ShareEventTypeRegistry count** 195 → 196 (verified by `grep -c "case linear" ShareEventTypeRegistry.swift` or equivalent).
9. **`presence_state.linear.state_json` contains `workspace_slug` field** after fresh poll tick (integration smoke).
10. **Privacy substrate purity** — zero new SQLCipher migrations (`git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/DB/Migrations*.swift` empty), zero new event_kinds beyond the listed 1 (`linear_comment_authored_to_me`), zero new MCP tools (`git diff feature/track-9-substrate -- LeafMCP/` empty).

---

## 8. Out of scope (carry list)

| Item | Phase | Reason |
|---|---|---|
| 4.7.C router event INBOX routing (assignee→self / priority→Urgent / label→blocked / project health red) | T8 | Requires new `InboxKind` enum cases — T8 owns delta per scope lock #3. |
| `linear_issue_url` on other linear_* event_kinds (status / priority / label / project updates) | T8 (if needed) | T8 InboxSourceURLDeriver may synthesize at deriver boundary instead. |
| @-mention detection | post-Track-9 | Linear `Notification` GraphQL query — separate phase. |
| Multi-workspace handling | OQ post-Track-9 | `integrations` table PK constraint (single-row-per-provider). |
| Settings UI explicit "Linear comments to me" toggle row | Privacy → Share Controls auto-list | Existing auto-render of registry entries covers. |
| MCP `get_linear_inbox_to_me` tool | Future | No demand articulated. |
| Real-Linear smoke (production workspace, OAuth flow, real polling tick) | T10 wrap | Smoke happens at Track-9 substrate-branch → main merge ship-prep. |
| `recentActivity` orphaned fetch cleanup | T10 | Phase 8.8 carry C-24. |

---

## 9. References

- Track-9 master design: [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md).
- Track-9 T1 spec: [`2026-05-19-track-9-T1-collector-payload-extensions.md`](./2026-05-19-track-9-T1-collector-payload-extensions.md).
- Master Track-8 spec: [`2026-05-18-track-8-home-ux-design.md`](./2026-05-18-track-8-home-ux-design.md) (§9.1 carry catalog).
- ADR-010 walkback discipline: `RelayBodyLeakageTests` Track-3 D1..D3 + Track-6 P1..P5 + Track-4 S1..S4 + Track-9 T1 lineage.
- Architecture: `.claude/shared/architecture.md`.
- Conventions / 8-stage workflow: `.claude/shared/conventions.md`.

---

## 10. Open questions resolved this session

| OQ | Resolution |
|---|---|
| OQ-T2-1: Per-issue aggregate vs per-comment emission for `_to_me`? | Per-issue aggregate (D-1). Preserves 4.7.A invariant. |
| OQ-T2-2: Where to source workspace_slug? | Piggyback `organization { urlKey }` into existing LeafPoll viewer block (D-6). Zero new HTTP. |
| OQ-T2-3: URL composition — parser vs deriver? | Parser-side (D-5). Reuses cached slug, deriver consumes structured field. |
| OQ-T2-4: 4.7.C router events routing in T2? | NO — deferred to T8 (D-12). InboxKind expansion is T8's contract. |
| OQ-T2-5: @-mention detection in T2? | NO — body-parse brittle (D-2). Linear's `Notification` query post-Track-9. |
| OQ-T2-6: Schema migration for workspace_slug? | NO — `presence_state.state_json` JSON dict (D-8). |
| OQ-T2-7: Severity for InboxItem.commentOnMyWork | `.muted` (D-11). Informational, not urgent. |
| OQ-T2-8: Multi-workspace support? | NO in T2 — single-row-per-provider PK constraint (carry §8). |

---

## 11. Workflow per `conventions.md` (Stages 4-8)

After this spec lands + user review gate:

- **Stage 4 — Plan** (`superpowers:writing-plans`) — atomic per-commit decomposition with explicit AC per step. File: `.claude/plans/track-9-T2.md` (gitignored).
- **Stage 5 — Implementation** — TDD per step (`superpowers:test-driven-development`), sequential.
- **Stage 6 — Independent review** (`superpowers:code-reviewer` subagent) → digest via `superpowers:receiving-code-review`.
- **Stage 7 — Verification** — gates §7 explicit.
- **Stage 8 — Ship** — FF merge to `feature/track-9-substrate`; commit `docs(shared): Track-9 T2 landed — current-state update`.

Track-9 collective merge to main happens after T10 wrap per master spec §11.
