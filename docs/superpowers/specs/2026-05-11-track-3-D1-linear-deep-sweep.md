# Track 3 / D1 — Linear Deep Sweep

**Status:** Active (2026-05-11). First sub-phase of Track 3 stack.
**Owner:** Alex.
**Stack:** branches off `main` (Track-1 D3 + Track-2 D4 stacks ready, awaiting collective merge). **НЕ merged в main** — D1 → D2 → D3 → D4 sequential; collective merge стэка после Track 3 acceptance gate (Track 3 design spec §13).

---

## 1. Context

D1 — substrate sub-phase, открывает Track 3 ("external providers deep sweep"). Контракт уровня track'а — `2026-05-11-track-3-providers-deep-sweep-design.md`. Декомпозиция (§"Approach" контракта): D1 Linear → D2 GitHub → D3 Slack → D4 cross-cutting. Track 3 acceptance gate — manual smoke на real workspace для каждого sub-phase до коллективного merge.

**Зачем сейчас.** Baseline (2026-05-11): Linear collector emit'ит 14 event_kinds через single 5-минутный poll (`LinearCollector.swift`). Один OAuth scope `read` покрывает гораздо больше API surface — оставлено за бортом: notifications inbox, subscribed issues diff, comment reactions, roadmap state, triage queue transitions, custom views, issue relations, cycle lifecycle, project memberships.

Track 3 спек §"D1 — Linear matrix" перечисляет 9 endpoint clusters → **18 distinct event_kinds** (расширенный пересчёт vs spec headline "~12"; см. §3 ниже). Capture-everything локально, share-selectively через Share Controls (ADR-020) — все новые kinds default OFF.

**Нет scope bump.** OAuth `read` покрывает все 9 endpoints. Никакого re-auth UX (тот резервируется на D2 GitHub + D3 Slack).

**Privacy model:** ADR-010 §6 amendment остаётся в силе — bodies/titles on-device only (SQLCipher decrypted only by Agent / MCPServer / MenuBarApp), forbidden в data egress. D1 не пишет в relay вообще.

**Whitepaper sync deferred** до post-Track-3-D4 collective merge, public-safe architectural framing only (Track 3 design spec §13).

**Текущее состояние codebase:**
- Track-1 D3 stack landed (`feature/track-1-D3-detectors-and-structured-mcp`, awaiting Track 1 acceptance gate merge). 28 SQLCipher tables (M001-M014). 1213 SPM tests baseline.
- Track-2 D4 stack landed (`feature/track-2-D4-final-migration-and-cleanup`, awaiting Track 2 acceptance gate). Design system substrate complete, 5/5 xcodebuild schemes green.
- `LinearCollector.swift` (`Packages/LeafCore/Sources/LeafCore/Collectors/LinearCollector.swift`) — single actor, 14 event_kinds.
- `LinearGraphQLProvider.swift` (`Packages/LeafCore/Sources/LeafCore/Integrations/Linear/`) — protocol с одним методом `fetchIssues(accessToken:since:)`. Prod impl в `LeafCorePrivate` (`ProdLinearGraphQLProvider.swift`, moat).
- ShareEventTypeRegistry — **48 keys** (Track-1 D3 added 5; spec recon "39" outdated).
- `EventsFullTextStore.swift` (Track-1 D2) — dispatcher checks `"linear_issue_updated"` но `LinearCollector` emits `"issue_updated"` — Linear descriptions не индексируются в FTS. **Carry-over bug fixed в D1** (см. §6).
- Existing scheduler patterns: `MaintenanceScheduler`, `DetectorScheduler`, `RotationFetchScheduler` — public actor + Task loops + start/stop/performTick.
- Existing atomic write pattern: `Database.writeEventsOffsetAndPresence` (events + cursor + presence_state). Generalized form (`writeEventsOffsetsAndSnapshots`) добавляется в D1 (§5).

