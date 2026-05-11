# Phase Track-3 D2 — GitHub Deep Sweep

**Date:** 2026-05-12
**Branch:** `feature/track-3-D2-github-deep-sweep` (off `feature/linear-schema-reconciliation-2026-05-11`)
**Stack position:** Track 3 second sub-phase. Stack: `main` → D1 (Linear deep sweep) → reconciliation (Linear schema correction) → **D2 (this)** → D3 (Slack) → D4 (cross-cutting). Collective merge after Track 3 acceptance gate.
**Contract:** `docs/superpowers/specs/2026-05-11-track-3-providers-deep-sweep-design.md` §"D2 — GitHub matrix".
**Baseline:** 1283 SPM tests (post-reconciliation), 5/5 xcodebuild schemes green, `just check-tokens` PASS, M001–M015, 28 SQLCipher tables.

---

## 1. Goals

Expand GitHub coverage **21 → 52 event_kinds** (+31 net-new across hot 7 + warm 13 + cold 11; `gh_pr_review_submitted` is a rename + discriminator enhancement of existing `review_submitted`, counted under the 21 existing rather than as new), introduce the **first OAuth scope-bump UX ceremony** in the stack, unify all GitHub event_kinds under `gh_*` canonical prefix discipline (retroactive normalization of existing 21), reuse D1 substrate (`provider_snapshots` M015, atomic write helper, scheduler patterns) verbatim, and apply the Linear-reconciliation lesson — every new event_kind has explicit dispatcher coverage tests preventing dispatcher-drift bugs.

**Non-goals:**
- Track-3 D3 (Slack deep sweep) — separate sub-phase
- Track-3 D4 (cross-cutting polish: FTS dispatcher unification, Share Controls UI pagination, scope-status surface per-provider generalization) — separate sub-phase
- Whitepaper sync — deferred until full Track 3 ship per design spec §13
- Live runtime smoke on signed release — separate workstream (release.sh + new alpha)

---

## 2. Architecture decisions

### 2.1 Naming convention — `gh_*` canonical prefix (decision: **B1 from brainstorm**)
All GitHub event_kinds (existing 21 + new 22) live under canonical `gh_*` prefix forever. Drives:
- ShareEventTypeRegistry — 13 existing GitHub entries renamed in place + 22 new entries appended
- FTS dispatcher (`EventsFullTextStore`) — body extraction dispatch keyed on `gh_*` literals only
- EventLinks `LinkDerivers` — all GitHub-related deriver predicates rewritten к `gh_*`
- DetectorPipeline body-bearing dispatch — single body-kind dispatch table aligned к `gh_*`
- Tests — all literal references swept

**M016 migration** (one-time, idempotent on repeat):
```sql
-- For each existing GitHub event_kind k that lacks "gh_" prefix:
UPDATE events
SET payload_json = json_set(payload_json, '$.event_kind', 'gh_' || json_extract(payload_json, '$.event_kind'))
WHERE json_extract(payload_json, '$.event_kind') = '<old_kind>';
```
Run inside `M016_NormalizeGitHubEventKinds.swift` migration; iterates known old-name list (21 names from collector source-of-truth); guarded by per-row WHERE matches old name → idempotent (re-run finds zero rows). Also rewrites `events_fts_meta` body_kind values (`pr_comment` → `gh_pr_comment` etc.) for FTS retrieval consistency.

### 2.2 Scope management — service-layer derivation (decision: **C from brainstorm**)
- **Required core scopes (build-time constant):** `["repo", "read:user", "read:org", "read:project"]`
- **Recommended optional scopes (build-time constant):** `["security_events", "read:audit_log"]`
- **Granted scopes:** parsed from existing `integrations.scope` TEXT column (no schema change)
- New actor `GitHubScopesService` derives `(granted, requiredCore, requiredOptional, missing)` synchronously; missing = `requiredCore - granted`. ShipState gains `connectedScopeOutdated` case when `missing.isEmpty == false`.
- Collectors **gate** on `scopeService.has(scope)` before calling scope-restricted endpoints — no 401/403 noise, no error spam. Optional scope missing → endpoint skipped silently with one log line per session.

