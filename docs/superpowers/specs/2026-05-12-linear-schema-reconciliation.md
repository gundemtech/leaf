# Linear schema reconciliation (hotfix workstream)

**Date:** 2026-05-12
**Branch:** `feature/linear-schema-reconciliation-2026-05-11`
**Base:** `feature/track-3-D1-linear-deep-sweep` (commits e0aa78b baseline; 1282 SPM tests, 5/5 xcodebuild schemes)
**Scope:** Minimal — restore baseline functionality + resurrect what current Linear schema permits. No CI guard, no v1.1 features.
**Type:** Hotfix workstream (not Track 3 D2). Schema-drift reconciliation.

## 1. Context

Track 3 D1 ship'нулся, smoke test выявил **10 schema-drift bugs** в `ProdLinearGraphQLProvider.swift` (LeafCorePrivate moat). Это pre-existing drift, накапливался с Phase 4.6.B / 4.7.C / Track-1 D1 — D1 acceptance gate просто его обнаружил. Production alpha.10 уже тихо ломал Linear data collection. Прошлая сессия применила 9 iterative `Track-3 D1 fix:` patches — guess-driven, без introspection. Этот pass — full introspection-driven correction.

## 2. Introspection truth

Полный schema sweep на `lin_api_...` Personal API Key (revoked после ship). Использовался Linear's `__type` introspection с `includeDeprecated: true`. 17 types + 4 input types + 7 live probe queries.

### 2.1 Comparison matrix (all 10 seed items + new findings)

| # | Field / area | Code as of D1 | Schema truth | Fix |
|---|---|---|---|---|
| 1 | `state.type.in: ["started"]` | quoted strings | `WorkflowStateFilter.type` = `StringComparator` | Keep strings. D1 fix correct. |
| 2 | `viewer.customViews` | moved to top-level | `User` has no `customViews`; top-level `customViews` exists | Keep at top-level. D1 fix correct. |
| 3 | `viewer.initiatives` | disabled fragment | `User` has no `initiatives`; **top-level `initiatives` exists** | **Re-enable** as `initiatives(first:25) { nodes { id name status health } }`. |
| 4 | `IssueHistory.type` | dropped from query | Confirmed not in schema (neither current nor deprecated) | Keep dropped. |
| 5 | `IssueHistory.flavor` | dropped from query | Same as #4 | Keep dropped. |
| 6 | `addedLabels { nodes }` | flattened to `addedLabels { id name }` | `IssueHistory.addedLabels: [IssueLabel]` LIST direct (may return `null`) | Keep flattened. Parser must treat `null` as empty. |
| 7 | `IssueRelationHistoryPayload.id` | whole `relationChanges` disabled | Type EXISTS with `identifier` + `type` String fields. `IssueHistory.relationChanges: [IssueRelationHistoryPayload]` LIST (may return `null`). | **Re-enable** `relationChanges { identifier type }` block. Resurrect `linear_relation_added/_removed` events. |
| 8 | `Comment.reactions(filter: ...)` | filter dropped, client-side filter | `Comment.reactions` field has 0 args | Keep dropped. |
| 9 | `Attachment.contentType` | nil-defensive read | Confirmed removed. Has `metadata` JSON, `bodyData` String, `source` field. | Keep dropped. Optional v1.1 — parse MIME from `metadata`. |
| 10 | `viewer.notifications` | still in query (broken in production) | `User` has no `notifications`. Top-level `notifications` exists. **`Notification` is INTERFACE**; 10 subtypes (`IssueNotification`, `ProjectNotification`, `DocumentNotification`, `PullRequestNotification`, etc). `issue` field only on `IssueNotification` (and similar). | **Move to top-level** + add `... on IssueNotification { issue { id identifier title } }` inline fragment. Other subtypes return base `Notification` fields only — graceful. |
| 11 | `viewer.subscribedIssues` | still in query | `User` has no `subscribedIssues`. `Issue` has `subscribers: [User]`. `IssueFilter.subscribers: UserCollectionFilter` accepts `some.isMe`. | Replace with `issues(filter: { subscribers: { some: { isMe: { eq: true } } } })`. |
| 12 | `viewer.projectMemberships` | still in query | `User` has no `projectMemberships`. `ProjectMembership` type does not exist. **Replacement found:** `Project.members` + top-level `projects(filter: { members: { some: { isMe: { eq: true } } } })` returns projects where viewer is member. | Replace. Diff vs snapshot logic untouched. |
| 13 | `roadmaps` top-level | top-level query | Field exists but **deprecated**: `"Roadmaps are deprecated, use initiatives instead"`. Returns empty array on most workspaces. | **Drop entirely.** `linear_roadmap_state_observed` event_kind becomes permanent zero-emit. Substrate keeps registry entry. |
| 14 | `Cycle.progress` | parser reads `progress` | `Cycle` has `currentProgress` not `progress`. | Query field rename. Parser also reads `currentProgress`. |
| 15 | `Cycle.completedIssueCountHistory` aliased | parser alias `issuesCompleted` | Confirmed field exists. | Keep alias. |