**Источники правды (priority при противоречии):**
1. `2026-05-11-track-3-providers-deep-sweep-design.md` §"D1 — Linear matrix", §"OAuth re-auth UX" (D1 — N/A), §"Acceptance criteria — D1".
2. Существующие patterns: `LinearGraphQLProvider.swift` (GraphQL fragment + snapshot pair), `MaintenanceScheduler.swift` (cold scheduler reference), Track-1 D2 `EventsFullTextStore.swift` (FTS dispatcher).
3. ADR-010 §6 amendment: bodies on-device → yes, в relay → never.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| **`M015_ProviderSnapshots` migration** | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M015_ProviderSnapshots.swift` (new) | `extension DatabaseMigrator { mutating func registerMigration015ProviderSnapshots() }`. SQL: `CREATE TABLE provider_snapshots (provider TEXT NOT NULL, snapshot_kind TEXT NOT NULL, snapshot_json TEXT NOT NULL, captured_at_ms INTEGER NOT NULL, PRIMARY KEY (provider, snapshot_kind)) WITHOUT ROWID`. Idempotent. Generic — D2/D3 будут использовать без новых migration'ов. |
| **Migration registration** | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (edit) | Insert `migrator.registerMigration015ProviderSnapshots()` после M014. |
| **`ProviderSnapshot` value type** | `Packages/LeafCore/Sources/LeafCore/DB/ProviderSnapshot.swift` (new) | `public struct ProviderSnapshot: Codable, Sendable, Hashable { provider: String; snapshotKind: String; snapshotJSON: String; capturedAtMs: Int64 }`. |
| **`ProviderSnapshotsStore`** | `Packages/LeafCore/Sources/LeafCore/DB/ProviderSnapshotsStore.swift` (new) | Read/write API: `read(provider:snapshotKind:) -> ProviderSnapshot?`; `write(_ snapshot:)`. GRDB. |
| **`Database.writeEventsOffsetsAndSnapshots`** | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (edit) | New atomic write helper. Signature: `func writeEventsOffsetsAndSnapshots(events: [RawEvent], offsets: [(CollectorOffsetID, String, CollectorOffset)], snapshots: [ProviderSnapshot]) async throws`. Single transaction. Arrays могут быть пустыми (partial updates allowed). Existing `writeEventsOffsetAndPresence` остаётся unchanged (hot tier path). |
| **`Schema.EventPayloadKeys` extension** | `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` (edit) | Add new payload key constants: `notificationId`, `notificationKind`, `notificationTitle`, `issueId`, `issueIdentifier`, `commentId`, `relationId`, `fromIssueId`, `fromIssueIdentifier`, `toIssueId`, `toIssueIdentifier`, `relationKind`, `emoji`, `teamId`, `toStateName`, `toStateType`, `resolutionKind`, `cycleId`, `cycleNumber`, `cycleName`, `viewId`, `viewName`, `roadmapId`, `roadmapName`, `projectId`, `projectName`, `stateEnum`, `issuesCompletedCount`, `progress`, `observedAtMs`, `receivedAtMs`, `readAtMs`, `archivedAtMs`, `reactedAtMs`, `startedAtMs`, `endsAtMs`, `completedAtMs`, `removedAtMs`. **Naming convention:** snapshot-diff derived events (subscription/customView/membership) use `observedAtMs` (= nowMs); Linear-side timestamps (cycle/relation/triage/notification/reaction) use specific field names (`startedAtMs`/`completedAtMs`/`reactedAtMs`/etc). Single source of truth для collectors + D2 FTS + D3 detectors. |
| **`CollectorOffsetID` enum extension** | `Packages/LeafCore/Sources/LeafCore/DB/CollectorOffset.swift` (edit) | Add `linearWarmPolling` и `linearColdPolling` cases. Existing `linearPolling` остаётся (hot tier). |
| **`Schema.BodyKinds` extension** | `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` (edit) | Add `linearNotificationTitle = "linear_notification_title"`. |
| **`ShareEventTypeRegistry` extension** | `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` (edit) | 18 new enum cases (см. §3 ниже) + 18 entries в `ShareEventTypeDefaults.all` с `defaultEnabled: false`. Registry size: 48 → **66**. |
| **`LinearWarmCursors` value type** | `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearWarmCursors.swift` (new) | `public struct LinearWarmCursors: Sendable, Hashable { notificationsSince: Int64?; cyclesSince: Int64? }`. Bootstrap behavior: nil → 7-day backfill window (mirror `LinearCollector.backfillWindowDays`). |
| **`LinearWarmBatch` value type** | `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearGraphQLProvider.swift` (edit, add public types) | `public struct LinearWarmBatch: Sendable, Hashable { notifications: [LinearNotificationSnapshot]; notificationCursorMs: Int64?; cyclesStarted: [LinearCycleSnapshot]; cyclesCompleted: [LinearCycleSnapshot]; cyclesCursorMs: Int64?; subscribedIssueIds: [LinearSubscribedIssueSnapshot] }`. Subscribed issues — current full set (diff делает collector). Cycle started/completed — pre-bucketed provider-side по timestamp filter. |
| **`LinearColdBatch` value type** | `LinearGraphQLProvider.swift` (edit) | `public struct LinearColdBatch: Sendable, Hashable { roadmaps: [LinearRoadmapSnapshot]; customViews: [LinearCustomViewSnapshot]; projectMemberships: [LinearProjectMembershipSnapshot] }`. All three — current full sets (diff делает collector). |
| **Snapshot value types** | `LinearGraphQLProvider.swift` (edit) | `LinearNotificationSnapshot { id, kind, issueId?, issueIdentifier?, title, createdAtMs, readAtMs?, archivedAtMs? }`. `LinearSubscribedIssueSnapshot { id, identifier }`. `LinearCycleSnapshot { id, number, teamId, name?, startsAtMs, endsAtMs, completedAtMs?, progress?, issuesCompletedCount? }`. `LinearRoadmapSnapshot { id, name?, projects: [LinearRoadmapProjectSnapshot] }`. `LinearRoadmapProjectSnapshot { projectId, projectName, stateEnum }`. `LinearCustomViewSnapshot { id, name, teamId?, updatedAtMs }`. `LinearProjectMembershipSnapshot { projectId, projectName }`. Все Codable+Sendable+Hashable. |
| **`LinearGraphQLProvider` protocol extension** | `LinearGraphQLProvider.swift` (edit) | Add two new methods: `func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch`; `func fetchColdState(accessToken: String) async throws -> LinearColdBatch`. Existing `fetchIssues` signature unchanged (см. §4 — hot fragments — implementation moat). |
| **`LinearIssueBatch` extension** | `LinearGraphQLProvider.swift` (edit, ~lines 31-93) | Add new fields для hot piggy-back: `commentReactions: [LinearCommentReactionSnapshot]`, `relationAdditions: [LinearRelationSnapshot]`, `relationRemovals: [LinearRelationSnapshot]`, `triagePickedUp: [LinearTriageTransitionSnapshot]`, `triageResolved: [LinearTriageTransitionSnapshot]`. Backward-compat init defaults (empty arrays). |
| **`LinearCommentReactionSnapshot`** | `LinearGraphQLProvider.swift` (edit) | `{ id, commentId, issueId, issueIdentifier, emoji, createdAtMs }`. Provider already filters `user.id == viewer.id` (moat). |
| **`LinearRelationSnapshot`** | `LinearGraphQLProvider.swift` (edit) | `{ id, fromIssueId, fromIssueIdentifier, toIssueId, toIssueIdentifier, relationKind, transitionedAtMs }`. `relationKind ∈ {blocks, blocked_by, related, duplicate}`. |
| **`LinearTriageTransitionSnapshot`** | `LinearGraphQLProvider.swift` (edit) | `{ issueId, issueIdentifier, teamId, toStateName, toStateType, transitionedAtMs, resolutionKind? }`. `resolutionKind` populated только для `_resolved` flavor (`completed` | `canceled`). |
| **`LinearCollector` extensions** | `Packages/LeafCore/Sources/LeafCore/Collectors/LinearCollector.swift` (edit) | Add 5 new `make*Event()` static methods: `makeCommentReactionAddedEvent`, `makeRelationAddedEvent`, `makeRelationRemovedEvent`, `makeTriagePickedUpEvent`, `makeTriageResolvedEvent`. Each constructs `RawEvent` with proper `signalType` (`.action`), payload keys, `source="linear"`, `event_kind=<discriminator>`. Wire emissions в `performTick` mapping pass. Existing 14 event_kinds untouched. |
| **`LinearWarmCollector`** | `Packages/LeafCore/Sources/LeafCore/Collectors/LinearWarmCollector.swift` (new) | `public actor LinearWarmCollector`. Mirrors `LinearCollector` shape: deps (`Database`, `LinearGraphQLProvider`, `LinearTokenRefresher`, `intervalSec=900`, logger). `performTick(now:)` reads integration row, refreshes token, reads cursors (`linear:notifications:<workspaceID>`, `linear:cycles:<workspaceID>`) + snapshot (`linear_subscribed_issues`), calls `fetchWarmState`, maps to events (3 notification flavors + 2 subscription flavors + 2 cycle flavors), atomic write via `writeEventsOffsetsAndSnapshots`. Public `start()/stop()/performTick(now:)`. |
| **`LinearColdCollector`** | `Packages/LeafCore/Sources/LeafCore/Collectors/LinearColdCollector.swift` (new) | `public actor LinearColdCollector`. Same shape — deps, `performTick(now:)`. Reads 3 snapshots (`linear_custom_views`, `linear_project_memberships`, `linear_roadmap_state`), calls `fetchColdState`, maps to events (1 roadmap heartbeat-per-tick + 3 customView flavors + 2 membership flavors), atomic write. Public `start()/stop()/performTick(now:)`. |
| **`LinearWarmScheduler`** | `Packages/LeafCore/Sources/LeafCore/Agent/LinearWarmScheduler.swift` (new) | Mirrors `RotationFetchScheduler` shape. Public `start()/stop()`. Interval-based Task loop: initial delay = `intervalSec / 2`, then `while !Task.isCancelled { await collector.performTick(now:); await sleep(intervalSec) }`. `intervalSec = 900` (15m). |
| **`LinearColdScheduler`** | `Packages/LeafCore/Sources/LeafCore/Agent/LinearColdScheduler.swift` (new) | 4am local anchor + catch-up. Public `start()/stop()`. On start: read `linear:cold:<workspaceID>` offset; если `now - lastColdRunMs > 24h` (или offset absent) → perform catch-up tick immediately. Then loop: compute `nextLocal4amMs(now)` via `Calendar.current` (`DateComponents(hour: 4, minute: 0)` next occurrence), `Task.sleep(nanoseconds: deltaNanos)`, perform tick, repeat. Mac asleep at 4am → Task.sleep continues on wake (fires при первом wake после 4am, как design intent). On successful tick → update `linear:cold:<workspaceID>` offset = `nowMs`. |
| **`AgentLifetime` wiring** | `Packages/LeafCore/Sources/LeafCore/Agent/Agent.swift` (edit) | Construct `LinearWarmCollector` + `LinearWarmScheduler` + `LinearColdCollector` + `LinearColdScheduler`. Plug в shutdown chain (after `DetectorScheduler` — read-side from collector POV; order: shutdown collectors first → schedulers → DB last). Stop order: `linearColdScheduler.stop() → linearWarmScheduler.stop() → linearCollector.stop()`. |
| **`EventsFullTextStore.topLevelBodyKind` extension** | `Packages/LeafCore/Sources/LeafCore/DB/EventsFullTextStore.swift` (edit) | (a) **Track-1 D2 carry-over fix:** replace `case "linear_issue_updated"` → `case "issue_updated"` (Linear collector emits `"issue_updated"` без `linear_` префикса — broken since D2 land, fixed here). (b) Add `case "linear_notification_received": return Schema.BodyKinds.linearNotificationTitle`. Both cases dispatched по top-level `payload.event_kind`. |
| **DetectorPipeline carry-over** | `Packages/LeafCore/Sources/LeafCore/Detection/DetectorPipeline.swift` (no edit) | Shares `topLevelBodyKind()` dispatcher с FTS store — fix + extension propagate automatically. Bodies (`issue_updated.body`, `notification_received.title`) fed в decision/openQuestion/blocker detectors. Notification titles often mechanical ("@X commented on Y") — low-value detector input, accepted noise. |
| **`LinearIDExtractor` cross-link enrichment** | `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearIDExtractor.swift` (no edit для D1) | Existing `extractAll` уже работает поверх arbitrary text. Notification.title будет automatically scanned downstream link derivation (Track-1 D2 `event_links` substrate) — no extension needed. |

### Не входит (D2+)

- GitHub deep sweep — D2 Track 3 sub-phase.
- Slack deep sweep — D3.
- FTS dispatcher для GitHub/Slack new bodies — D4 cross-cutting.
- Share Controls UI pagination для 60+ entry registry — D4.
- OAuth re-auth UX banners — D2 (GitHub scope bump first surface).
- Auto-poll loop для invites (Phase 5.6) — отдельный track.
- Whitepaper sync — post-Track-3-D4 collective merge.

---

## 3. New event_kinds (18) + payload shapes

### Hot tier (5m, в `LinearCollector` через extended `fetchIssues`)

5 kinds. Mechanism: piggy-back fragments в существующий `fetchIssues` GraphQL query (exact fragment text — moat). Provider возвращает pre-bucketed snapshots; collector mapping остаётся ~10-line per `make*Event` функция.

1. **`linear_comment_reaction_added`** — `{ comment_id, issue_id, issue_identifier, emoji, reacted_at_ms, source: "linear" }`. Provider filters `user.id == viewer.id` (moat). signalType: `.action`.
2. **`linear_relation_added`** — `{ relation_id, from_issue_id, from_issue_identifier, to_issue_id, to_issue_identifier, relation_kind, started_at_ms, source: "linear" }`. `started_at_ms` = Linear `IssueRelationHistory.transitionedAtMs` of the "add" entry. `relation_kind ∈ {blocks, blocked_by, related, duplicate}`. signalType: `.action`. Mechanism: extension существующего `Issue.history` fragment dispatch (Track 4.7.C precedent — mirrors `linear_status_transition` / `linear_label_added`).
3. **`linear_relation_removed`** — same payload shape, `removed_at_ms` = Linear `IssueRelationHistory.transitionedAtMs` of the "remove" entry. signalType: `.action`.
4. **`linear_triage_item_picked_up`** — `{ issue_id, issue_identifier, team_id, to_state_name, to_state_type, started_at_ms, source: "linear" }`. signalType: `.action`. Derived от `Issue.history` entries where `from.state.type == "triage"` && `to.state.type ∈ {started, unstarted, backlog}` (т.е. not completion-bound). Substrate classification (Linear `WorkflowState.type` enum is public API).
5. **`linear_triage_item_resolved`** — same shape + `resolution_kind ∈ {completed, canceled}`. Derived от `Issue.history` entries where `from.state.type == "triage"` && `to.state.type ∈ {completed, canceled}`.

### Warm tier (15m, `LinearWarmCollector` через `fetchWarmState`)

7 kinds. Mechanism: single GraphQL call с top-level fields `viewer.notifications`, `viewer.subscribedIssues`, `viewer.teams.activeCycle` (mirroring Track 4.7.B precedent). Provider возвращает `LinearWarmBatch`; collector делает diff vs prior snapshot для subscribed issues.

6. **`linear_notification_received`** — `{ notification_id, notification_kind, issue_id?, issue_identifier?, notification_title, received_at_ms, source: "linear" }`. signalType: `.context`. Emit для notifications where `createdAt > prevNotificationsCursor`. Title — constructed substrate-side по Linear's standard rendering (`"\(actor.name) \(action) \(issue.identifier): \(issue.title)"` — substrate, public API mapping). **Title goes to FTS** через `linear_notification_title` body_kind.
7. **`linear_notification_read`** — `{ notification_id, read_at_ms, source: "linear" }`. signalType: `.context`. Emit где `readAt > prevCursor && readAt != null`.
8. **`linear_notification_archived`** — `{ notification_id, archived_at_ms, source: "linear" }`. signalType: `.context`. Emit где `archivedAt > prevCursor && archivedAt != null`.
9. **`linear_subscription_added`** — `{ issue_id, issue_identifier, observed_at_ms (= nowMs), source: "linear" }`. signalType: `.context`. Collector reads prior snapshot `linear_subscribed_issues` (JSON-encoded `[String]` issueID list), computes set-diff vs current batch, emits `_added` per new ID.
10. **`linear_subscription_removed`** — same shape, `observed_at_ms (= nowMs)`. Emitted per ID that's в prior snapshot но не в current batch.
11. **`linear_cycle_started`** — `{ cycle_id, cycle_number, team_id, cycle_name?, started_at_ms, ends_at_ms, source: "linear" }`. signalType: `.context`. Emit для cycles where `startsAt > prevCyclesCursor && startsAt <= now`. Pure timestamp filter, no snapshot needed.
12. **`linear_cycle_completed`** — `{ cycle_id, cycle_number, team_id, completed_at_ms, progress?, issues_completed_count?, source: "linear" }`. signalType: `.context`. Emit для cycles where `(completedAt != null && completedAt > prevCyclesCursor) || (endsAt > prevCyclesCursor && endsAt <= now)`. Manual completion + scheduled end both trigger.

### Cold tier (4am daily, `LinearColdCollector` через `fetchColdState`)

6 kinds. Mechanism: single GraphQL call с top-level fields `viewer.customViews`, `viewer.projectMemberships`, `roadmaps`. Provider возвращает `LinearColdBatch`; collector делает diff vs prior snapshots.

13. **`linear_roadmap_state_observed`** — `{ roadmap_id, project_id, project_name, state_enum, observed_at_ms (= nowMs), source: "linear" }`. signalType: `.context`. Heartbeat-per-tick — emit per (roadmap × project) pair every cold tick regardless of state change. Mirrors `linear_initiative_observed` precedent (Track 4.7.C). `state_enum` ∈ Linear ProjectStatus enum (`onTrack` / `atRisk` / `offTrack` / `noUpdate` / etc — substrate mapping).
14. **`linear_custom_view_created`** — `{ view_id, view_name, team_id?, observed_at_ms (= nowMs first-observed), source: "linear" }`. signalType: `.action`. Diff prior snapshot — emit per new view_id.
15. **`linear_custom_view_updated`** — `{ view_id, view_name, team_id?, observed_at_ms (= nowMs), source: "linear" }`. signalType: `.action`. Diff — emit per view_id где `name` или Linear's `updatedAtMs` changed vs prior snapshot (Linear's `updatedAtMs` участвует в diff trigger но не идёт в payload — `observed_at_ms` достаточно для downstream queries).
16. **`linear_custom_view_deleted`** — `{ view_id, view_name (from prior snapshot), observed_at_ms (= nowMs), source: "linear" }`. signalType: `.action`. Diff — emit per view_id в prior snapshot но не в current batch.
17. **`linear_project_membership_added`** — `{ project_id, project_name, observed_at_ms (= nowMs), source: "linear" }`. signalType: `.action`. Diff.
18. **`linear_project_membership_removed`** — `{ project_id, project_name (from prior snapshot), observed_at_ms (= nowMs), source: "linear" }`. signalType: `.action`. Diff.

---

## 4. Cursor & snapshot strategy

### Cursors (timestamp-based, in `collector_offsets` table)

| sourceID | Покрывает | Cursor advancement |
|---|---|---|
| `linear:<workspaceID>` | Hot — issues + reactions + relations + triage | Existing path. Advance to `batch.cursorMs ?? since` (mirror existing logic). |
| `linear:notifications:<workspaceID>` | Warm — notification received/read/archived | `max(notification.updatedAtMs)` over current batch. Bootstrap nil → 7 days back. |
| `linear:cycles:<workspaceID>` | Warm — cycle_started + _completed | `max(cycle.startsAtMs, cycle.endsAtMs, cycle.completedAtMs)` over current batch. Bootstrap nil → 7 days back. |
| `linear:cold:<workspaceID>` | Cold — heartbeat trigger (catch-up gate only, NOT a polling cursor) | `lastColdRunMs = nowMs` после successful cold tick. Used by `LinearColdScheduler` для catch-up decision (`now - lastColdRunMs > 24h` → run immediately). |

Note: subscription_added/removed (warm) и customViews/memberships/roadmap (cold) НЕ используют timestamp cursors — diff vs snapshot.

### Snapshots (in `provider_snapshots` table, M015)

| snapshot_kind | Tier | Shape (`snapshot_json` JSON) | Diff strategy |
|---|---|---|---|
| `linear_subscribed_issues` | Warm | `{ ids: ["UUID1", "UUID2", ...] }` | Set-diff: current\prior → added; prior\current → removed. |
| `linear_custom_views` | Cold | `{ views: [{ id, name, updatedAtMs }] }` | Diff by id → created/deleted; same id with different (name OR updatedAtMs) → updated. |
| `linear_project_memberships` | Cold | `{ memberships: [{ projectId, projectName }] }` | Set-diff by projectId. |
| `linear_roadmap_state` | Cold | `{ pairs: [{ roadmapId, projectId, projectName, stateEnum }] }` | Heartbeat — no diff, emit `linear_roadmap_state_observed` per pair every tick. Snapshot still written для potential future delta-mode (substrate forward-compat). |

Bootstrap (snapshot absent on first tick): emit zero events on first run, just write snapshot. Second tick onwards — diff works. Prevents flood of false "added" events on Day 1.

---

## 5. Data flow

### Hot tick (existing 5m, в `LinearCollector.performTick`)

```
1. Read integration row → skip if absent.
2. Refresh token via LinearTokenRefresher.
3. Read cursor `linear:<workspaceID>` → since: Int64?
4. provider.fetchIssues(accessToken:, since:) → LinearIssueBatch (extended fields).
5. Map batch to RawEvent[]:
   - Existing 14 event_kinds (unchanged).
   - + comment reactions (filter applied provider-side): makeCommentReactionAddedEvent per snapshot.
   - + relation additions/removals: makeRelationAdded/RemovedEvent per snapshot.
   - + triage transitions: makeTriagePickedUp/ResolvedEvent per snapshot.