### 2.3 Re-auth UX (decision: **B from brainstorm — proactive + session-dismiss**)
- Banner: `LeafBanner.warning` on Home, proactive on launch when `missing.isEmpty == false`. Session-dismiss via `UserDefaults` key `github.reauth.bannerDismissedSessionID` storing UUID; UUID compared against current launch UUID — different → re-show. Cleared on app restart.
- Persistent red dot on Connections nav item — driven by `connectedScopeOutdated` ShipState
- Connections tab GitHub section — `LeafSection "Scopes"` showing granted scopes badge list + missing scopes highlighted with per-scope explainer (LeafBanner.warning inline within section)
- "Re-authorize" CTA → existing `GitHubOAuthService.connect(scopes:)` extended via `GitHubScopes.requested()` returning union of `requiredCore + requiredOptional`
- Optional scope denied (user rejects `security_events` in GitHub consent screen) → granted but core complete → ShipState `connected`, no banner, no red dot. Connections section shows subtle "Recommended scope not granted" note without red dot — informational only.

### 2.4 ProjectsV2 GraphQL cost (decision: **(b) + (i) from brainstorm**)
- Top-10 viewer's `projectsV2` by `updatedAt` desc per warm tick (bounded fan-out mirrors existing Phase 4.7.B `fetchActionsRunsForActor` top-10 active repos pattern)
- Full items snapshot per project via `provider_snapshots(provider="github", snapshot_kind="github_projectv2_items:<projectID>")`. Diff against last snapshot → emit `gh_project_card_moved` / `gh_project_iteration_changed` / `gh_project_field_updated` events
- Silent 403-skip per-project for Org-locked projects user has no access to
- Cost budget: 10 projects × ~50 items/page = 10 connection-pages = ~10 GraphQL points/tick. 15m interval = 4 ticks/hr = 40 pts/hr. Limit 5000 pts/hr. **0.8% of budget.**

---

## 3. Event_kind matrix

### 3.1 Hot tier (5m — existing GitHubCollector piggy-back, zero new HTTP)
All extracted from existing single `/users/<login>/events?per_page=100` REST call:

| event_kind | Source GitHub Event | Discriminator payload key |
|---|---|---|
| `gh_pr_review_submitted` | PullRequestReviewEvent | `state: approved` / `changes_requested` / `commented` |
| `gh_issue_locked` | IssuesEvent (action=locked) | — |
| `gh_issue_unlocked` | IssuesEvent (action=unlocked) | — |
| `gh_workflow_manual_triggered` | WorkflowDispatchEvent | `workflow_name`, `ref` |
| `gh_deployment_created` | DeploymentEvent | `environment` |
| `gh_deployment_status_changed` | DeploymentStatusEvent | `state: success` / `failure` / `error` / `pending` / `queued` / `in_progress` |
| `gh_repo_created` | CreateEvent (ref_type=repository) | `repository_visibility: public/private` |
| `gh_repo_forked` | ForkEvent | `forkee_full_name` |

**Note on `gh_pr_review_submitted`:** Upgrades existing `review_submitted` event_kind. M016 renames existing data; collector starts emitting with `state` discriminator key in payload. Existing rows lacking `state` payload field — gracefully tolerated downstream (NULL/missing semantic).

### 3.2 Warm tier (15m — new GitHubWarmCollector + GitHubWarmScheduler)
Mirror Linear D1 substrate exactly (`LinearWarmScheduler` shape: 15m interval task loop, half-interval initial delay, injectable clock for tests, graceful shutdown on `stop()`).

| event_kind | Source endpoint | Snapshot kind | Scope gate |
|---|---|---|---|
| `gh_project_card_moved` | GraphQL `viewer.projectsV2 → items` | `github_projectv2_items:<projectID>` | `read:project` |
| `gh_project_iteration_changed` | (same) | (same) | (same) |
| `gh_project_field_updated` | (same) | (same) | (same) |
| `gh_gist_created` | `/users/<login>/gists` | `github_gists` | — |
| `gh_gist_updated` | (same) | (same) | — |
| `gh_gist_deleted` | (same) | (same) | — |
| `gh_repo_invitation_received` | `/user/repository_invitations` | `github_repo_invitations` | — |
| `gh_repo_invitation_accepted` | (same) | (same) | — |
| `gh_codespace_created` | `/user/codespaces` | `github_codespaces` | — |
| `gh_codespace_started` | (same) | (same) | — |
| `gh_codespace_stopped` | (same) | (same) | — |
| `gh_codespace_deleted` | (same) | (same) | — |
| `gh_issue_reaction_received` | per-issue `/repos/{o}/{r}/issues/{n}/reactions` (top-10 viewer-authored issues last 7d) | `github_issue_reactions:<owner>/<repo>/<n>` | — |