### 2.2 Net event-kind impact

Из 18 новых D1 event_kinds (registry 48 → 66):

- **16 work** post-reconciliation (notification trio, subscription added/removed, cycle started/completed, comment reaction added, relation added, triage pick-up/resolved, priority/label×2/assignee/cycle-changed/estimate, custom-view ×3, project-membership added/removed).
- **2 zero-emit** permanent: `linear_relation_removed` (Linear lost add/remove discriminator) + `linear_roadmap_state_observed` (Linear deprecated `roadmaps`).

Baseline 14 hot-tier event_kinds (Track 3 D1 era) — все восстанавливаются после fixes #6/#10/#14.

## 3. Workstream layout

### 3.1 Files touched

**Primary (gitignored moat):**
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/ProdLinearGraphQLProvider.swift` (~2196 lines): three query bodies rewritten, mapper changes for `currentProgress`, notification interface fragment, snapshot key renames, roadmap parser removed, project membership parser rewritten.
- `Packages/LeafCore/Tests/LeafCorePrivateTests/ProdLinearGraphQLProviderTests.swift` (~4239 lines): targeted fixture edits for each fixed area (sections 4.1–4.3). New fixtures synthesized from sanitized live probe responses (personal data → placeholders).

**Public surface (not changed):**
- `Packages/LeafCore/Sources/LeafCore/...` — substrate (atomic write, schedulers, FTS dispatcher, M015 schema, ShareEventTypeRegistry) is correct.
- `Apps/Leaf/...` — UI unaffected (consumes via LeafCore reads, which work against current SQLCipher rows).

### 3.2 Branch / commit strategy

- **Branch:** `feature/linear-schema-reconciliation-2026-05-11` off `feature/track-3-D1-linear-deep-sweep`. Reconciliation merges into `main` together with Track 3 stack (D1+D2+D3+D4) after Track 3 acceptance gate.
- **Commits:** 1 public + N moat (gitignored, no diff visible in `git status`). Public:
  - `docs(shared): linear schema reconciliation — current-state update` (single line under "Last update" entry referencing this spec + the Track 3 D1 acceptance carry).

### 3.3 Whitepaper

- `/sync-docs` deferred until Track 3 ship per Track 3 design spec §13. Reconciliation findings — implementation moat (GraphQL fragments, deprecation status, query shapes) — do not publish to whitepaper.
- Whitepaper risk addendum (post-Track-3 ship, separate session): "External provider schema drift — Linear/GitHub/Slack APIs may change fields without notice. Mitigation: introspection in pre-merge smoke + graceful degrade (per-endpoint failure tolerance, empty-array fallbacks). Schema-drift guard infrastructure — v1.1 candidate." Public-safe phrasing only.

## 4. Per-query fix spec

### 4.1 `LeafPoll` (hot tier, line ~1548 in moat file)

**Query changes:**
- Keep `viewer { id, assignedIssues(filter: { state: { type: { in: ["started"] } } }), teams(first: 5) { nodes { id name activeCycle { ... } } } }` outer shape.
- Inside `viewer.teams.nodes[].activeCycle`: rename `progress` → `currentProgress`. Keep `id name startsAt endsAt scopeHistory completedScopeHistory`.
- Keep top-level `projectUpdates`, `documents`, `issues` blocks.
- Inside `issues.nodes[].history.nodes[]`:
  - Remove `type`, `flavor` (already done — confirmed permanently dropped).
  - Keep `id createdAt actor { id } fromState { id name type } toState { id name type } fromPriority toPriority addedLabels { id name } removedLabels { id name } fromAssigneeId toAssigneeId fromCycle { id name } toCycle { id name } fromEstimate toEstimate`.
  - **Re-enable** `relationChanges { identifier type }` (block previously disabled per Track-3 D1 fix #7).
- Inside `issues.nodes[].comments.nodes[].reactions`: keep without `filter` arg (already done — confirmed permanently dropped).
- Inside `issues.nodes[].attachments.nodes[]`: keep without `contentType` (already done).

**Parser changes (private statics in same file):**
- `parseActiveCycle` (and equivalents): read `cycle["currentProgress"]` as primary; fallback `cycle["progress"]` removed.
- `parseRelationChanges`: re-enable in restricted form. `IssueRelationHistoryPayload` has only `identifier: String!` (the related issue's identifier, e.g. `"GUN-42"`) and `type: String!` (the relation kind: `"blocks"`, `"blocked_by"`, `"related"`, `"duplicate"`). **Direction is unobservable** — Linear's API no longer surfaces an add/remove discriminator on history entries, and `relatedIssue` nested fragment is removed (only string identifier remains; no UUID issue ID). Implementation: emit **only `linear_relation_added` events** per non-null `relationChanges` entry; `linear_relation_removed` remains permanent zero-emit until v1.1 (which would need cache-diff approach against prior tick's relation set). Parser constructs `LinearRelationSnapshot` with `toIssueId = ""` (no longer queryable; identifier-only) + `toIssueIdentifier = payload.identifier` + `relationKind = payload.type`. Down-grades `linear_relation_removed` count to 0 in registry-still-on state; `linear_relation_added` is now the sole signal.
- `parseLabelChanges`: confirm `null` treated as empty (likely already so per current parser; verify in fixture test).

### 4.2 `LeafWarm` (warm tier, line ~1747 in moat file)

**Full query rewrite:**
```graphql
query LeafWarm($notifSince: DateTimeOrDuration!) {
  notifications(first: 50, filter: { updatedAt: { gt: $notifSince } }) {
    nodes {
      __typename
      id
      type
      title
      createdAt
      readAt
      archivedAt
      actor { name }
      ... on IssueNotification {
        issue { id identifier title }
      }
    }
  }
  subscribed: issues(
    first: 50,
    filter: { subscribers: { some: { isMe: { eq: true } } } }
  ) {
    nodes { id identifier }
  }
  viewer {
    id
    teams(first: 5) {
      nodes {
        id
        activeCycle {
          id
          number
          name
          startsAt
          endsAt
          completedAt
          currentProgress
          issuesCompleted: completedIssueCountHistory
        }
      }
    }
  }
}
```

**Fallback shape (OQ-D1-1):** if first response surfaces error mentioning `notif` + `updatedat`, retry with `createdAt: { gt: $notifSince }`. Logic in `fetchWarmState` retained.

**Parser changes:**
- `parseWarmNotifications`: read `dataDict["notifications"]` (top-level), not `viewerDict["notifications"]`. Reconstruction-of-title path keeps existing fallback (`actor.name + issue.identifier + issue.title`) — used now only when subtype is non-Issue and `title` is missing. Actor field shape unchanged.
- `parseSubscribedIssues`: read `dataDict["subscribed"]` (aliased top-level `issues`), not `viewerDict["subscribedIssues"]`.
- `parseWarmCycles`: keep current logic. Read `cycle["currentProgress"]`. `completedAt` / `progress` / `issuesCompleted` paths unchanged.

### 4.3 `LeafCold` (cold tier, line ~2040 in moat file)

**Full query rewrite:**
```graphql
query LeafCold {
  customViews(first: 50) {
    nodes { id name team { id } updatedAt }
  }
  projects(first: 100, filter: { members: { some: { isMe: { eq: true } } } }) {
    nodes { id name }
  }
}
```

**Parser changes:**
- Remove `parseColdRoadmaps` / drop call. `LinearColdBatch.roadmaps` field retained (= empty array always) to keep `LinearColdBatch` Sendable Hashable Public init surface backward-compatible (no public type change).
- `parseColdMemberships`: rewrite to read `dataDict["projects"].nodes` (list of projects with id+name) instead of `dataDict["viewer"]["projectMemberships"].nodes[].project`. Signature changes from `viewerDict: [String: Any]?` to `dataDict: [String: Any]?`. Map each project to existing `LinearProjectMembershipSnapshot(projectId, projectName)`.

**Initiative observation stays in hot tier (LeafPoll)** per Phase 4.7.C original design. Hot-tier query gets a new top-level `initiatives(first: 25) { nodes { id name status } }` piggy-back block (symmetric with existing `projectUpdates` and `documents` top-level piggy-backs). `parseInitiatives` signature changes from `viewerDict: [String: Any]?` to `dataDict: [String: Any]`. `observedAtMs = nowMs` semantic preserved (heartbeat-per-hot-tick).

### 4.4 Snapshot table M015

No migration. `provider_snapshots` table accepts 4 `snapshot_kind` values:
- `linear_subscribed_issues` — still written (warm tier).
- `linear_custom_views` — still written (cold tier).
- `linear_project_memberships` — still written (cold tier, new query path).
- `linear_roadmap_state` — **never written** post-reconciliation. Row never created. Substrate accepts NULL absence.

`writeEventsOffsetsAndSnapshots` helper signature unchanged. Caller passes `snapshots: [...]` with fewer entries — same atomic-write contract.

### 4.5 Type surface (LeafCore public)

No changes. `LinearWarmBatch`, `LinearColdBatch`, `LinearWarmCursors` keep current shape. `LinearColdBatch.roadmapSnapshots` stays in struct (empty array always) — preserves Sendable Hashable Public init compatibility, no source-breaking change for callers in `LinearColdCollector`.

## 5. Fixture tests

Approach: **targeted edits + selective regen**, not full 4239-line rewrite.

### 5.1 Touch (existing fixtures)

- Drop `type` / `flavor` keys from `IssueHistory` JSON fixtures.
- Add `relationChanges` non-null sample to at least one history fixture.
- Rename `progress` → `currentProgress` in cycle fixtures.
- Drop `contentType` from `Attachment` fixtures.
- Drop `filter` arg from `Comment.reactions` query-shape assertions.

### 5.2 New fixtures (sanitized from live probes)

- `Fixtures.LeafWarm.notificationsMixedSubtypes` — IssueNotification + DocumentNotification graceful (non-Issue subtype lacks `issue` field, parser does not crash).
- `Fixtures.LeafWarm.subscribedViaIssuesFilter` — `subscribed: issues(filter)` top-level alias path.
- `Fixtures.LeafCold.customViewsAndProjectMemberships` — two top-level fields in single response (initiative moved to hot tier).
- `Fixtures.LeafPoll.initiativesTopLevel` — top-level `initiatives` field response (replaces removed `viewer.initiatives` fragment).
- `Fixtures.LeafCold.noRoadmapsField` — assert parser does not crash when `roadmaps` key absent (it must not be in query).
- `Fixtures.LeafPoll.relationChangesEnabled` — synthesize `relationChanges` payload (no real workspace data — synthesize from introspection truth: `[{ identifier: "GUN-42", type: "blocks" }, { identifier: "GUN-43", type: "related" }]`).
- `Fixtures.LeafPoll.cycleCurrentProgress` — `activeCycle.currentProgress: 0.42` not `progress`.
- `Fixtures.QueryShapeAssertion` — at least one test asserts presence of `__typename`, inline fragment text, and `subscribed:` alias in generated query strings (regression-protect against accidental rollback).

### 5.3 Test count target

Baseline 1282 SPM tests + ~6-10 new = **~1288-1292 tests post-reconciliation**. Slight increase expected, no regressions.

## 6. Privacy / ADR-010 compliance

- All bodies (notification.title, issue.title, comment.body, attachment.title/metadata) — **on-device only**. Already covered by Track-1 D1 amendment (RelayBodyLeakageTests asserts none leak to `presence_state.state_json`).
- Reconciliation adds no new payload keys. ShareEventTypeRegistry untouched. Privacy regression test suite **untouched** — 14 walkbacks remain, all still relevant.

## 7. Acceptance gate

1. **All 10 seed items resolved** per Section 2.1 matrix. Each `// Track-3 D1 fix:` comment in `ProdLinearGraphQLProvider.swift` either becomes a permanent fix (no comment) or is replaced by a `// Reconciliation 2026-05-12:` note explaining the decision.
2. **Live smoke on dev Mac:** Agent runs cleanly. Logs confirm:
   - Hot tick: writes ≥ 1 event (current state: 13 events in last successful tick observed pre-reconciliation, similar expected).
   - Warm tick: returns populated `LinearWarmBatch` (notifications + subscribed + cycles non-empty for active workspace).
   - Cold tick: returns populated `LinearColdBatch` (custom views may be empty for some workspaces — that's fine; project memberships ≥ 1; initiatives if workspace has them).
3. **MCP queries return fresh data:**
   - `mcp__leaf__get_linear_activity` returns recent events with `event_kind` field showing variety (not just `issue_updated`).
   - `mcp__leaf__get_workload_pulse` returns non-empty `assignedStartedCount` + cycle pulse.
   - `mcp__leaf__get_current_presence` returns `state_json.linear` with populated `workloadPulse` + `assignedIssues`.
4. **MenuBar UI cross-check:** Activity tab shows recent Linear events; Linear connection card shows "Connected" without error banner. Counts match the user's expectation against linear.app (within polling lag tolerance ±10 min for hot tier).
5. **All SPM tests green:** 1282 baseline + new fixtures (target ≥1288). `swift test --package-path Packages/LeafCore` exits 0.
6. **All xcodebuild schemes green:** Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP. `xcodebuild -scheme <X> build` exits 0 for each.
7. **`just check-tokens` PASS** (unchanged token-discipline guard).
8. **Spec committed.** This file lives at `docs/superpowers/specs/2026-05-12-linear-schema-reconciliation.md`.
9. **Current-state updated** with reconciliation note + Linear API key revoke reminder.
10. **Whitepaper sync explicitly deferred** to post-Track-3 ship session (`/sync-docs` not invoked now).

## 8. Out of scope (explicit non-goals)

- Track 3 D2 (GitHub deep sweep).
- CI schema-drift guard (`LinearSchemaFingerprint` helper) — deferred to v1.1.
- New Linear event_kinds beyond reconciliation. ShareEventTypeRegistry stays at 66 entries.
- New MCP tools / Derived Insights surfaces.
- Slack / GitHub introspection (separate workstreams if drift is suspected — none observed in D1 smoke).
- UI changes (Activity, Connections, MenuBar) — substrate-only fix.
- Substrate changes (atomic write, schedulers, FTS dispatcher) — substrate is correct.
- Optional v1.1: parse MIME type from `Attachment.metadata` JSON.
- Optional v1.1: handle additional `Notification` interface subtypes (ProjectNotification, PullRequestNotification) with their own inline fragments — current scope handles `IssueNotification` only; other subtypes degrade gracefully to base fields.

## 9. Risks

- **Linear deprecating `roadmaps` further** — we already drop it. Risk-free.
- **Linear changing notification interface** — adding new subtype types: ours uses single inline fragment, new subtypes just lack the extra fields, no crash.
- **Linear changing `IssueRelationHistoryPayload` fields** — we use `identifier` + `type`, both schema-confirmed. If they change, parser surfaces empty `relationChanges` (defensive); detectable in next smoke pass.
- **`Cycle.currentProgress` rename** — if Linear renames again to `progress` (revert), parser must read both. Plan implementation includes dual-key read for forward-compat.
- **`projects.members.isMe` semantics** — assumed equivalent to old `viewer.projectMemberships`. If Linear's `members` is broader (e.g., includes viewer-as-followers not just members), event counts may differ slightly. Acceptable for reconciliation; verify in smoke.

## 10. Token discipline reminder

The Personal API key created for introspection during this pass is in conversation history and must be **revoked** at https://linear.app/settings/api **before** branch merge into `main`. Acceptance gate criterion #11: user confirms revocation in chat.