6. Database.writeEventsOffsetAndPresence(events, offset, presence: (.linear, ...), nowMs)
   — existing atomic helper unchanged, presence_state.linear dict unchanged.
```

### Warm tick (new 15m, `LinearWarmCollector.performTick`)

```
1. Read integration row → skip if absent.
2. Refresh token.
3. Read cursors: linear:notifications:<wid>, linear:cycles:<wid> (Int64? each).
   Read snapshot: linear_subscribed_issues (ProviderSnapshot?).
4. cursors = LinearWarmCursors(notificationsSince: ..., cyclesSince: ...)
   provider.fetchWarmState(accessToken:, cursors:) → LinearWarmBatch.
5. Map batch to RawEvent[]:
   - For each notification in batch.notifications:
       - if createdAtMs > prevNotificationsCursor: emit linear_notification_received (title to FTS via dispatch).
       - if readAtMs != null && readAtMs > prevNotificationsCursor: emit linear_notification_read.
       - if archivedAtMs != null && archivedAtMs > prevNotificationsCursor: emit linear_notification_archived.
   - For each cycle in batch.cyclesStarted: emit linear_cycle_started.
   - For each cycle in batch.cyclesCompleted: emit linear_cycle_completed.
   - Subscribed issues diff:
       - priorSet = JSON-decoded snapshot ids; currentSet = batch.subscribedIssueIds.map(\.id) as Set.
       - addedIds = currentSet \ priorSet → emit linear_subscription_added per id.
       - removedIds = priorSet \ currentSet → emit linear_subscription_removed per id.
       - Bootstrap (prior snapshot absent): emit no events, just write current snapshot.