**Bounded fan-out for `gh_issue_reaction_received`:** populate "active viewer-authored issues" list from existing hot-tier events feed (issues opened by viewer in last 7d), cap at top-10 by most-recent-activity. Aggregate emission: one event per (issue, polling tick) carrying reaction counts diff (added/removed) by emoji.

**Gist FTS body:** `gh_gist_description` body kind extracted on emission; description-only (gist file contents NOT indexed — out of scope per ADR-010).

### 3.3 Cold tier (4am local daily — new GitHubColdCollector + GitHubColdScheduler)
Mirror Linear D1 cold scheduler exactly (`LinearColdScheduler` shape: 4am local anchor + `lastColdMs > 24h` catch-up gate, injectable clock/calendar/sourceIDProvider, `nextLocal4am` + `shouldCatchUp` exposed `public nonisolated` for tests).

| event_kind | Source endpoint | Snapshot kind | Scope gate |
|---|---|---|---|
| `gh_repo_starred` | `/user/starred` | `github_starred_repos` | — |
| `gh_repo_unstarred` | (same) | (same) | — |
| `gh_repo_watched` | `/user/subscriptions` | `github_watched_repos` | — |
| `gh_repo_unwatched` | (same) | (same) | — |
| `gh_secret_alert_observed` | `/repos/{o}/{r}/secret-scanning/alerts` (top-K active repos) | `github_secret_alerts:<owner>/<repo>` | `security_events` |
| `gh_secret_alert_resolved` | (same) | (same) | (same) |
| `gh_code_alert_observed` | `/repos/{o}/{r}/code-scanning/alerts` | `github_code_alerts:<owner>/<repo>` | (same) |
| `gh_code_alert_resolved` | (same) | (same) | (same) |
| `gh_dependabot_alert_observed` | `/repos/{o}/{r}/dependabot/alerts` | `github_dependabot_alerts:<owner>/<repo>` | (same) |
| `gh_dependabot_alert_resolved` | (same) | (same) | (same) |
| `gh_audit_action_observed` | `/orgs/{org}/audit-log` (Org member only) | `github_audit_cursor` | `read:audit_log` + Org membership |

**Bootstrap discipline:** mirror Linear D1 cold tier behaviour. First cold tick after install — writes all baseline snapshots, emits zero diff events. Day-2 cold tick produces normal events.

**Heartbeat events:** none required for D2 (Linear D1 emitted `linear_initiative_observed` as heartbeat-per-tick context signal; GitHub D2 cold endpoints are all diff-driven, no analogous context signal needed).

**Security alerts top-K source:** "active repos" list = existing hot-tier events feed source (repos viewer pushed to / opened PRs in last 14d), cap at **top-10 most-recently-active**. Matches Phase 4.7.B `fetchActionsRunsForActor` bounded fan-out precedent. Different from issue reactions 7d window — alerts are slower-moving than reactions, 14d gives reasonable stability for "active repo" definition.

**Audit Org detection:** parsed from `GET /user/orgs` once per day cached. If empty → skip audit endpoint entirely.

---

## 4. Substrate additions

### 4.1 Migration M016 — `M016_NormalizeGitHubEventKinds.swift`
Renames 21 existing GitHub event_kinds to `gh_*` prefix.

Old → new mapping (single source of truth in migration file + collector emit sites + tests):
```
commit_pushed → gh_commit_pushed
pr_opened → gh_pr_opened
pr_merged → gh_pr_merged
pr_closed → gh_pr_closed
issue_opened → gh_issue_opened
issue_closed → gh_issue_closed
review_submitted → gh_pr_review_submitted   (also gains `state` payload key)
pr_review_comment_authored → gh_pr_review_comment_authored
issue_comment_authored → gh_issue_comment_authored
release_published → gh_release_published
branch_created → gh_branch_created
branch_deleted → gh_branch_deleted
tag_created → gh_tag_created
discussion_authored → gh_discussion_authored
discussion_comment_authored → gh_discussion_comment_authored
pr_review_thread_resolved → gh_pr_review_thread_resolved
github_notifications_pulse → gh_notifications_pulse
pr_awaiting_review_count → gh_pr_awaiting_review_count
my_open_pr_count → gh_my_open_pr_count
actions_run_initiated → gh_actions_run_initiated
check_runs_status → gh_check_runs_status
```

