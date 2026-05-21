# Track-9 T3 — GitHub INBOX feeder + payload enrichment + Slack DM verify

**Status:** APPROVED (Stage 3, awaiting user spec-review gate).
**Track-9 master design:** [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md).
**T1 spec (precedent — payload field extension pattern):** [`2026-05-19-track-9-T1-collector-payload-extensions.md`](./2026-05-19-track-9-T1-collector-payload-extensions.md).
**T2 spec (precedent — Linear inbox feeder pattern):** [`2026-05-20-track-9-T2-linear-inbox-feeder.md`](./2026-05-20-track-9-T2-linear-inbox-feeder.md).
**Branch:** `feature/track-9-substrate` (off `feature/phase-8-1-substrate` `e659b9e5`, currently at T2 tip `5ec26f58`).
**Ship classification:** Substrate-only, silent — UI без изменений, INBOX rows fade in только когда `gh_pr_review_requested` / `gh_pr_review_request_removed` ShareEventTypeKey toggled ON в Privacy → Share Controls (default OFF per ADR-020). GitHub notifications inbox surfaces appear automatically через deriver-side synthesis из existing `gh_notifications_pulse` substrate (без новых registry entries).

---

## 1. Scope

**In scope:**

1. **2 new event_kinds**: `gh_pr_review_requested` + `gh_pr_review_request_removed`. Capture-path emission через `mapPullRequestEvent` switch расширение на новые `payload.action` values из `/users/<login>/events` REST polling.
2. **Universal URL payload enrichment** на 15 event_kinds (8 `gh_pr_*` + 5 `gh_issue_*` + 2 `comment_url` overlay): `pr_url`, `issue_url`, `comment_url` composed at parser boundary inside `ProdGitHubAPIProvider` moat. Forward-only — historical events stay unenriched, T8 deriver synthesizes from `(repoFullName, number)` refs.
3. **`presence_state.github.viewer_login` finalization** — single-line addition к existing `githubPresence` composite dict в `GitHubCollector.swift:326-335`. Provisioning уже сделан OAuth bootstrap (login passed parameter в каждый fetch method); T3 только pip'ает его в presence dict.
4. **`gh_notification_received` deriver-side synthesis** в `ProdInsights+InboxItems` moat — НЕ новый capture-path event_kind. Reads `gh_notifications_pulse` last-2-ticks diff на `reason_review_requested_count` / `reason_mention_count` / `reason_comment_count` / `reason_assigned_count` / `reason_state_change_count` keys → synthesizes InboxItem per non-zero positive delta. Zero new registry entries.
5. **Slack DM verify outcome** — Discovery confirmed substrate отсутствует целиком: нет `slack_dm_received` event_kind, нет emission path в `SlackCollector`, нет registry entry. **Carry post-Track-9** per master spec §4 T3 line 168 conditional.
6. **ShareEventTypeKey registry** +2 entries: `githubPRReviewRequested = "gh_pr_review_requested"` + `githubPRReviewRequestRemoved = "gh_pr_review_request_removed"`, both default OFF. Registry 196 → 198.
7. **GitHubEventKindKey enum** +2 cases (`prReviewRequested`, `prReviewRequestRemoved`).
8. **`ActivityFeedMapper.mapGitHub`** +2 cases (mirror existing `gh_pr_review_submitted` row shape — outbound activity narrating).
9. **`EventKindIcon`** +2 SF Symbol mappings (`person.crop.circle.badge.plus` for review_requested, `person.crop.circle.badge.minus` for removed — confirm in plan).
10. **`DispatchCoverageTests` GitHub parity fence extension** — add 2 new event_kinds во все 4 aspect arrays (registry / defaults / icon / mapper allowlist).
11. **`ProdInsights+InboxItems` extension** (LeafCorePrivate moat): (a) replace stub `queryReviewRequests` → reads `gh_pr_review_requested` events filtered by client-side criterion (see §3.4); (b) extend `queryCommentsOnMyWork` adding GitHub branch (sibling to T2's Linear branch — Discovery confirmed T2 added separate `queryLinearCommentsOnMyWork` method); (c) new `queryGitHubNotifications` synthesizing InboxItems from notifications_pulse diff.
12. **3 sentinel-injection regression tests + 1 integration sweep** в `RelayBodyLeakageTests` mapping к master spec §6 invariants 5 (URLs), 6 (gh_pr_review_requested/_removed), 7 (viewer_login presence dict key).

**Hard exclusion (out of T3 — carry list):**

- **`gh_notification_received` as capture-path event_kind** — DEVIATION от master spec §5.1 line 242 (см. §1.1 ниже). Deriver-side synthesis preferred over duplicate capture.
- **Retroactive URL backfill** for events already in DB — T8 `InboxSourceURLDeriver` handles historical rows via ref composition. Carry T8.
- **Slack DM bucket routing into INBOX** — substrate отсутствует целиком. Carry post-Track-9. Master spec §5.1 line 245 conditional resolved as NO.
- **GraphQL viewer{login} query OR REST /user bootstrap call** — Discovery showed `login` parameter уже passed в каждый fetch method, provisioning уже done at OAuth completion. T3 не вводит new HTTP.
- **Cross-actor anonymization buckets for `requested_reviewer.login`** — pattern parity с existing `prMetadata.requestedReviewers: [String]` (Track-3 D2 plaintext logins). Privacy frontier уже crossed; T3 не вводит new delta. См. §2 D-5.
- **`/notifications` per-row polling** for per-notification ID tracking — `fetchNotifications` Phase 4.7.B returns summary tuple `(totalUnread, byReason)`, не raw notification rows. Per-row polling требует new GitHub API call (`GET /notifications?per_page=50` parse each row's `subject.url` + `subject.type` + `reason`) — substantial scope, carry post-Track-9.
- **UI surface changes (HomeView, InboxBlock, Settings)** — none. Existing Privacy → Share Controls auto-lists new registry entries.
- T5 YOU·NOW branch deriver / T6 hybrid pills / T7 WHERE STOPPED depth / T8 InboxKind expansion / T9 Analytics UI — separate phases per master design.

### 1.1 Deviations from Track-9 master spec §4 T3 + §5

Master spec line 167 + §5.1 line 242:
> `fetchNotifications` snapshot diff → synthetic `gh_notification_received` InboxItem feeder (derive from `presence_state.github.notifications` diff).
> | `gh_notification_received` | T3 | OFF | Synthesized from `fetchNotifications` snapshot diff (4.7.B) |

**T3 implements deriver-side synthesis ONLY (not a capture-path event_kind).** Reason (post-Stage-1 Discovery): `gh_notifications_pulse` substrate already exists Phase 4.7.B — emits each tick with `reason_review_requested_count` / `reason_mention_count` / etc. top-level keys в payload (`GitHubCollector.swift:378-397`). Adding `gh_notification_received` как capture-path kind duplicates emission поверх existing pulse — neither adds signal nor enables new use case. Deriver reads last 2 pulse rows + diff'ает per-reason counters → synthesizes InboxItems on-the-fly, тот же pattern что и D3 detection tables (decisions/open_questions/blockers — derived rows из existing events, не capture-path).

**Net deltas updated:**
- ShareEventTypeKey registry +**2** (not +3): only `githubPRReviewRequested` + `githubPRReviewRequestRemoved`.
- No new `ActivityFeedMapper` case for synthetic notifications (synthetic InboxItems don't surface in Activity tab — they're InboxBlock-only).
- No new `EventKindIcon` mapping for `gh_notification_received` (rendered as InboxItem icon at UI layer T8).

Master spec §4 T3 + §5.1 + §5.3 to be amended in T10 wrap. T3 spec is the authoritative implementation contract (T1/T2 precedent для deviation pattern).

Master spec line 244 (`slack_dm_received`):
> | `slack_dm_received` | T3 | OFF | **Conditional** — only if substrate verify confirms emission today; else carry |

**Verify outcome: NEGATIVE.** `SlackEventKinds.swift` 21 cases, no DM-related kind. `SlackCollector` 923 LOC, no DM-fetch path, no DM emission. `ShareEventTypeRegistry` no Slack DM entry. `presence_state.slack` composite has no DM-bucket field. Conclusion: Slack DM substrate absent at all 4 layers. **Carry post-Track-9** — separate phase needed для (a) `conversations.list` types=`im` polling + (b) `slack_dm_received` event_kind + (c) registry entry + (d) ADR-010 walkback discipline для DM channel anonymization (per architecture.md "DM channels anonymized → "DM" bucket до записи").

---

## 2. Decisions taken (Stage 2 brainstorm output)

| # | Question | Decision | Rationale |
|---|---|---|---|
| D-1 | `gh_notification_received` emission point | **Deriver-side synthesis** (НЕ capture-path event_kind). `ProdInsights+InboxItems.queryGitHubNotifications` reads last-2-tick `gh_notifications_pulse` rows + diffs per-reason counters → synthesizes InboxItems on-the-fly. | `gh_notifications_pulse` substrate уже ships reason buckets per tick (Phase 4.7.B, `GitHubCollector.swift:378-397`). Capture-path duplicate adds no signal. Mirror D3 detection tables pattern (derived rows из existing events, не capture-path). Drops registry delta с +3 на +2. |
| D-2 | URL enrichment scope | **15 event_kinds, forward-only** (8 `gh_pr_*` + 5 `gh_issue_*` + 2 `comment_url` overlay на existing comment kinds). Composition at parser boundary в `ProdGitHubAPIProvider` moat. | Master spec §4 T3 line 165 explicit "across all `gh_pr_*` / `gh_issue_*` event_kinds". Excludes: state pulses (`gh_notifications_pulse` / `_count`), branch/tag/release kinds (no PR/issue context), discussion kinds (different URL shape). Forward-only — historical rows synthesized T8 deriver from `(repoFullName, number)`. |
| D-3 | URL composition formulas | `pr_url = "https://github.com/{repoFullName}/pull/{number}"`, `issue_url = "https://github.com/{repoFullName}/issues/{number}"`, `comment_url = pr_url + "#issuecomment-{comment_id}"` (issue_comment) или `pr_url + "#discussion_r{comment_id}"` (pr_review_comment_authored). | Standard GitHub URL grammar. Composition в moat — public-safe (repoFullName + number опубликованы любым PR/issue link сегодня). Comment_id уже в payload metadata (Phase 4.7.A added `comment_id` to `GitHubEventSnapshot.metadata`). |
| D-4 | Forward-only vs retroactive URL backfill | **Forward-only.** Historical events stay unenriched. T8 `InboxSourceURLDeriver` synthesizes URLs from `(repoFullName, number)` refs at deriver boundary. | Mirror T2 `linear_issue_url` precedent (T2 forward-only on new `linear_comment_authored_to_me` emissions; historical Linear events unenriched). Retroactive update requires bulk SQL UPDATE на `payload_json` — risk + scope для тесного phase. |
| D-5 | `requested_reviewer.login` privacy treatment | **Plaintext `requested_reviewer_login: String`** в payload, NO anonymization buckets. | Pattern parity с existing `prMetadata.requestedReviewers: [String]` (Track-3 D2, `ProdGitHubAPIProvider.swift:1114-1117` — plaintext logins of reviewers in `gh_pr_opened`). Privacy frontier уже crossed; T3 не вводит new delta. Linear 4.7.C 7-bucket anonymization применима к assignee transitions (high-volume cross-actor graph aggregation risk), не к binary single-target review request (single login per event). |
| D-6 | `viewer_login` provisioning mechanism | **Single-line addition** `"viewer_login": login` (или NSNull при empty) в existing `githubPresence` composite dict в `GitHubCollector.swift:326-335`. Zero new HTTP. | Discovery: `login: String` parameter уже в scope `runOnce()` метода — passed в `provider.fetchEvents(login:)`, `fetchPRsAwaitingReview(login:)`, и т.д. Provisioning happened at OAuth completion (cached в `integrations` row). T3 finalizes intent stated в `ProdInsights+InboxItems.swift:66-73` comment. |
| D-7 | Parse path для `gh_pr_review_requested/_removed` | **2 new switch cases в existing `mapPullRequestEvent` switch** (`ProdGitHubAPIProvider.swift:1071-1086`). `action="review_requested"` → kind=prReviewRequested, `action="review_request_removed"` → kind=prReviewRequestRemoved. | Existing switch silent-skips эти actions через `default: kind = nil`. Extension trivial — 2 new cases preserve existing infrastructure (linkedID extraction, body cap, attachments, prMetadata). |
| D-8 | `gh_pr_review_requested` payload shape | Reuse existing `GitHubEventSnapshot` shell — `metadata` extension slot gets `["requested_reviewer_login": "<login>"]`. No new struct field. | Phase 4.7.A precedent — `metadata: [String: String]?` is the extension slot для per-kind additions ("Phase 4.7.A — extension slot для new event_kinds с per-kind payload fields", line 197-200). T3 не вводит new struct fields. |
| D-9 | Cold-tick when `requested_reviewer` payload absent (stripped feed) | Skip emission (return `[]` from this branch). | GitHub stripped feed может не отдать `payload.requested_reviewer` field. ADR-010 safety — better drop event than emit with empty/sentinel login. Mirror existing T3 D2 hot/warm/cold pattern (`fetchActionsRunsForActor` line 432-433 uses similar guard). |
| D-10 | ShareEventTypeKey delta | **+2 entries** (`githubPRReviewRequested`, `githubPRReviewRequestRemoved`), both default OFF. Registry 196 → 198. | Slack DM verify NEGATIVE (Q1.1) + `gh_notification_received` deriver-side (Q1.1) → only 2 registry rows added. Master spec §5.3 said +3 to +4; T3 ships +2. T10 amendment. |
| D-11 | `ProdInsights+InboxItems` extension strategy | 3 separate methods: (a) **new** `queryReviewRequests(cutoffMs:)` — reads `gh_pr_review_requested` events client-side filter `actor.login != viewer_login` (see §3.4 nuance), routes к `.reviewRequest` InboxKind. (b) **extend** `queryCommentsOnMyWork` adding GitHub branch (T2 added separate `queryLinearCommentsOnMyWork` — symmetric pattern keeps method per provider). (c) **new** `queryGitHubNotifications(cutoffMs:)` — reads last-2-tick pulse rows + diffs reason counters → synthetic InboxItems. | T2 precedent (Linear separate method, not branched into shared method). Three methods symmetric — Linear/GitHub/notification synthesis isolated. |
| D-12 | `queryReviewRequests` filter semantics | Phase 4.7.A `mapPullRequestEvent` emits `gh_pr_review_requested` events **только когда я был actor** (`/users/<login>/events` returns only viewer's events — see Discovery insight #1). Это **outbound** events. Inbound ("X requested MY review") уже surfaced через `gh_notifications_pulse.reason_review_requested_count`. So `queryReviewRequests` reads outbound events filtered by **recency** (cutoffMs window), not by actor identity. UI surfaces "I requested review N times this week". | Discovery confirmed: `/users/<login>/events` REST polling returns events viewer performed. `actor.login == viewer_login` by definition. Inbound flow uses notifications synthesis separately. |
| D-13 | InboxItem field mapping для `gh_pr_review_requested` | `kind=.reviewRequest` / `severity=.muted` / `title="<repoFullName>#<number>"` / `sourceMeta="GitHub · <repoFullName>#<number>"` / `sourceURL=URL(pr_url)` / `aggregatedCount=count per (repoFullName, number)` / `createdAtMs=latest createdAt`. | Aggregation key = PR identity. Multiple requests on same PR (e.g., re-request after dismiss) collapse to 1 row. Severity `.muted` — review request informational, not blocking. |
| D-14 | InboxItem field mapping для GitHub notifications synthesis | One InboxItem per non-zero positive diff in `reason_X_count` between two consecutive pulse ticks. `kind` from reason: `review_requested → .reviewRequest`, `mention → .mention`, `comment → .commentOnMyWork`, `assigned → .commentOnMyWork` (carry: existing 5 enum cases — no exact "assigned" or "state_change" semantic; map к closest). | InboxKind expansion = T8 scope; T3 reuses existing 5 cases. Master spec §3.4 line 108 lists T8 InboxKind expansion as separate phase. Imperfect mapping accepted — T8 fixes. |
| D-15 | Sentinel-injection test grouping | **3 per-invariant tests + 1 integration sweep** в `RelayBodyLeakageTests`. Per-invariant pinpoints regression. | T1 lineage (3 per-field + 1 sweep). T2 used single test потому что only 1 new payload field. T3 multiple new fields → per-invariant decomposition (URLs / review_requested+removed / viewer_login). |
| D-16 | Sentinel constants | `LEAKED_SENTINEL_GH_T3_PR_BODY` (PR body injection → assert URL fields clean) / `LEAKED_SENTINEL_GH_T3_REVIEWER` (requested_reviewer position injection → assert no body field polluted) / `LEAKED_SENTINEL_GH_T3_VIEWER_LOGIN` (presence_state.github.viewer_login slot assert correct write + sentinel sweep). | T1 lineage username-position pattern (sentinel injected at position which MUST NOT leak; structurally-correct positions preserve). |
| D-17 | DispatchCoverageTests parity fence | **Extend existing GitHub fence** — add 2 new event_kinds (`gh_pr_review_requested`, `gh_pr_review_request_removed`) ко всем 4 aspect arrays (registry / defaults / icon / mapper allowlist). No new fence test. | T2 precedent: "Add to existing fence, не add new fence". |
| D-18 | EventKindIcon mappings | `gh_pr_review_requested → "person.crop.circle.badge.plus"`, `gh_pr_review_request_removed → "person.crop.circle.badge.minus"`. Confirm in plan vs `arrow.up.message.fill` / `bell.badge`. | SF Symbol semantic match — adding/removing a person from review queue. Mirror existing GitHub icon vocabulary (`gh_pr_review_submitted → "checkmark.bubble.fill"` per icon file pattern). |
| D-19 | ActivityFeedMapper extension | **+2 cases в `mapGitHub` switch**. Outbound activity narrating — label "GitHub: requested review on <repo>#<n>" / "GitHub: dropped review request on <repo>#<n>". Allowlist-only payload reads (`repoFullName`, `number`, `requested_reviewer_login` — opaque login, no privacy leak per D-5). | Mirror existing `gh_pr_review_submitted` row shape. Activity tab uses allowlist payload extraction (D2 dispatcher). |
| D-20 | Migrations | **0 new SQLCipher migrations.** Total tables preserved (M001-M018 + M024 + M026 + M027 = 30 baseline + Track-9 T1 = 0 delta + T2 = 0 delta = **30**). Track-9 has migrations only at T7 (M028 carved out для where_stopped_log column). | Master spec §5.2 — M028 is T7's scope, not T3. T3 adds no DDL. |
| D-21 | MCP tools | **0 new tools.** | Confirmed by master spec §5.5. |
| D-22 | Settings UI | **None.** Privacy → Share Controls auto-lists new registry entries. | No code change в `SystemObserversSettingsSection` / `PrivacyControlsSection`. |
| D-23 | Tests split: public vs LeafCorePrivate moat | **Public** (`LeafCoreTests`): sentinel-injection regression + DispatchCoverageTests fence + Snapshot round-trip + Collector emission test for new kinds + ShareEventTypeKey registry parity fence bumps. **Moat** (`LeafCorePrivateTests`): `mapPullRequestEvent` switch new cases unit tests + URL composition unit tests + `queryReviewRequests` SQL/fixture tests + `queryCommentsOnMyWork` GitHub branch tests + `queryGitHubNotifications` synthesis tests. | T1/T2 precedent. Provider classification logic + SQL stay in moat (DB shape + GraphQL parse moat-only); higher-level invariants public. |
| D-24 | Branch off | `feature/track-9-substrate` at T2 tip `5ec26f58`. FF после T3 acceptance. | Mirror T2 off-T1 chain. T3..T9 sequence на same collective branch. |

---

## 3. Architecture

### 3.1 Component map

```
Agent process
├── GitHubCollector.runOnce() (LeafCore/Collectors, public)
│   ├── existing flow (Phase 4.7.B):
│   │   ├── refreshed.accessToken + login (from integrations row)
│   │   ├── provider.fetchEvents(accessToken, login, since) → batch of GitHubEventSnapshot
│   │   ├── provider.fetchNotifications → summary (totalUnread + byReason dict)
│   │   ├── provider.fetchPRsAwaitingReview / fetchMyOpenPRs / fetchActionsRunsForActor / fetchContributionsCalendar
│   │   ├── makeEvent(snapshot:) → RawEvent с payload включает {pr_url|issue_url|comment_url} (NEW from T3)
│   │   ├── makeNotificationsPulseEvent(summary:) → unchanged
│   │   └── buildGitHubPresenceState(...) → presence_state.github composite
│   ├── NEW: snapshots для kind ∈ {gh_pr_review_requested, gh_pr_review_request_removed} emit'ятся через existing makeEvent path
│   └── NEW: githubPresence dict gets +1 key "viewer_login": login (or NSNull when empty)
│
├── ProdGitHubAPIProvider.mapPullRequestEvent (LeafCorePrivate moat)
│   ├── existing switch on payload.action:
│   │   ├── case "opened" → "gh_pr_opened"
│   │   ├── case "closed" → "gh_pr_closed" / "gh_pr_merged" (if merged:true)
│   │   ├── case "merged" → "gh_pr_merged" (squash/rebase normalized form)
│   │   └── default → silent skip
│   ├── NEW: case "review_requested" → "gh_pr_review_requested" with metadata["requested_reviewer_login"]
│   └── NEW: case "review_request_removed" → "gh_pr_review_request_removed" with metadata["requested_reviewer_login"]
│
├── ProdGitHubAPIProvider.buildSnapshotPayload (LeafCorePrivate moat, NEW helper or inline at makeEvent)
│   └── для kind ∈ {gh_pr_*, gh_issue_*}: compose pr_url / issue_url / comment_url at boundary
│       └── push composed URL into snapshot.metadata or pass through to GitHubCollector.makeEvent payload
│
MenuBarApp / MCP processes (read-only)
└── ProdInsights+InboxItems (LeafCorePrivate moat)
    ├── existing T2: queryLinearCommentsOnMyWork → Linear branch fed
    ├── existing stub: queryCommentsOnMyWork → []
    │   └── NEW T3: queries gh_pr_review_comment_authored + gh_issue_comment_authored events,
    │       filter actor.login != viewer_login (read viewer_login from presence_state.github),
    │       (kind, sourceURL=pr_url||issue_url||comment_url) aggregation
    ├── existing stub: queryReviewRequests → []
    │   └── NEW T3: queries gh_pr_review_requested events (outbound activity),
    │       aggregate by (repoFullName, number), surface in InboxBlock with .reviewRequest kind
    └── NEW T3: queryGitHubNotifications(cutoffMs:)
        └── reads last-2-tick gh_notifications_pulse rows, diffs reason counters,
            synthesizes InboxItem per non-zero positive delta
```

### 3.2 Data flow

T3 emits — T8 InboxBlock consumes. T3 ships substrate; T8 lights up full Inbox surface routing.

```
events table after T3:
  payload_json[event_kind in gh_pr_*]:
    { event_kind, repo_full_name, number, title, ..., pr_url? }       ← pr_url ADDED (Optional)

  payload_json[event_kind in gh_issue_*]:
    { event_kind, repo_full_name, number, title, ..., issue_url? }    ← issue_url ADDED

  payload_json[event_kind in (gh_pr_review_comment_authored, gh_issue_comment_authored)]:
    { ..., pr_url? || issue_url?, comment_url? }                       ← +comment_url overlay

  payload_json[event_kind = "gh_pr_review_requested"]:
    { event_kind, repo_full_name, number, title, requested_reviewer_login, pr_url? }   ← NEW kind

  payload_json[event_kind = "gh_pr_review_request_removed"]:
    { event_kind, repo_full_name, number, title, requested_reviewer_login, pr_url? }   ← NEW kind

presence_state.github composite after T3:
  state_json:
    { notifications_unread, notifications_by_reason, prs_awaiting_my_review, ...
      viewer_login }                                                   ← viewer_login ADDED (or null)
```

### 3.3 `mapPullRequestEvent` extension (ProdGitHubAPIProvider moat)

Current switch (`ProdGitHubAPIProvider.swift:1071-1086`):

```swift
let kind: String?
switch action {
case "opened":
    kind = "gh_pr_opened"
case "closed":
    let merged = (pr["merged"] as? Bool) ?? false
    kind = merged ? "gh_pr_merged" : "gh_pr_closed"
case "merged":
    kind = "gh_pr_merged"
default:
    kind = nil    // silent skip — reopened / assigned / labeled / review_requested / etc
}
```

T3 extension:

```swift
let kind: String?
let extraMetadata: [String: String]?
switch action {
case "opened":
    kind = "gh_pr_opened"
    extraMetadata = nil
case "closed":
    let merged = (pr["merged"] as? Bool) ?? false
    kind = merged ? "gh_pr_merged" : "gh_pr_closed"
    extraMetadata = nil
case "merged":
    kind = "gh_pr_merged"
    extraMetadata = nil
case "review_requested":
    // payload.requested_reviewer.login is the just-added reviewer (singular).
    // Stripped feed may omit this — guard skip emission per D-9.
    guard let reviewer = payload["requested_reviewer"] as? [String: Any],
          let reviewerLogin = reviewer["login"] as? String,
          !reviewerLogin.isEmpty
    else { return [] }
    kind = "gh_pr_review_requested"
    extraMetadata = ["requested_reviewer_login": reviewerLogin]
case "review_request_removed":
    guard let reviewer = payload["requested_reviewer"] as? [String: Any],
          let reviewerLogin = reviewer["login"] as? String,
          !reviewerLogin.isEmpty
    else { return [] }
    kind = "gh_pr_review_request_removed"
    extraMetadata = ["requested_reviewer_login": reviewerLogin]
default:
    kind = nil
    extraMetadata = nil
}
guard let kind else { return [] }
```

`extraMetadata` merges into existing `metadata` dict (currently carries `linked_linear_id` for new kinds). Both `gh_pr_review_requested` and `_removed` get `requested_reviewer_login` plus optional `linked_linear_id` from title.

### 3.4 URL composition at parser boundary

Inline helper (or static method) on `ProdGitHubAPIProvider`:

```swift
private static func composePRURL(repoFullName: String, number: Int) -> String? {
    guard !repoFullName.isEmpty, number > 0 else { return nil }
    return "https://github.com/\(repoFullName)/pull/\(number)"
}

private static func composeIssueURL(repoFullName: String, number: Int) -> String? {
    guard !repoFullName.isEmpty, number > 0 else { return nil }
    return "https://github.com/\(repoFullName)/issues/\(number)"
}

private static func composeCommentURL(parentURL: String?, commentID: String?, commentKind: CommentKind) -> String? {
    guard let parentURL, let commentID, !commentID.isEmpty else { return nil }
    let anchor = commentKind == .reviewComment ? "discussion_r" : "issuecomment-"
    return parentURL + "#\(anchor)\(commentID)"
}
```

URL composition is **structurally-correct** — only composes from `(repoFullName, number, commentID)` (all public-safe refs). NEVER reads title / body / comment text. Sentinel test §5.4 guards.

**Per-event-kind URL field placement:**

| Event kind | Field(s) added | Computed from |
|---|---|---|
| `gh_pr_opened` / `_merged` / `_closed` | `pr_url` | `(repoFullName, number)` |
| `gh_pr_review_submitted` | `pr_url` | `(repoFullName, number)` |
| `gh_pr_review_thread_resolved` | `pr_url` | `(repoFullName, number)` |
| `gh_pr_review_requested` / `_removed` | `pr_url` | `(repoFullName, number)` |
| `gh_pr_review_comment_authored` | `pr_url` + `comment_url` | parent PR URL + `comment_id` |
| `gh_issue_opened` / `_closed` / `_locked` / `_unlocked` | `issue_url` | `(repoFullName, number)` |
| `gh_issue_comment_authored` | `issue_url` + `comment_url` | parent issue URL + `comment_id` |

**15 event_kinds = 8 `gh_pr_*` (3 baseline opened/merged/closed + 4.6/4.7.A: review_submitted/review_comment_authored/review_thread_resolved + 2 new from T3: review_requested/_removed) + 5 `gh_issue_*` (opened/closed/locked/unlocked/comment_authored) + 2 overlays (`comment_url` on the 2 comment kinds).**

URL fields written into `GitHubEventSnapshot.metadata` dict (Phase 4.7.A extension slot). `GitHubCollector.makeEvent` reads metadata as-is into RawEvent payload (existing flow at `GitHubCollector.swift:505-585`).

### 3.5 `viewer_login` provisioning + presence dict write

`GitHubCollector.runOnce(...)` already has `login` parameter (from refreshed integration row):

```swift
// At GitHubCollector.swift:326-335 — existing composite write
let githubPresence: [String: Any] = [
    "notifications_unread": notifSummary.totalUnread,
    "notifications_by_reason": notifSummary.byReason,
    "prs_awaiting_my_review": reviewQueueSummary.count,
    "prs_awaiting_top_repo": reviewQueueSummary.topRepo.map { $0 as Any } ?? NSNull(),
    "my_open_prs": myOpenPRsSummary.count,
    "latest_push_check_status": latestPushCheckStatus.map { $0 as Any } ?? NSNull(),
    "contributions_today": lastContributionsToday,
    "active_repos_count": activeRepos.count,
    "viewer_login": login.isEmpty ? NSNull() as Any : login,    // NEW T3
]
```

NSNull-on-empty mirrors existing 2 fields (`prs_awaiting_top_repo` + `latest_push_check_status` line 330 + 332) — distinguishes "key absent, field not tracked" from "key present, value null" (existing comment line 322-325 documents the convention).

Reader side (`ProdInsights+InboxItems.queryCommentsOnMyWork`): reads `presence_state.github.state_json`, extracts `viewer_login` string, uses for client-side filter `actor.login != viewer_login`. If `viewer_login` absent or NSNull → filter degrades to no-op (returns all comment events — graceful, no crash). Carry T8 если this proves noisy.

### 3.6 `ProdInsights+InboxItems` extension (moat)

#### 3.6.1 `queryReviewRequests` (replaces existing stub)

```swift
private func queryReviewRequests(cutoffMs: Int64) throws -> [InboxItem] {
    // Real query body lives in LeafCorePrivate moat.
    // Conceptually: read `gh_pr_review_requested` events from the action
    // stream with ts >= cutoffMs, aggregate per (repo_full_name, number)
    // — count of requests, latest timestamp, representative pr_url —
    // ordered most-recent first, mapped to InboxItem(kind: .reviewRequest,
    // severity: .muted, ...).
}
```

**Filter rationale**: `gh_pr_review_requested` from `/users/<login>/events` REST polling captures **outbound** review requests (viewer asked others). Inbound flow (others asked viewer) surfaced via `queryGitHubNotifications` synthesis. T8 InboxBlock UI can label this row "I requested review" vs notifications "Review requested of me" (T8 scope).

#### 3.6.2 `queryCommentsOnMyWork` GitHub branch extension

Replace `return []` stub with:

```swift
private func queryCommentsOnMyWork(cutoffMs: Int64) throws -> [InboxItem] {
    // Real query body lives in LeafCorePrivate moat.
    //
    // Step 1: read `viewer_login` from `presence_state.github.state_json`
    // (graceful degrade to [] if absent or empty).
    //
    // Step 2: aggregate `gh_pr_review_comment_authored` +
    // `gh_issue_comment_authored` events from the action stream with
    // ts >= cutoffMs, grouped per (repo_full_name, number), capturing
    // count, latest timestamp, and a representative parent URL (PR url
    // when present else issue url). Actor-self-exclusion filter is
    // anticipatory: `/users/<login>/events` REST polling currently
    // returns viewer-as-actor only, so the filter is a no-op today. T8
    // owns the InboxKind semantic split (.myRecentComments vs
    // .commentsByOthersOnMyWork) once an inbound-comment surface lands.
}
```

#### 3.6.3 `queryGitHubNotifications` synthesis

```swift
private func queryGitHubNotifications(cutoffMs: Int64) throws -> [InboxItem] {
    // Real query body lives in LeafCorePrivate moat.
    // Step 1: read the last 2 `gh_notifications_pulse` rows (context stream,
    // ts >= cutoffMs, ordered newest first, limit 2). Decode each payload
    // to extract `reason_*_count` keys.
    let rows: [(Int64, [String: Int])] = try /* moat helper */ []

    guard rows.count == 2 else { return [] }    // Need 2 ticks to diff

    let (latestTs, latestReasons) = rows[0]
    let (_, priorReasons) = rows[1]

    // For each reason where latest > prior, synthesize InboxItem with positive delta.
    let kinds: [(String, InboxKind)] = [
        ("review_requested", .reviewRequest),
        ("mention", .mention),
        ("comment", .commentOnMyWork),
        // "assigned" / "state_change" map к existing kinds heuristically — T8 enum expansion fixes
        ("assigned", .commentOnMyWork),
        ("state_change", .commentOnMyWork),
    ]

    var out: [InboxItem] = []
    for (reasonKey, inboxKind) in kinds {
        let latest = latestReasons[reasonKey] ?? 0
        let prior = priorReasons[reasonKey] ?? 0
        let delta = latest - prior
        guard delta > 0 else { continue }
        out.append(InboxItem(
            id: "ghNotif:\(reasonKey):\(latestTs)",
            kind: inboxKind,
            severity: .muted,
            title: "\(delta) new \(reasonKey) notification\(delta > 1 ? "s" : "")",
            sourceMeta: "GitHub · \(reasonKey)",
            sourceURL: URL(string: "https://github.com/notifications"),
            aggregatedCount: delta,
            createdAtMs: latestTs
        ))
    }
    return out
}
```

**Cold-tick degenerate**: Only one `gh_notifications_pulse` row in window → guard returns `[]`. No synthesis на first observation tick. Acceptable graceful behavior — InboxItems appear from second pulse onwards.

**Diff semantics**: Notifications can decay (`totalUnread` decreases как user reads them). Negative deltas dropped (means user dismissed notifications — не actionable). Only positive deltas synthesize InboxItems.

### 3.7 `ActivityFeedMapper` extension

Add 2 cases in `mapGitHub` switch:

```swift
case "gh_pr_review_requested":
    let repo = payload["repo_full_name"] ?? "?"
    let num = payload["number"] ?? "?"
    let reviewer = payload["requested_reviewer_login"] ?? "?"
    return ActivityFeedEntry(
        timestamp: timestamp,
        icon: EventKindIcon.icon(for: "gh_pr_review_requested"),
        label: "GitHub: requested review on \(repo)#\(num) (\(reviewer))",
        category: .layerB,
        eventKind: "gh_pr_review_requested"
    )

case "gh_pr_review_request_removed":
    let repo = payload["repo_full_name"] ?? "?"
    let num = payload["number"] ?? "?"
    let reviewer = payload["requested_reviewer_login"] ?? "?"
    return ActivityFeedEntry(
        timestamp: timestamp,
        icon: EventKindIcon.icon(for: "gh_pr_review_request_removed"),
        label: "GitHub: dropped review request on \(repo)#\(num) (\(reviewer))",
        category: .layerB,
        eventKind: "gh_pr_review_request_removed"
    )
```

Allowlist payload reads: `repo_full_name`, `number`, `requested_reviewer_login` (opaque plaintext login per D-5 — pattern parity с PRMetadata.requestedReviewers). NEVER reads `title` / `body`.

---

## 4. Implementation surface

### 4.1 Files touched

**Public (committed to leaf repo):**

| File | Change | Approx LOC |
|---|---|---|
| `Packages/LeafCore/Sources/LeafCore/Integrations/GitHub/GitHubEventKinds.swift` | +2 enum cases (`prReviewRequested`, `prReviewRequestRemoved`) + cumulative `allCases` if used | +4 |
| `Packages/LeafCore/Sources/LeafCore/Integrations/GitHub/GitHubAPIProvider.swift` | Docs comment update (Phase 4.7.A additions list line 174 + Track-9 T3 additions) — text-only | +6 docs |
| `Packages/LeafCore/Sources/LeafCore/Collectors/GitHubCollector.swift` | `githubPresence` dict +1 key (`viewer_login`); doc comment about T3 | +2 + 2 docs |
| `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | +2 enum cases `githubPRReviewRequested` + `githubPRReviewRequestRemoved` (`gh_pr_review_requested` + `gh_pr_review_request_removed`) | +2 |
| `Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift` | +2 cases в `mapGitHub` switch | +24 |
| `Packages/LeafCore/Sources/LeafCore/Insights/EventKindIcon.swift` | +2 SF Symbol mappings | +2 |
| `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` | +3 per-invariant tests + 1 integration sweep | +180 |
| `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` | +2 entries в GitHub enumeration arrays (all 4 aspects) | +8 |
| `Packages/LeafCore/Tests/LeafCoreTests/GitHubCollectorTests.swift` (or similar) | +3 tests: viewer_login round-trip + new kinds round-trip + URL field present | +90 |
| `Packages/LeafCore/Tests/LeafCoreTests/*ShareEventTypeRegistry*ParityTests.swift` (7 fence files per T2 precedent) | Bump count 196 → 198 in 7 historical track-baseline parity fences | +14 |

**LeafCorePrivate moat (gitignored, not pushed):**

| File | Change | Approx LOC |
|---|---|---|
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/ProdGitHubAPIProvider.swift` | (a) `mapPullRequestEvent` switch +2 cases с requested_reviewer parsing; (b) URL composition static helpers + injection into snapshot.metadata at 15 emission points; (c) related body cap / metadata merge for new kinds | +110 |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+InboxItems.swift` | (a) `queryReviewRequests` SQL impl; (b) `queryCommentsOnMyWork` GitHub branch SQL + viewer_login read; (c) `queryGitHubNotifications` synthesis impl | +120 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/ProdGitHubAPIProviderHotExtensionsTests.swift` (or new file) | +4 tests: `mapPullRequestEvent` `review_requested` case + `_removed` case + stripped-feed guard + URL composition unit | +120 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsInboxItemsTests.swift` | +4 tests: `queryReviewRequests` aggregation + `queryCommentsOnMyWork` GitHub branch filter + `queryGitHubNotifications` synthesis 2-tick diff + cold-tick degenerate | +180 |

**Estimated total LOC delta:** ~860 lines (public ~330 + moat ~530), 0 file deletions, 0 renames.

### 4.2 Atomic commit decomposition (preview — finalized in Stage 4 plan)

Tentative 10 commits (1 spec docs + 8 atomic feat/test + 1 registry fence bump):

1. `docs(track-9-T3): spec — GitHub INBOX feeder + URL enrichment + Slack DM verify`
2. `feat(track-9-T3): GitHubEventKindKey +2 cases + GitHubAPIProvider docs update`
3. `feat(track-9-T3): ProdGitHubAPIProvider URL composition + 15-kind injection` (moat)
4. `feat(track-9-T3): ProdGitHubAPIProvider mapPullRequestEvent +review_requested/_removed cases` (moat + 4 moat tests)
5. `feat(track-9-T3): GitHubCollector viewer_login presence dict finalization` (public + 1 test)
6. `feat(track-9-T3): ShareEventTypeKey +2 + EventKindIcon +2 + ActivityFeedMapper +2 + DispatchCoverageTests bump`
7. `feat(track-9-T3): ProdInsights+InboxItems queryReviewRequests + queryGitHubNotifications + queryCommentsOnMyWork GitHub branch` (moat + 4 moat tests)
8. `test(track-9-T3): 3 per-invariant sentinel-injection regressions + 1 integration sweep`
9. `test(track-9-T3): bump registry parity fences 196 -> 198`

Finalized commit order in Stage 4 plan (`writing-plans` skill).

---

## 5. Tests

### 5.1 Provider parse + URL composition (moat)

```swift
// ProdGitHubAPIProviderHotExtensionsTests.swift (moat)

func test_mapPullRequestEvent_reviewRequestedCase_emitsKindWithReviewerLogin() throws {
    let payload: [String: Any] = [
        "action": "review_requested",
        "pull_request": ["title": "Add feature X", "number": 42],
        "requested_reviewer": ["login": "octocat"],
    ]
    let events = parser.mapPullRequestEvent(
        eventID: "e1", repoFullName: "leaf/core",
        createdAtMs: 1715900000000, payload: payload, linearPrefixes: []
    )
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].eventKind, "gh_pr_review_requested")
    XCTAssertEqual(events[0].metadata?["requested_reviewer_login"], "octocat")
}

func test_mapPullRequestEvent_reviewRequestRemovedCase_emits() throws {
    let payload: [String: Any] = [
        "action": "review_request_removed",
        "pull_request": ["title": "X", "number": 7],
        "requested_reviewer": ["login": "alice"],
    ]
    let events = parser.mapPullRequestEvent(/* ... */)
    XCTAssertEqual(events[0].eventKind, "gh_pr_review_request_removed")
    XCTAssertEqual(events[0].metadata?["requested_reviewer_login"], "alice")
}

func test_mapPullRequestEvent_strippedFeed_noRequestedReviewer_skipsEmit() throws {
    let payload: [String: Any] = [
        "action": "review_requested",
        "pull_request": ["title": "X", "number": 7],
        // requested_reviewer omitted (stripped feed)
    ]
    let events = parser.mapPullRequestEvent(/* ... */)
    XCTAssertTrue(events.isEmpty)
}

func test_composePRURL_structuralOnly() {
    XCTAssertEqual(
        ProdGitHubAPIProvider.composePRURL(repoFullName: "leaf/core", number: 42),
        "https://github.com/leaf/core/pull/42"
    )
    XCTAssertNil(ProdGitHubAPIProvider.composePRURL(repoFullName: "", number: 42))
    XCTAssertNil(ProdGitHubAPIProvider.composePRURL(repoFullName: "leaf/core", number: 0))
}
```

### 5.2 Collector emission (public)

```swift
// GitHubCollectorTests.swift (public)

func test_viewerLogin_writtenIntoPresenceState_whenLoginNonEmpty() async throws {
    // Stub provider returns ok; collector ticks; verify presence_state.github
    // contains "viewer_login" == "octocat".
}

func test_viewerLogin_writtenAsNSNull_whenLoginEmpty() async throws {
    // Login empty in integrations row → presence dict has key with null value (not absent).
}

func test_makeEvent_payloadIncludesPRURL_forGHPROpened() {
    let snapshot = GitHubEventSnapshot(
        eventID: "e1", eventKind: "gh_pr_opened",
        repoFullName: "leaf/core", title: "X", number: 42,
        sha: nil, branch: nil, createdAtMs: 0,
        metadata: ["pr_url": "https://github.com/leaf/core/pull/42"]
    )
    let event = GitHubCollector.makeEvent(snapshot: snapshot)
    XCTAssertEqual(event.payload["pr_url"], "https://github.com/leaf/core/pull/42")
}
```

### 5.3 InboxItem assembly (moat)

```swift
// ProdInsightsInboxItemsTests.swift (moat)

func test_queryReviewRequests_aggregatesByRepoAndNumber() throws {
    // Insert 3 gh_pr_review_requested events for leaf/core#42 + 1 for leaf/core#43
    // Expect 2 InboxItems: leaf/core#42 aggregatedCount=3, leaf/core#43 aggregatedCount=1
}

func test_queryCommentsOnMyWork_githubBranch_aggregatesPRAndIssueComments() throws {
    // Insert mix of gh_pr_review_comment_authored + gh_issue_comment_authored events
    // Expect grouped by (repo, number) regardless of kind
}

func test_queryGitHubNotifications_synthesizesPositiveDeltaOnly() throws {
    // Insert 2 gh_notifications_pulse rows: prior has review_requested=2, latest has review_requested=5
    // Expect 1 InboxItem with delta=3
}

func test_queryGitHubNotifications_coldTickReturnsEmpty() throws {
    // Insert only 1 gh_notifications_pulse row in window
    // Expect [] (no diff possible)
}
```

### 5.4 Sentinel-injection regression (public)

3 per-invariant tests + 1 integration sweep в `RelayBodyLeakageTests`:

| Test name | Sentinel | Injection point | Assertion |
|---|---|---|---|
| `testEventBodyDoesNotLeakIntoPresenceState_GHURLEnrichment` | `LEAKED_SENTINEL_GH_T3_PR_BODY` | PR body field of a `gh_pr_opened` event | `pr_url` field structurally `https://github.com/{repo}/pull/{n}` only; sentinel NEVER в `pr_url` / `issue_url` / `comment_url` payload fields anywhere |
| `testEventBodyDoesNotLeakIntoPresenceState_GHReviewRequested` | `LEAKED_SENTINEL_GH_T3_REVIEWER` | PR title/body adjacent to `requested_reviewer.login` | `requested_reviewer_login` field structurally is `login` only (alphanumeric/underscore/hyphen) — sentinel containing whitespace+special chars NEVER reaches payload field, no body fields polluted |
| `testEventBodyDoesNotLeakIntoPresenceState_GHViewerLogin` | `LEAKED_SENTINEL_GH_T3_VIEWER_LOGIN` | Inject sentinel into PR body + unrelated payload field. Mock integration row sets `login = "octocat"` (real-shape value). | `presence_state.github.state_json` contains `viewer_login == "octocat"` (proves slot wiring correct). Sentinel NEVER appears anywhere in `presence_state.github.state_json` or events.payload_json (proves viewer_login slot does not bleed from event body). |
| `testEventBodyDoesNotLeakIntoPresenceState_GHIntegrationSweep` | All 3 sentinels above | All emission paths simultaneously | iterate `events.payload_json` + `presence_state.github.state_json` for cross-contamination |

### 5.5 DispatchCoverageTests parity fence

Existing GitHub fence enumerates kinds × 4 aspects (registry / defaults / icon / mapper). Add `"gh_pr_review_requested"` + `"gh_pr_review_request_removed"` to all 4 arrays.

### 5.6 7 historical track-baseline registry parity fences

Same pattern as T2 commit `c49eea4a test(track-9-T2): bump registry parity fences 195 -> 196`. Bump count from 196 → 198 in:
- DispatchCoverageTests баса baseline
- 6 other track-baseline parity tests (Track-3 D2/D3/D4 + Track-4 S1/S2/S3 + Track-6 P1/P2/P3/P4/P5/P6/P7) — exact file enumeration finalized в Stage 4 plan via grep.

### 5.7 Per-step TDD discipline

Per `superpowers:test-driven-development`:
1. Write test (red).
2. Run test, confirm fails for the right reason.
3. Implement minimum code to pass.
4. Run test, confirm passes.
5. Commit.

Sequential per commit decomposition (no batching).

---

## 6. ADR-010 privacy walkback

Per master spec §6 invariants 5, 6, 7 (T3):

> 5. `pr_url` / `issue_url` / `comment_url` (T3) — composed URLs from owner/repo/N references; no PR title / body / comment text.
> 6. `gh_pr_review_requested` / `_removed` (T3) — captured fields: reviewer login (anonymized to 7-bucket per Phase 4.7.C pattern if cross-actor), PR ref, ts. No PR title / body.
> 7. `gh_notification_received` (T3) — captured: notification reason enum (review_requested / mention / state_change), source_ref. No body.

**T3 implementation deviations from master spec §6 listed verbatim above:**

- **#6 anonymization clause** — T3 stores `requested_reviewer_login: String` plaintext per D-5 (pattern parity с existing `prMetadata.requestedReviewers: [String]`). Not anonymized to 7-bucket. Rationale: existing precedent already crossed; new privacy delta absent. Master spec §6 #6 amended T10.
- **#7 `gh_notification_received` capture** — T3 ships deriver-side synthesis only (no new capture-path event_kind per D-1). Master spec §6 #7 reframes as deriver invariant in T10 amendment.

T3 walkback enumeration:

1. **`pr_url` / `issue_url` / `comment_url`** — composed from 3 sources only: `repoFullName` (public org/repo identifier), `number` (public PR/issue number), `comment_id` (numeric, public). Composition functions are pure string interpolation with hard-coded URL prefix `https://github.com/`. No PR/issue `title`, `body`, comment `body`, mention text ever reaches composition. Sentinel test §5.4 guards.
2. **`requested_reviewer_login`** — plaintext GitHub login (public username). Pattern parity с PRMetadata.requestedReviewers (Track-3 D2 plaintext). NEVER reads PR title / body adjacent to login. Sentinel test §5.4 guards (sentinel injected into PR body, assert login field structurally clean).
3. **`presence_state.github.viewer_login`** — string login, public GitHub username. Already passed parameter в каждый fetch method since OAuth bootstrap. Not new privacy surface, just new placement (existing field reused into composite dict).
4. **`queryReviewRequests` / `queryCommentsOnMyWork` GitHub branch / `queryGitHubNotifications`** — read only `repo_full_name`, `number`, `event_kind`, `pr_url`/`issue_url`/`comment_url`, `ts`, `reason_*_count` keys. NEVER read `body` (D1 body capture field), `title`, `comment.body`. Queries use an explicit payload-key allow-list (moat-side helper).

**Privacy walkback grep AC (Stage 7 gate):**
```bash
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body" \
  Packages/LeafCore/Sources/LeafCore/Collectors/GitHubCollector.swift \
  Packages/LeafCore/Sources/LeafCore/Integrations/GitHub/GitHubAPIProvider.swift \
  Packages/LeafCore/Sources/LeafCore/Integrations/GitHub/GitHubEventKinds.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift
# Expected: 0 hits in T3-touched file scope
```

---

## 7. Verification gates (Stage 7 explicit checks)

Per `superpowers:verification-before-completion`:

1. **5/5 xcodebuild schemes Debug build SUCCESS** (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. **SPM tests green** — XCTest + Swift-Testing combined, 0 failures, recorded skipped count vs. T2 baseline 2893 (expected net new ~22: 4 moat parser + 4 moat inbox + 3 public collector + 7 fence bumps + 4 sentinel + 1 dispatch fence).
3. **`just check-tokens` 3-tier clean** — BASE + MIGRATION + RETIRED.
4. **Privacy walkback grep** (§6 AC) — 0 hits.
5. **3+1 sentinel-injection tests green**.
6. **DispatchCoverageTests GitHub fence still green** with 2 new entries.
7. **HomeView.swift LOC unchanged** (T3 substrate-only, no UI touch). Track-8 P9 budget ≤280 preserved.
8. **ShareEventTypeRegistry count** 196 → 198 (verified by 7 fence bump tests).
9. **`presence_state.github.state_json` contains `viewer_login` field** after fresh poll tick (integration smoke).
10. **Privacy substrate purity** — zero new SQLCipher migrations (`git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/DB/` empty), zero new event_kinds beyond listed 2 (`gh_pr_review_requested`, `gh_pr_review_request_removed`), zero new MCP tools (`git diff feature/track-9-substrate -- LeafMCP/` empty).

---

## 8. Acceptance criteria

| AC | Description |
|---|---|
| AC-1 | `gh_pr_review_requested` event emitted when GitHub `/users/<login>/events` PullRequestEvent action=`review_requested` with non-empty `requested_reviewer.login`. |
| AC-2 | `gh_pr_review_request_removed` event emitted for symmetric `review_request_removed` action. |
| AC-3 | Stripped feed (missing `requested_reviewer` payload field) → no event emitted (guard skips). |
| AC-4 | `gh_pr_review_requested` + `_removed` events carry `requested_reviewer_login: String` plaintext in payload. |
| AC-5 | All 15 enriched event_kinds (8 `gh_pr_*` + 5 `gh_issue_*` + 2 `comment_url` overlay) carry `pr_url` / `issue_url` / `comment_url` payload fields when `(repoFullName, number)` valid. |
| AC-6 | URL fields composed structurally only: `https://github.com/{repo}/pull/{n}` / `https://github.com/{repo}/issues/{n}` / `<parent_url>#issuecomment-{id}` or `#discussion_r{id}`. |
| AC-7 | `presence_state.github.viewer_login` populated when integrations row `login` non-empty; NSNull when empty. |
| AC-8 | `ProdInsights+InboxItems.queryReviewRequests` returns InboxItems aggregated by `(repoFullName, number)` from `gh_pr_review_requested` events within cutoff window. |
| AC-9 | `queryCommentsOnMyWork` GitHub branch reads `viewer_login` from `presence_state.github`, applies client-side filter, aggregates by `(repoFullName, number)` from `gh_pr_review_comment_authored` + `gh_issue_comment_authored` events. |
| AC-10 | `queryGitHubNotifications` synthesizes InboxItems from last-2-tick `gh_notifications_pulse` diff, positive deltas only, cold-tick (1 row only) returns `[]`. |
| AC-11 | `ShareEventTypeRegistry` count 196 → 198 (`githubPRReviewRequested` + `githubPRReviewRequestRemoved` added). |
| AC-12 | 7 registry parity fences bumped 196 → 198. |
| AC-13 | `DispatchCoverageTests` GitHub fence includes `gh_pr_review_requested` + `gh_pr_review_request_removed` в всех 4 aspect arrays. |
| AC-14 | `EventKindIcon.icon(for:)` returns SF Symbol для оба new kinds. |
| AC-15 | `ActivityFeedMapper.mapGitHub` emits ActivityFeedEntry для оба new kinds. |
| AC-16 | 3 per-invariant sentinel-injection tests green. |
| AC-17 | `git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/DB/` returns empty (zero SQLCipher migration delta). |
| AC-18 | `git diff feature/track-9-substrate -- LeafMCP/ Packages/LeafCore/Sources/LeafCore/MCP/` returns empty (zero MCP tool delta). |
| AC-19 | Privacy walkback narrow grep — 0 hits forbidden fields in T3 file scope. |
| AC-20 | 5/5 xcodebuild schemes Debug build SUCCESS. |
| AC-21 | SPM tests green; net new test count delta ~+22 vs T2 baseline 2893. |
| AC-22 | `just check-tokens` 3-tier clean. |
| AC-23 | HomeView.swift LOC unchanged (≤280). |

---

## 9. Out of scope (carry list)

| Item | Phase | Reason |
|---|---|---|
| `gh_notification_received` as capture-path event_kind | DEVIATION — deriver-side synthesis preferred (§1.1) | Duplicate substrate over existing `gh_notifications_pulse`. Master spec §5.1 line 242 amended T10. |
| Retroactive URL backfill for events already in DB | T8 `InboxSourceURLDeriver` | Synthesizes from `(repoFullName, number)` refs at deriver boundary. Forward-only T3 emission avoids bulk SQL UPDATE risk. |
| Slack DM bucket routing into INBOX | post-Track-9 | Substrate отсутствует at all 4 layers (no event_kind / no collector path / no registry entry / no presence field). Carry separate phase. |
| Per-notification ID polling via `GET /notifications?per_page=50` | post-Track-9 | Phase 4.7.B `fetchNotifications` returns summary tuple, not raw rows. Per-row polling = substantial new API surface. |
| Cross-actor anonymization buckets для reviewer logins | post-Track-9 (if needed) | Pattern parity с existing `prMetadata.requestedReviewers: [String]` plaintext. Master spec §6 #6 amendment T10. |
| Inbound review request flow ("X requested MY review") as discrete events | T8 + post-Track-9 | Surfaced via `queryGitHubNotifications` synthesis (notifications.reason=review_requested delta). T8 InboxBlock UI presents as `.reviewRequest` kind. |
| InboxKind enum expansion (per-reason kinds: `.assigned`, `.stateChange`) | T8 | Master spec scope lock #3 — T8 owns +5-7 new InboxKind cases. |
| Real-GitHub smoke (production OAuth + real polling tick) | T10 wrap | Smoke happens at Track-9 substrate-branch → main merge ship-prep. |
| `get_github_inbox` MCP tool | Future | No demand articulated. |

---

## 10. References

- Track-9 master design: [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md).
- Track-9 T1 spec: [`2026-05-19-track-9-T1-collector-payload-extensions.md`](./2026-05-19-track-9-T1-collector-payload-extensions.md).
- Track-9 T2 spec: [`2026-05-20-track-9-T2-linear-inbox-feeder.md`](./2026-05-20-track-9-T2-linear-inbox-feeder.md).
- Master Track-8 spec: [`2026-05-18-track-8-home-ux-design.md`](./2026-05-18-track-8-home-ux-design.md) (§9.1 carry catalog — C-16 sourceURL synthesis).
- ADR-010 walkback discipline: `RelayBodyLeakageTests` Track-3 D1..D3 + Track-6 P1..P5 + Track-4 S1..S4 + Track-9 T1/T2 lineage.
- Architecture: `.claude/shared/architecture.md`.
- Conventions / 8-stage workflow: `.claude/shared/conventions.md`.
- Existing GitHub substrate (Discovery grounding):
  - `Packages/LeafCore/Sources/LeafCore/Collectors/GitHubCollector.swift` (presence_state.github composite write at 318-335; notifications pulse emission at 378-397).
  - `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/ProdGitHubAPIProvider.swift` (`mapPullRequestEvent` switch 1071-1086; `requestedReviewers` plaintext capture 1114-1117).
  - `Packages/LeafCore/Sources/LeafCore/Integrations/GitHub/GitHubAPIProvider.swift` (event_kind enumeration 172-176 docs; GitHubEventSnapshot struct 167-250).
  - `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+InboxItems.swift` (`queryCommentsOnMyWork` stub 66-76; T2 Linear branch 85-87 pattern reuse).

---

## 11. Open questions resolved this session

| OQ | Resolution |
|---|---|
| OQ-T3-1: `gh_notification_received` capture-path vs deriver-side? | Deriver-side (D-1, §1.1 deviation). Avoids duplicate substrate over existing `gh_notifications_pulse`. |
| OQ-T3-2: URL enrichment scope (`pr_url` / `issue_url` / `comment_url` placement)? | 15 event_kinds (8 `gh_pr_*` + 5 `gh_issue_*` + 2 comment_url overlay), forward-only (D-2, D-3, D-4). |
| OQ-T3-3: `viewer_login` provisioning mechanism? | Single-line in existing presence dict; `login` already in scope (D-6). |
| OQ-T3-4: Cross-actor anonymization для reviewer logins? | None — plaintext per pattern parity (D-5). Master spec §6 #6 amendment T10. |
| OQ-T3-5: Sentinel-injection test grouping? | 3 per-invariant + 1 sweep (D-15). T1 lineage. |
| OQ-T3-6: DispatchCoverageTests fence — extend or new? | Extend existing GitHub fence (D-17). T2 precedent. |
| OQ-T3-7: Slack DM substrate verify outcome? | NEGATIVE — substrate отсутствует at all 4 layers. Carry post-Track-9 (§1.1). |
| OQ-T3-8: `queryReviewRequests` filter semantics — outbound vs inbound? | Outbound only ("I requested others"). Inbound surfaced via `queryGitHubNotifications` synthesis (D-12). |

---

## 12. Workflow per `conventions.md` (Stages 4-8)

After this spec lands + user review gate:

- **Stage 4 — Plan** (`superpowers:writing-plans`) — atomic per-commit decomposition with explicit AC per step. File: `.claude/plans/track-9-T3.md` (gitignored).
- **Stage 5 — Implementation** — TDD per step (`superpowers:test-driven-development`), sequential, separate session per conventions.md "one phase = one session" mandate.
- **Stage 6 — Independent review** (`superpowers:code-reviewer` subagent) → digest via `superpowers:receiving-code-review`.
- **Stage 7 — Verification** — gates §7 explicit.
- **Stage 8 — Ship** — FF merge to `feature/track-9-substrate`; commit `docs(shared): Track-9 T3 landed — current-state update`.

Track-9 collective merge to main happens after T10 wrap per master spec §11.