6. Compute new cursors + new subscribed_issues snapshot.
7. Database.writeEventsOffsetsAndSnapshots(
     events: [...],
     offsets: [(.linearWarmPolling, "linear:notifications:<wid>", newNotifCursor),
               (.linearWarmPolling, "linear:cycles:<wid>", newCyclesCursor)],
     snapshots: [updatedSubscribedSnapshot]
   ).
```

### Cold tick (new 4am daily, `LinearColdCollector.performTick`)

```
1. Read integration row → skip if absent.
2. Refresh token.
3. Read snapshots: linear_custom_views, linear_project_memberships, linear_roadmap_state.
4. provider.fetchColdState(accessToken:) → LinearColdBatch.
5. Map batch to RawEvent[]:
   - For each (roadmap, project) pair in batch.roadmaps: emit linear_roadmap_state_observed (heartbeat).
   - Custom views diff:
       - priorById = JSON-decoded snapshot views, keyed by id.
       - currentById = batch.customViews, keyed by id.
       - For each id in currentById:
           - if prior[id] absent: emit linear_custom_view_created.
           - else if (name OR updatedAtMs differs): emit linear_custom_view_updated.
       - For each id in priorById не в currentById: emit linear_custom_view_deleted.
       - Bootstrap: emit no events, write current snapshot.
   - Project memberships diff (set-based by projectId): emit _added / _removed.