Migration also rewrites `events_fts_meta.body_kind` values for FTS dispatch consistency:
```
gh_pr → gh_pr (unchanged — already canonical)
gh_issue_comment → unchanged
gh_pr_review_comment → unchanged
```
(Body kinds were already correctly `gh_*` prefixed in Schema.BodyKinds — only event_kind normalization is needed.)

### 4.2 `Schema.ProviderSnapshotKinds` additions
```swift
// GitHub D2 — singleton snapshot kinds
public static let githubStarredRepos = "github_starred_repos"
public static let githubWatchedRepos = "github_watched_repos"
public static let githubGists = "github_gists"
public static let githubCodespaces = "github_codespaces"
public static let githubRepoInvitations = "github_repo_invitations"
public static let githubAuditCursor = "github_audit_cursor"

// GitHub D2 — parameterized snapshot kind prefixes (composite key embedded in value)
public static let githubProjectV2ItemsPrefix = "github_projectv2_items:"
public static let githubIssueReactionsPrefix = "github_issue_reactions:"
public static let githubSecretAlertsPrefix = "github_secret_alerts:"
public static let githubCodeAlertsPrefix = "github_code_alerts:"
public static let githubDependabotAlertsPrefix = "github_dependabot_alerts:"
```

### 4.3 `Schema.BodyKinds` additions
```swift
public static let ghGistDescription = "gh_gist_description"
public static let ghReleaseBody = "gh_release_body"          // release_published may already carry — formalize
public static let ghDeploymentDescription = "gh_deployment_description"
```

### 4.4 `CollectorID` additions
```swift
public static let githubWarmPolling = "github_warm_polling"   // sourceID: github:warm:<login>
public static let githubColdPolling = "github_cold_polling"   // sourceID: github:cold:<login>
```

### 4.5 `Schema.EventPayloadKeys` additions
Compact additions (all values lowercase snake_case):

| Key constant | JSON key |
|---|---|
| `prReviewState` | `pr_review_state` |
| `workflowName` | `workflow_name` |
| `workflowRef` | `workflow_ref` |
| `deploymentEnvironment` | `deployment_environment` |
| `deploymentState` | `deployment_state` |
| `repositoryVisibility` | `repository_visibility` |
| `forkeeFullName` | `forkee_full_name` |
| `gistId` | `gist_id` |
| `gistDescription` | `gist_description` |
| `projectV2Id` | `projectv2_id` |
| `projectV2CardId` | `projectv2_card_id` |
| `projectV2FieldName` | `projectv2_field_name` |
| `projectV2OldValue` | `projectv2_old_value` |
| `projectV2NewValue` | `projectv2_new_value` |
| `iterationId` | `iteration_id` |
| `codespaceName` | `codespace_name` |
| `codespaceState` | `codespace_state` |
| `repoInvitationId` | `repo_invitation_id` |
| `repoInvitationFromLogin` | `repo_invitation_from_login` |
| `repoFullName` | `repo_full_name` |
| `reactionEmoji` | `reaction_emoji` |
| `reactionCount` | `reaction_count` |
| `reactionDelta` | `reaction_delta` |
| `alertNumber` | `alert_number` |
| `alertSeverity` | `alert_severity` |
| `alertRule` | `alert_rule` |
| `dependabotPackageName` | `dependabot_package_name` |
| `auditAction` | `audit_action` |
| `auditActorLogin` | `audit_actor_login` |