6. Compute new snapshots (overwrite all 3).
7. Database.writeEventsOffsetsAndSnapshots(
     events: [...],
     offsets: [(.linearColdPolling, "linear:cold:<wid>", CollectorOffset(lastModifiedMs: nowMs))],
     snapshots: [updatedRoadmapsSnap, updatedCustomViewsSnap, updatedMembershipsSnap]
   ).
```

### Cold scheduler timing

```
LinearColdScheduler.start():
  Task {
    1. Read linear:cold:<wid> offset.
    2. If absent || (nowMs - lastColdRunMs > 24h): perform catch-up tick immediately.
    3. Loop while !Task.isCancelled:
       a. let next4amMs = nextLocal4amMs(from: nowMs)  // Calendar.current, DateComponents(hour: 4)
       b. let deltaNs = (next4amMs - nowMs) * 1_000_000
       c. try? await Task.sleep(nanoseconds: deltaNs)
       d. if Task.isCancelled { break }
       e. await collector.performTick(now: nowMs)
  }
```

Mac asleep behavior: `Task.sleep` continues on wake — Task fires at first wake after 4am instant. Acceptable per design intent ("off-hours rough").

---

## 6. FTS integration + Track-1 D2 carry-over fix

### Dispatcher edits (`EventsFullTextStore.topLevelBodyKind`)

**Fix:** existing line `case "linear_issue_updated": return Schema.BodyKinds.linearDesc` → `case "issue_updated": return Schema.BodyKinds.linearDesc`. `LinearCollector` emits `"issue_updated"` (без `linear_` префикса) — broken since Track-1 D2 land (current-state.md flags carry-over).

**Extension:** add new case:
```
case "linear_notification_received":
    return Schema.BodyKinds.linearNotificationTitle