### 4.6 ShareEventTypeRegistry
- Rename existing GitHub entries inline to `gh_*` form (preserve display labels, only enum case raw values change). Exact count of existing GitHub-flavored registry entries verified at implementation start (discovery surfaced 13 visible mentions in 4.7.A + 4.7.B blocks; 4.6 baseline + 4.7.C entries also exist — full count ~21 aligned with collector emit sites).
- Add 31 new cases, all default OFF, alphabetized within GitHub block
- Tests assert `ShareEventTypeKey.allCases.count == 97` (66 existing total, all renames preserve count, 31 new appended; 0 existing entries dropped). If implementation reveals existing GitHub registry count differed from emit-site count, plan adds missing entries as part of M016 normalization (closing gap is part of the dispatcher-coverage discipline §9).
- Cross-check: every emit site collector → registry entry exists test

---

## 5. Public protocol API additions (`GitHubAPIProvider`)

```swift
public protocol GitHubAPIProvider: Sendable {
    // ...existing 7 methods unchanged...

    // D2 — warm tier
    func fetchProjectsV2State(accessToken: String, login: String, topN: Int) async throws -> GitHubProjectsV2Snapshot
    func fetchGists(accessToken: String, login: String) async throws -> [GitHubGistSnapshot]
    func fetchRepoInvitations(accessToken: String) async throws -> [GitHubRepoInvitationSnapshot]
    func fetchCodespaces(accessToken: String) async throws -> [GitHubCodespaceSnapshot]
    func fetchIssueReactions(accessToken: String, owner: String, repo: String, issueNumber: Int) async throws -> GitHubIssueReactionsSnapshot

    // D2 — cold tier
    func fetchStarredRepos(accessToken: String, login: String) async throws -> [GitHubStarredRepoSnapshot]
    func fetchWatchedRepos(accessToken: String, login: String) async throws -> [GitHubWatchedRepoSnapshot]
    func fetchSecretScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot]
    func fetchCodeScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot]
    func fetchDependabotAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot]
    func fetchOrganizations(accessToken: String) async throws -> [GitHubOrgSnapshot]
    func fetchOrgAuditLog(accessToken: String, org: String, since: Int64?) async throws -> GitHubOrgAuditLogBatch
}
```

All snapshot types are `public Sendable Hashable` structs in LeafCore with public init + `static let empty` constants — mirror Linear D1 convention. `Stub*Provider` adds `.empty` returns for all new methods (CI builds without moat).

Moat (LeafCorePrivate, gitignored): `ProdGitHubAPIProvider` extended with full REST/GraphQL bodies for all new methods. Per-endpoint failure tolerance: each method catches and returns `.empty` on 403/404/scope-related errors (cold tier uses logger one-shot — `logger.warning("Scope missing for X — skipping")` only on first failure per session per kind).

---

## 6. `GitHubScopesService` actor

```swift
public actor GitHubScopesService {
    public static let requiredCore: Set<String> = [
        "repo", "read:user", "read:org", "read:project"
    ]
    public static let requiredOptional: Set<String> = [
        "security_events", "read:audit_log"
    ]
    public static func requested() -> [String] {
        Array(requiredCore.union(requiredOptional)).sorted()
    }

    public init(database: Database)

    public func currentGranted() async -> Set<String>
    public func missing() async -> Set<String>                  // requiredCore - granted
    public func has(_ scope: String) async -> Bool
    public func refresh() async                                  // reload from integrations.scope
    public func observeIntegrationChanges()                      // DistributedNotification hook
}
```

Wired in `AgentLifetime` as new slot `githubScopesService`, constructed after `database` available, observed by `RotationFetchScheduler` peer (warm + cold collectors).

UI side: `Leaf/Integrations/GitHub/GitHubScopesReader.swift` — `@Observable` reader observing service + emitting `ShipState` to UI tree.

---

## 7. Re-auth UX wiring

### 7.1 ShipState extension
Existing `Leaf/Integrations/GitHub/GitHubOAuthService.swift` ShipState enum gains:
```swift
case connectedScopeOutdated(missing: Set<String>)
```

### 7.2 Banner — Home view
- `Leaf/Views/Window/Home/HomeView.swift` renders `LeafBanner.warning` when ShipState matches `.connectedScopeOutdated` AND `bannerDismissedSessionID != currentSessionID`
- Body: "Leaf needs to refresh access to GitHub to unlock N new event types"
- Actions: "Re-authorize" (CTA) → `Task { await GitHubOAuthService.connect(scopes: GitHubScopes.requested()) }`; "Dismiss for now" → stores current session UUID in UserDefaults
- Session UUID generated once per app launch in App-level state