```

Body extraction: `payload["notification_title"]` → indexed в `events_fts` через existing FTS write path. One FTS row per `linear_notification_received` event.

### `Schema.BodyKinds` extension

Add `linearNotificationTitle = "linear_notification_title"` static constant.

### DetectorPipeline propagation

`DetectorPipeline.dispatch` shares `topLevelBodyKind` dispatcher — fix + extension auto-propagate. Notification titles get fed в decision/openQuestion/blocker detectors. Mechanical text ("@X commented on Y") generates noisy detector input — accepted (false-positive cost low; substantive notifications mention real terms).

### Regression tests

- Add test asserting `LinearCollector`-emitted `issue_updated` event с `body` payload key indexes в `events_fts` (regression для Track-1 D2 bug — confirms fix unlocks UC1/UC3 для Linear bodies).
- Add test asserting `LinearWarmCollector`-emitted `linear_notification_received` event с `notification_title` payload indexes в `events_fts`.

---

## 7. Share Controls

### Registry expansion (48 → 66)

18 new `ShareEventTypeKey` cases (one per event_kind):

```
case linearCommentReactionAdded = "linear_comment_reaction_added"
case linearRelationAdded = "linear_relation_added"
case linearRelationRemoved = "linear_relation_removed"
case linearTriageItemPickedUp = "linear_triage_item_picked_up"
case linearTriageItemResolved = "linear_triage_item_resolved"
case linearNotificationReceived = "linear_notification_received"
case linearNotificationRead = "linear_notification_read"
case linearNotificationArchived = "linear_notification_archived"
case linearSubscriptionAdded = "linear_subscription_added"
case linearSubscriptionRemoved = "linear_subscription_removed"
case linearCycleStarted = "linear_cycle_started"
case linearCycleCompleted = "linear_cycle_completed"
case linearRoadmapStateObserved = "linear_roadmap_state_observed"
case linearCustomViewCreated = "linear_custom_view_created"
case linearCustomViewUpdated = "linear_custom_view_updated"
case linearCustomViewDeleted = "linear_custom_view_deleted"
case linearProjectMembershipAdded = "linear_project_membership_added"
case linearProjectMembershipRemoved = "linear_project_membership_removed"
```

All 18 — `.init(key: ..., defaultEnabled: false)` в `ShareEventTypeDefaults.all`. User opt-ins per ADR-020.

### Privacy walkbacks

- **Comment reactions** filter `user.id == viewer.id` provider-side — team reactions НЕ captured.
- **Notification titles** могут содержать team member names (`"@Alice commented on TEAM-12"`). On-device only per ADR-010 §6; default OFF prevents relay leak.
- **Triage transitions** capture `team_id` (substrate identifier) + `to_state_name` (raw enum string) — no PII.
- **Roadmaps / projects** capture `project_name` (workspace label, не secret content).
- **Relations** capture `from/to_issue_identifier` (e.g., `"LEAF-12"`) — cross-link friendly, no PII.

---

## 8. Error handling

### Hot tick (existing `LinearCollector`)

- Network / parse failure в `fetchIssues` → returns `TickResult(skipped: false, cursorAdvancedMs: nil)` — cursor NOT advanced. Existing behavior preserved.
- Token `.refreshDenied` → skipped, no retry. Existing.

### Hot tier complexity-error fallback (NEW, per Q7)

`ProdLinearGraphQLProvider.fetchIssues` parses GraphQL response `errors[]` для complexity-related signatures (Linear returns HTTP 200 + errors array на complexity overrun, not 429). Detection logic — moat (specific error message strings). On detection:
- Log warn (`os.Logger`)
- Return `LinearIssueBatch` без populated `commentReactions` / `relationAdditions` / `relationRemovals` / `triagePickedUp` / `triageResolved` (empty arrays).
- Existing issue data still flows через batch.
- Cursor still advances.
- Next tick retries from same cursor.

Test: stub provider returns complexity-error response → assert: existing event emission unaffected, new event arrays empty, cursor advances. Mirror Track 4.7.C documents legacy-workspace degrade precedent.

### Warm tick

- Network / parse failure → returns empty batch, cursors NOT advanced, snapshot NOT updated. Next tick retries.
- Partial batch: provider attempts notifications / subscribed / cycles independently. On per-endpoint failure, batch field stays empty for that endpoint; other endpoints emit normally. `writeEventsOffsetsAndSnapshots` accepts partial offsets/snapshots arrays — only successful endpoints' cursors update.

### Cold tick

- Network / parse failure → empty batch, snapshots NOT updated, `linear:cold:<wid>` offset NOT advanced. Next 4am wake retries.
- No retry suppression on consecutive failures (simpler — manual operator visibility via logs). Edge case: if cold endpoint persistently failing, cold scheduler fires daily, logs daily warn. Acceptable.

### Bootstrap windows

- Hot bootstrap (since=nil): existing 7-day backfill window (`LinearCollector.backfillWindowDays = 7`).
- Warm bootstrap (cursors nil): 7-day backfill window для notifications + cycles (mirror existing). Subscribed issues snapshot absent → emit zero events, write current snapshot only.
- Cold bootstrap (snapshots absent): emit only roadmap heartbeats (всегда emit-per-tick); customViews + memberships → emit zero events, write current snapshots only. Day-2 diff works normally.

### Atomic write under partial failure

`Database.writeEventsOffsetsAndSnapshots(events:offsets:snapshots:)` — single GRDB write transaction. On exception → full rollback (events not written, cursors not advanced, snapshots not updated). Failure isolation guaranteed: warm tick failure doesn't corrupt cold state и vice versa (different `provider_snapshots` rows).

---

## 9. Moat boundaries

### Substrate (`LeafCore`, public)

- All event_kind discriminator strings + payload key names + `BodyKinds` constants.
- `provider_snapshots` schema + M015 migration.
- `LinearWarmCollector` / `LinearColdCollector` actor skeletons (start/stop/performTick lifecycle).
- `LinearWarmScheduler` / `LinearColdScheduler` actors.
- `LinearGraphQLProvider` protocol additions (`fetchWarmState`, `fetchColdState` signatures + value types).
- Snapshot kind constants.
- Diff helper utilities (set-based added/removed computation; customView updated detection by name+updatedAtMs equality).
- Triage classification (Linear `WorkflowState.type` → picked_up vs resolved — public API mapping).
- Notification.title construction (`"\(actor.name) \(action) \(issue.identifier): \(issue.title)"` — substrate, public API rendering).
- Roadmap state enum mapping (`ProjectStatus` enum — public API).
- FTS dispatcher edits.
- ShareEventTypeRegistry entries.
- All test code (mock providers, snapshot fixtures, integration tests).

### Moat (`LeafCorePrivate`, `ProdLinearGraphQLProvider`)

- GraphQL fragments для reactions / relations / triage history dispatch (the actual query text additions to existing `fetchIssues` query).
- New GraphQL query bodies для `fetchWarmState` (single multi-field query) и `fetchColdState` (single multi-field query).
- Page size / complexity budget constants (page size for warm/cold endpoints).
- Complexity-error detection logic (parsing GraphQL `errors[]` для defensive fallback — specific message string signatures).
- Linear `user.id == viewer.id` filter (server-side filter clause inside reactions fragment).
- Linear notification updatedAt filter expression (`filter: { updatedAt: { gt: $since }}`).
- Linear triage history actor filter expression.

---

## 10. Testing strategy

Target growth: **+40-50 SPM tests** (1213 baseline → ~1253-1263).

### Substrate unit tests (LeafCore)

**Migration:**
- `M015_ProviderSnapshotsTests` — fresh DB + apply migration → table exists, schema matches.
- `ProviderSnapshotsStoreTests` — read/write API + JSON roundtrip + transaction atomicity (write fails → no partial state).

**Collectors:**
- `LinearWarmCollectorTests` — mock provider, mock database. Coverage:
  - Bootstrap (no cursors, no snapshot): emits cycle starts + completes (timestamp-based), zero subscription events, writes snapshot.
  - Steady-state: emits 3 notification flavors per matching record, emits subscription added/removed via diff.
  - Empty batch: no events, cursors NOT advanced, snapshot unchanged.
  - Provider error: no events, cursors NOT advanced.
  - Partial batch: notifications populated + cycles empty → cycles cursor NOT advanced, notification cursor advances.
- `LinearColdCollectorTests` — mock provider:
  - Bootstrap: only roadmap heartbeats emitted; customViews + memberships emit zero events on first tick.
  - Steady-state: customView created/updated/deleted + membership added/removed via diff.
  - Roadmap heartbeat: emits per (roadmap × project) every tick regardless of state change.
- `LinearCollectorTests` (extension) — additional cases:
  - Reactions emitted (mock provider returns reactions in batch).
  - Relations emitted (added + removed flavors).
  - Triage transitions emitted (picked_up + resolved discriminated by to.state.type).
  - Complexity-error fallback: provider returns batch with empty new-field arrays → existing 14 event_kinds still emit, new 5 don't.

**Scheduler:**
- `LinearWarmSchedulerTests` — start/stop lifecycle, tick fires after initial delay, multiple ticks at interval.
- `LinearColdSchedulerTests`:
  - `nextLocal4amMs(now:)` computation — boundary cases (3:59am, 4:00am, 5:00am).
  - Catch-up on start: stale offset → immediate tick.
  - Catch-up on start: fresh offset (< 24h) → wait for next 4am, no immediate tick.
  - Cancellation: stop() during sleep cancels Task.

**FTS:**
- `EventsFullTextStoreTests` — extended cases:
  - **Track-1 D2 carry-over fix:** event_kind `"issue_updated"` (not `"linear_issue_updated"`) with `body` payload key → indexed в FTS, BM25 search hits Linear description. Regression для D2 bug.
  - `linear_notification_received` event с `notification_title` payload → indexed, BM25 search hits notification title.

**Helpers:**
- `LinearSubscribedIssuesDiffTests` — set-diff produces correct added/removed.
- `LinearCustomViewsDiffTests` — diff produces created/updated/deleted correctly; updated detected via (name OR updatedAtMs) change.
- `LinearProjectMembershipsDiffTests` — set-diff by projectId.

**Privacy regression (extension of `RelayBodyLeakageTests`):**
- Notification title NOT leak в `presence_state.state_json`.
- Reaction emoji NOT leak в `presence_state.state_json`.
- Relation kind / triage state_name NOT leak в `presence_state.state_json`.

**Atomic write:**
- `WriteEventsOffsetsAndSnapshotsTests` — happy path; partial arrays (events only / offsets only / snapshots only / empty all); rollback on failure (inject invalid JSON in event payload → no offsets updated, no snapshots written).

### Moat tests (`LeafCorePrivateTests`, `ProdLinearGraphQLProviderTests`)

Fixture-based GraphQL response decoding:
- `fetchIssues` response with reactions fragment → correct `LinearCommentReactionSnapshot[]` populated, only viewer's filtered.
- `fetchIssues` response with relation history → correct relation_added / relation_removed snapshots.
- `fetchIssues` response with triage history → correct triage_picked_up / triage_resolved discriminated by to.state.type.
- `fetchIssues` response with complexity error → empty new-field arrays, existing data still decoded.
- `fetchWarmState` response → `LinearWarmBatch` decoded correctly: 3 notification flavors derived from same record (createdAt/readAt/archivedAt fields), cycle started/completed bucketed correctly.
- `fetchWarmState` partial response (notifications populated + subscribed null) → batch fields reflect partiality.
- `fetchColdState` response → `LinearColdBatch` decoded: roadmaps with multiple projects, customViews with team scope, memberships.

---

## 11. Acceptance criteria (D1 sub-phase)

Before merge of stack into main (after Track 3 D4 acceptance), this sub-phase must verify:

1. **All 9 Linear endpoint clusters poll'ятся w/o errors** на real Linear workspace (manual smoke на собственных рабочих данных).
2. **18 new event_kinds emit'ятся** при соответствующих действиях:
   - Comment reaction on own comment → `linear_comment_reaction_added` row.
   - Add relation to issue → `linear_relation_added` row; remove → `_removed`.
   - Move issue out of triage state → `linear_triage_item_picked_up` (если not completion-bound) или `_resolved` (если completion-bound).
   - Receive @-mention notification → `linear_notification_received` row with title в FTS index.
   - Mark notification read → `linear_notification_read` row.
   - Archive notification → `linear_notification_archived` row.
   - Subscribe to issue → `linear_subscription_added` row; unsubscribe → `_removed`.
   - Cycle starts (its startsAt passes) → `linear_cycle_started` row.
   - Cycle completes (endsAt passes OR manual complete) → `linear_cycle_completed` row.
   - Roadmap viewed at 4am cold tick → `linear_roadmap_state_observed` row per (roadmap × project) pair.
   - Create custom view → `linear_custom_view_created` row (next cold tick); update → `_updated`; delete → `_deleted`.
   - Added to project → `linear_project_membership_added` row (next cold tick); removed → `_removed`.
3. **ShareEventTypeKey registry shows 66 entries** (48 + 18, all 18 new default OFF). Confirmed via test assertion + manual count.
4. **Track-1 D2 carry-over fix verified:** FTS test confirms Linear descriptions hit index after fix (was broken pre-D1). UC1/UC3 для Linear bodies теперь работают (manual smoke: BM25 search over commit-message-like description text hits result).
5. **`provider_snapshots` table populated** after first warm + cold tick on real workspace. Manual SQL inspection: `SELECT * FROM provider_snapshots` shows 4 rows (linear_subscribed_issues + 3 cold snapshots).
6. **Diff produces correct added/removed events on second tick:** verified via test fixtures (substrate) + manual smoke (subscribe to new issue → next warm tick emits `linear_subscription_added`).
7. **Cold catch-up:** stopping app + waiting > 24h + restarting → cold tick fires within ~10 seconds of restart (manual smoke or test with mock clock).
8. **Complexity-error fallback test passes** (stubbed response in moat test).
9. **Partial batch fallback test passes** (warm tick stub: notifications populated + cycles empty → only notification cursor advances).
10. **Bootstrap cap verified:** first warm tick on fresh integration (no prior cursors) fetches ≤ 7 days of notifications (manual smoke на real workspace + test assertion).
11. **SPM test count growth verified:** 1213 baseline → ~1253-1263 (target +40-50).
12. **5/5 xcodebuild schemes green** (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
13. **No regression в existing 14 Linear event_kinds:** `LinearCollectorTests` + `RelayBodyLeakageTests` stay green.
14. **Cold scheduler shuts down cleanly** on `AgentLifetime.shutdown()` (no orphaned Task — verified via cancellation test + manual log inspection).
15. **No new GraphQL complexity violations** on real workspace (manual bench during smoke pass; OQ-3 закрывается).

---

## 12. Open questions

- **OQ-D1-1:** Linear's GraphQL schema does not expose `linear:notifications` updatedAt filter universally — some Linear versions require `createdAt` filter. Verify in implementation: if `updatedAt` filter unavailable → fall back to `createdAt > since` filter + client-side detection of read/archived transitions через separate previous-snapshot diff (would require additional `linear_notifications_state` snapshot kind). Resolution path documented in code comments at fallback.
- **OQ-D1-2:** `linear_cycle_completed` for cycles where `endsAt` passes but admin doesn't mark complete — emit при passing endsAt automatically? Spec choice: yes, emit at endsAt boundary (mirror "auto-archive" behavior in Linear UI). Document edge: re-opened cycle (admin sets `completedAt` to null after our emission) — leaves orphan event; accepted as edge case.
- **OQ-D1-3:** `linear_roadmap_state_observed` heartbeat-per-tick может flood events table если user has many roadmaps with many projects. Cap? Spec choice: no cap для MVP (Linear workspaces typically ≤ 10 roadmaps × ≤ 50 projects = ≤ 500 events/day). If real users hit cardinality issues — D1.1 patch для cap.
- **OQ-D1-4:** `linear_custom_view_updated` detection via (name OR updatedAtMs) — Linear may bump `updatedAtMs` on benign access (re-render). Test on real workspace whether this triggers false-positive `_updated` events. If yes, drop `updatedAtMs` from diff trigger, use `name` change only.

---

## 13. Out of scope

- GitHub deep sweep — D2.
- Slack deep sweep — D3.
- FTS dispatcher для GitHub/Slack new bodies — D4.
- Share Controls UI pagination для 60+ entry registry — D4.
- OAuth re-auth UX banners — D2.
- Phase 5.6 invite auto-poll — separate track.
- Whitepaper sync — post-Track-3 collective merge per design spec §13.

---

## 14. Dependencies

- Track-1 D3 substrate (FTS + event_links + DetectorPipeline) — landed ✅
- Track-2 D4 substrate (design system) — landed ✅ (D1 не трогает UI; design system только wiring через future Activity tab if surfaced)
- ADR-010 §6 amendment (bodies on-device only) — in force ✅
- ADR-020 (Share Controls opt-in) — in force ✅

---

## 15. Risk

- **Linear GraphQL complexity ceiling на large workspaces:** D1 piggy-back fragments могут push `fetchIssues` query over per-query limit on workspaces with high-cardinality issue.history. Mitigation — defensive complexity-error fallback (§8, mirrors Track 4.7.C precedent).
- **Notification backlog flood on bootstrap:** first warm tick on fresh integration could emit hundreds of `linear_notification_received` events. Mitigation — 7-day bootstrap cap (§8); UC1/UC3 search still works because FTS indexes everything regardless.
- **Cold scheduler timezone drift:** if user travels across timezones, `nextLocal4amMs` shifts. Acceptable — cold tier is off-hours rough, not precision timing.
- **`provider_snapshots` table grows unbounded:** never — composite PK (provider, snapshot_kind) caps at 4 rows for D1 (5+ rows post-D2/D3). No retention needed.
- **Track-1 D2 carry-over fix touches existing FTS path:** could regress existing FTS coverage if test missed. Mitigation — explicit regression test (§6).