### 7.3 Connections tab
- `Leaf/Views/Window/Connections/ConnectionsView.swift` GitHub section gains `LeafSection "Scopes"` showing:
  - Granted scope badges (LeafBadge per scope, all from `requiredCore + requiredOptional`)
  - Missing core scopes rendered with red dot + inline `LeafBanner.warning` containing explainer text per scope
  - Missing optional scopes rendered subtle `LeafType.body.tertiary` "Recommended scope not granted" hint, no banner
- Per-scope explainer copy (English MVP, Russian post):
  - `read:org` — "Required to detect Organization context for audit log + project membership"
  - `read:project` — "Required to track ProjectsV2 board activity (cards, iterations, fields)"
  - `security_events` — "Recommended: surfaces secret-scanning, code-scanning, and Dependabot alerts on your repositories"
  - `read:audit_log` — "Recommended: tracks admin actions on your GitHub Organization"

### 7.4 Connections nav red dot
- `Leaf/Views/Window/Sidebar/SidebarView.swift` (or equivalent root nav file from Track 2 D4) — Connections tab item gains `LeafBadge.dot` rendered conditionally on `GitHubScopesReader.connectedScopeOutdated || LinearScopesReader.connectedScopeOutdated || SlackScopesReader.connectedScopeOutdated` — D2 implements GitHub side; Linear/Slack readers stub `.connected` always (out of D2 scope, future use).

### 7.5 Re-authorize flow
- `GitHubOAuthService.connect(scopes: [String])` — extend existing connect method to accept scope list parameter (currently hard-coded `["repo", "read:user"]`)
- After re-auth, `integration_changed` notification → `GitHubScopesService.refresh()` → ShipState recomputed → banner hides / red dot clears

---

## 8. Privacy regression (ADR-010 §6)

Add 8+ walkbacks to `Packages/LeafCore/Tests/LeafCoreTests/Privacy/RelayBodyLeakageTests.swift`:

| Walkback | Asserts |
|---|---|
| `testRelayDoesNotLeakGistDescription` | gist description body NOT in `presence_state.state_json` |
| `testRelayDoesNotLeakReleaseBody` | release_published body NOT leaked |
| `testRelayDoesNotLeakDeploymentDescription` | deployment description NOT leaked |
| `testRelayDoesNotLeakProjectV2FieldValues` | projectV2 field value strings NOT leaked |
| `testRelayDoesNotLeakCodespaceName` | codespace display names NOT leaked |
| `testRelayDoesNotLeakRepoInvitationFromLogin` | invitation sender login NOT leaked |
| `testRelayDoesNotLeakSecurityAlertRule` | security alert rule/description NOT leaked |
| `testRelayDoesNotLeakAuditAction` | audit log entry action/actor NOT leaked |
| `testRelayDoesNotLeakIssueReactionEmoji` | reaction emoji counts allowed in presence — sentinel = full message bodies NOT leaked |

Sentinel-injection regression pattern matches D1 exactly: every payload field with body-like content seeded with `BODY_SENTINEL_<kind>` string, RelayBodyLeakage test walks the entire `presence_state.state_json` blob asserting sentinel NOT found.

---

## 9. Reconciliation lesson applied — dispatch coverage tests

D1 reconciliation discovered: `EventsFullTextStore`/`EventLinksStore`/`DetectorPipeline` dispatchers each had body-kind dispatch tables that drifted from collector emit sites (the `issue_updated` vs `linear_issue_updated` bug pattern).

**Mitigation for D2:** new test file `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` asserting:
1. **Every** GitHub event_kind in the canonical `gh_*` list (single source of truth: `GitHubEventKinds.allCanonical` static var) has either:
   - An explicit FTS body-kind dispatch entry (if body-bearing), OR
   - An explicit `_ = ()` no-body case in dispatcher switch (compile-time enforced via Swift exhaustive switch on `GitHubEventKindKey` typed enum mirror)
2. M016 rename mapping covers every event_kind that existed in old collector source before D2
3. ShareEventTypeRegistry includes every kind from `GitHubEventKinds.allCanonical`
4. `LinkDerivers` GitHub predicate coverage matches kinds carrying linkable refs (commit msg / PR title / issue body)

Implementation: introduce internal `GitHubEventKindKey` enum (string-backed) in LeafCore — used as compile-time exhaustive switch target in all three dispatchers + ShareEventTypeKey registry duplication check. New dispatchers must add a case → compile fails until covered everywhere. This is the "fence" preventing future D1-style drift bugs.

---

## 10. Test plan

### 10.1 New unit tests (target +70-90 → 1283 → ~1353-1373)

Public substrate (LeafCore):
- **M016 migration** (`M016NormalizeGitHubEventKindsTests.swift`): rename idempotency (run twice no-op), payload preservation, FTS meta consistency, edge case (empty events table)
- **GitHubScopesService** (`GitHubScopesServiceTests.swift`): `computeMissing` with various granted sets, optional vs core distinction, `has()` cache invalidation on `integration_changed` notification, concurrent access safety
- **GitHubWarmCollector** (`GitHubWarmCollectorTests.swift`): tick with full state (all 5 endpoints), scope-gated skip (projectsV2 without `read:project`), 403 graceful per-project, bootstrap discipline (first tick zero diff events for diff-based endpoints), bounded fan-out cap (top-10 projects)
- **GitHubColdCollector** (`GitHubColdCollectorTests.swift`): 4am scheduling logic, catch-up gate, scope-gated skip (security alerts), Personal vs Org audit detection, top-K active repos selection for alerts
- **GitHubWarmScheduler / GitHubColdScheduler** (`GitHubWarmSchedulerTests.swift` + `GitHubColdSchedulerTests.swift`): injectable clock, shutdown lifecycle, error swallowing (collector throws → scheduler continues)
- **Dispatch coverage** (`DispatchCoverageTests.swift`): per §9 — typed enum exhaustive switch enforcement + registry consistency
- **RelayBodyLeakage** (`RelayBodyLeakageTests.swift`): 9 new walkbacks per §8
- **Hot tier upgrades** (`GitHubCollectorTests.swift` extensions): each of the 6 hot-tier new event_kinds emits with correct payload from fixture event feed responses
- **EventsFullTextStore** (existing test file extensions): body extraction for new body kinds (gist description, release body, deployment description) via new event_kind dispatch entries
- **ShareEventTypeRegistry** (existing test file extensions): count assertion 88, default-OFF discipline for new entries, alphabetization within GitHub block

Moat (LeafCorePrivate, gitignored, +20-30 tests):
- `ProdGitHubAPIProviderTests.swift` — fixtures для each new method (projectsV2 GraphQL response, gists REST, codespaces, security alerts, etc.); error path coverage (403/404 → `.empty`); rate-limit response handling

### 10.2 Live smoke (manual, post-merge gate)
1. Fresh Mac with no GitHub integration → connect (Device Flow) with `requiredCore + requiredOptional` scopes → all 4 collector tiers (existing hot + new warm + new cold) tick once → events table grows with `gh_*` event_kinds
2. Run app pre-existing alpha → install build with M016 → verify existing events renamed; verify FTS still queryable
3. Re-auth UX: revoke `read:project` scope via GitHub settings → app detects on next ScopesService refresh → ShipState `connectedScopeOutdated` → banner + red dot → click → OAuth re-auth → granted → next warm tick fetches ProjectsV2
4. Optional scope denial: re-auth screen, deny `security_events` → app detects partial grant → no banner, no red dot, subtle Connections hint only
5. Real GitHub actions: star a repo → next cold tick emits `gh_repo_starred`; create a gist → next warm tick emits `gh_gist_created`; trigger workflow → next hot tick emits `gh_workflow_manual_triggered`; etc.

---

## 11. Decomposition (high-level — full plan in writing-plans stage)

Atomic task ordering (TDD per task):

1. **Schema additions** — Migration M016 + Schema.{ProviderSnapshotKinds, BodyKinds, CollectorID, EventPayloadKeys} extensions + tests
2. **GitHubScopesService** — actor + tests + AgentLifetime wiring
3. **Dispatch coverage substrate** — `GitHubEventKindKey` typed enum + DispatchCoverageTests scaffolding
4. **ShareEventTypeRegistry expansion** — rename 13 + add 22 + tests
5. **Hot tier extensions** — 6 new event_kinds in existing GitHubCollector, fixture tests, FTS dispatch entries
6. **API protocol expansion** — 11 new methods on `GitHubAPIProvider`, snapshot value types, StubGitHubAPIProvider `.empty` returns
7. **Warm tier** — GitHubWarmCollector + GitHubWarmScheduler + tests (no provider implementation yet — Stub returns)
8. **Cold tier** — GitHubColdCollector + GitHubColdScheduler + tests
9. **Atomic write wiring** — collectors call `writeEventsOffsetsAndSnapshots`; offsets cursors registered; tests assert atomic rollback
10. **Moat (LeafCorePrivate)** — `ProdGitHubAPIProvider` extended with full GraphQL + REST implementations; moat fixture tests; per-endpoint graceful degrade
11. **UI: GitHubScopesReader + ShipState extension** — Reader observes service, emits state
12. **UI: Re-auth banner** — Home view banner + session-dismiss + UserDefaults
13. **UI: Connections scope section** — LeafSection rendering granted vs required, per-scope explainer, re-authorize CTA
14. **UI: Connections nav red dot** — sidebar nav badge wiring
15. **GitHubOAuthService.connect extension** — accept scopes parameter, propagate to Device Flow request
16. **Privacy regression** — 9 new RelayBodyLeakage walkbacks
17. **Verification** — full smoke per §10.2 + 5/5 xcodebuild + just check-tokens + SPM tests count target
18. **Ship commit** — current-state.md update + docs(shared) commit

---

## 12. Whitepaper sync

**Deferred** until full Track 3 ship (D1 + D2 + D3 + D4 collective merge), per design spec §13.

Track 3 D2 specifics that would be public-safe candidates (post-merge separate session):
- Architectural framing — "GitHub coverage expanded to ~40 event_kinds across hot/warm/cold tiers; OAuth scope-bump UX surfaced as ambient reauth ceremony"
- High-level event_kinds taxonomy table (categories without raw event names that compromise moat)
- Scope philosophy — distinction between required core (blocking) vs recommended optional (silent degrade)

Implementation moat NOT for whitepaper:
- GraphQL ProjectsV2 query bodies
- Security alerts polling cadence + scope discovery logic
- Audit log cursor format
- Bounded fan-out heuristics (top-K, last 7d) — specific thresholds
- M016 rename logic + idempotency mechanism (already deep enough internal to be IP-relevant)

---

## 13. Acceptance criteria

1. All 31 new `gh_*` event_kinds emit on real GitHub actions on real workspace
2. M016 migration renames existing data idempotently; re-running yields zero changes
3. ShareEventTypeRegistry shows 97 entries (66 existing + 31 new), all 31 new default OFF, tests assert
4. Re-auth flow E2E: missing scope → `connectedScopeOutdated` → banner + red dot → re-auth → granted → next tick fetches new endpoints
5. `provider_snapshots` populated for GitHub (starred/watched/codespaces/gists/invitations/projects/security_alerts) after first warm + cold tick
6. `gh_secret_alert_*` graceful skip without `security_events` scope (no error spam, one log line per session)
7. `gh_audit_action_observed` graceful skip on Personal accounts (no error)
8. SPM tests +70-90 (1283 → ~1353-1373 baseline preserved + new)
9. 5/5 xcodebuild schemes green + `just check-tokens` PASS
10. No regression in D1 reconciliation work (Linear endpoints still emit correctly per regression suite)
11. Privacy: all 9 RelayBodyLeakage walkbacks pass — bodies + alert details + project card values NOT leak to `presence_state.state_json`
12. DispatchCoverageTests: typed enum exhaustive switch enforcement passes — every canonical event_kind has FTS + EventLinks + Detector + Registry coverage

---

## 14. Open questions

None at spec time — all design decisions resolved during brainstorming. Implementation-stage detail decisions deferred to plan stage:
- Exact field set per event_kind payload (full vs minimal) — emerges from collector TDD
- Optional `LinkDerivers` extensions for GitHub-side `gh_*` (e.g., commit messages already linked to Linear IDs in D1 D2 — confirm no new derivers needed)
- Russian translations for re-auth banner + Connections scope explainer (English MVP, RU in v1.1 i18n track)
