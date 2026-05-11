# Track 3 — External Providers Deep Sweep

**Date:** 2026-05-11
**Status:** Draft (brainstorm-approved, awaiting per-sub-phase implementation plan)
**Owner:** Dmitrii

## Context

Recon baseline (2026-05-11):
- **Linear:** 14 event_kinds, single scope `read`. File: `Packages/LeafCore/Sources/LeafCore/Collectors/LinearCollector.swift`.
- **GitHub:** 21 event_kinds (16 events + 5 pulses), scopes `repo` + `read:user`. File: `GitHubCollector.swift`.
- **Slack:** 8 event_kinds, 9 user scopes (`users:read, users.profile:read, search:read, channels:history, groups:history, im:history, mpim:history, dnd:read, files:read`). File: `SlackCollector.swift`.
- **`ShareEventTypeKey` registry:** 39 entries (`Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift`).

Track 3 — full breadth sweep всех трёх провайдеров. Capture-everything локально, share-selectively через Share Controls (все новые event_kinds default OFF per ADR-020).

## Scope

**In-scope:** Linear / GitHub / Slack deeper endpoint coverage, OAuth scope bumps (с re-auth UX), ShareEventTypeKey registry expansion (39 → ~78), FTS body-kind dispatcher extension для новых body-bearing kinds, cross-provider linker enrichment.

**Out-of-scope:** real-time webhooks / websockets (future Track 7 candidate), new providers (Notion / Figma — Layer C), local OS coverage (Track 4), Activity UI surfacing (Track 5).

## Approach

Phased sub-decomposition:

- **D1 — Linear deep sweep** (~12 new event_kinds, scope `read` покрывает — **no scope bump**)
- **D2 — GitHub deep sweep** (~16 new event_kinds + scope bump: `read:org` + `read:project` + `security_events` + optional `read:audit_log`)
- **D3 — Slack deep sweep** (~14 new event_kinds + big scope bump: 8-9 new scopes)
- **D4 — Cross-cutting** (FTS dispatcher + DetectorPipeline tie-in + cross-provider linker enrichment + Share Controls UI for expanded registry + per-provider scope-status UI)

OAuth re-auth ceremony — **per sub-phase где есть scope bump** (D2, D3). Single re-auth banner в Home + Connections red dot при scope mismatch. Graceful degrade — existing endpoints работают со старыми tokens, new endpoints молча skip'аются без error spam.

**Cadence tiering:**
- **Hot (5m)** — write-side events
- **Warm (15m)** — read-side state (notifications, pins, bookmarks)
- **Cold (daily, ~4am local)** — slow-moving state (stars, watches, custom emoji, scheduled, audit log)

## D1 — Linear matrix

| Endpoint / GraphQL fragment | New event_kind(s) | Cadence | Notes |
|---|---|---|---|
| `viewer.notifications` | `linear_notification_received`, `linear_notification_read`, `linear_notification_archived` | Warm | Inbox + read deltas |
| `viewer.subscribedIssues` snapshot diff | `linear_subscription_added`, `linear_subscription_removed` | Warm | Follow w/o assignment |
| `comment.reactions` fragment (extend Track-1 D1) | `linear_comment_reaction_added` | Hot piggy-back | Filter `user.id == viewer.id` |
| `roadmaps { projects { state } }` | `linear_roadmap_state_observed` | Cold | Context signal |
| Triage queue filter (`issues filter:{state:{type:{eq:triage}}}`) | `linear_triage_item_picked_up`, `linear_triage_item_resolved` | Warm | Per user's teams |
| `viewer.customViews` diff | `linear_custom_view_created`, `linear_custom_view_updated`, `linear_custom_view_deleted` | Cold | |
| `issue.relations` fragment | `linear_relation_added`, `linear_relation_removed` | Hot piggy-back | Relation kind: blocks / blocked_by / related / duplicate |
| Cycles lifecycle (`cycles` field) | `linear_cycle_started`, `linear_cycle_completed` | Warm | Per user's teams |
| `viewer.projectMemberships` diff | `linear_project_membership_added`, `linear_project_membership_removed` | Cold | |

**Linear scope analysis:** all above endpoints reachable через existing single `read` scope — **no scope bump**, no re-auth required.

**Query complexity:** D1 endpoints piggy-back на existing `LeafPoll` GraphQL query where possible (notifications + subscriptions + relations) → bounded complexity increment. Separate queries для cold endpoints (roadmaps, customViews, projectMemberships) — once daily, no rate-limit pressure.

## D2 — GitHub matrix

| Endpoint | New event_kind(s) | Cadence | Required scope |
|---|---|---|---|
| `PullRequestReviewEvent` (events feed extension) | `gh_pr_review_submitted` (discriminator `state: approved / changes_requested / commented`) | Hot | existing |
| GraphQL `viewer.projectsV2` + items | `gh_project_card_moved`, `gh_project_iteration_changed`, `gh_project_field_updated` | Warm | **`read:project`** |
| `/user/starred` diff | `gh_repo_starred`, `gh_repo_unstarred` | Cold | existing |
| `/user/subscriptions` diff | `gh_repo_watched`, `gh_repo_unwatched` | Cold | existing |
| `/users/<login>/gists` diff | `gh_gist_created`, `gh_gist_updated`, `gh_gist_deleted` | Warm | `gist` (verify if `repo` covers) |
| LockedEvent / UnlockedEvent (events feed) | `gh_issue_locked`, `gh_issue_unlocked` | Hot | existing |
| `/user/repository_invitations` | `gh_repo_invitation_received`, `gh_repo_invitation_accepted` | Warm | existing |
| `/repos/<o>/<r>/secret-scanning/alerts` | `gh_secret_alert_observed`, `gh_secret_alert_resolved` | Cold | **`security_events`** |
| `/repos/<o>/<r>/code-scanning/alerts` | `gh_code_alert_observed`, `gh_code_alert_resolved` | Cold | **`security_events`** |
| `/repos/<o>/<r>/dependabot/alerts` | `gh_dependabot_alert_observed`, `gh_dependabot_alert_resolved` | Cold | **`security_events`** |
| WorkflowDispatchEvent (events feed) | `gh_workflow_manual_triggered` | Hot | existing |
| DeploymentEvent / DeploymentStatusEvent | `gh_deployment_created`, `gh_deployment_status_changed` | Hot | existing |
| CreateEvent (repo type) / ForkEvent (events feed) | `gh_repo_created`, `gh_repo_forked` | Hot piggy-back | existing |
| `/orgs/<o>/audit-log` (admin-only) | `gh_audit_action_observed` | Cold | **`read:audit_log`** + **`read:org`** |
| `/user/codespaces` diff | `gh_codespace_created`, `gh_codespace_started`, `gh_codespace_stopped`, `gh_codespace_deleted` | Warm | `codespace` (verify) |
| Reactions to issues/PRs (own items, bounded fan-out) | `gh_issue_reaction_received` (aggregate) | Warm | existing |

**Scope additions:** `read:org`, `read:project`, `security_events`, optional `read:audit_log`. Re-auth ceremony обязательно.

## D3 — Slack matrix

| Endpoint | New event_kind(s) | Cadence | Required scope |
|---|---|---|---|
| `reactions.list` (own) | `slack_reaction_added` | Warm | **`reactions:read`** |
| `pins.list` per channel diff | `slack_pin_added`, `slack_pin_removed` | Warm | **`pins:read`** |
| `bookmarks.list` per channel diff | `slack_bookmark_added`, `slack_bookmark_removed` | Warm | **`bookmarks:read`** |
| `reminders.list` | `slack_reminder_created`, `slack_reminder_completed` | Warm | **`reminders:read`** |
| `chat.scheduledMessages.list` | `slack_message_scheduled`, `slack_message_sent_scheduled` | Warm | **`chat:read`** |
| `stars.list` | `slack_item_saved`, `slack_item_unsaved` | Warm | **`stars:read`** |
| Canvases (`conversations.canvases` + free canvas list) | `slack_canvas_created`, `slack_canvas_edited` | Cold | **`canvases:read`** — **title + lastEditedAt only, no content** (ADR-010) |
| `users.conversations` diff (channel membership) | `slack_channel_joined`, `slack_channel_left` | Warm | existing |
| `emoji.list` diff | `slack_custom_emoji_added` | Cold | **`emoji:read`** |
| `usergroups.list` + `usergroups.users.list` diff | `slack_usergroup_membership_changed` | Cold | **`usergroups:read`** |
| `conversations.info` per active channel (renamed / archived detection) | `slack_channel_renamed`, `slack_channel_archived` | Cold | existing |

**Scope additions:** 8-9 new scopes. Re-auth ceremony обязательно. Largest scope bump в track'е.

## D4 — Cross-cutting

- **FTS body-kind dispatcher extension** (`Packages/LeafCore/Sources/LeafCore/.../EventsFullTextStore.swift`): add new body-bearing kinds (`linear_notification_received.payload.title`, `gh_gist_*.payload.description`, `slack_canvas_*.payload.title`).
- **DetectorPipeline body-kind dispatch** (mirror FTS additions).
- **Cross-provider linker enrichment:** `LinearIDExtractor` применяется к `linear_notification_received.payload.title` + `gh_audit_action_observed.payload.repo_name` + Slack canvas titles.
- **Share Controls UI:** pagination + grouping для 78-entry list (currently 39-entry flat list borderline UX).
- **Per-provider scope-status UI** в Connections tab: granted vs missing scopes display + "Re-authorize to enable N more features" CTA + per-scope explainer copy.

## Schema changes

- **No new tables** — pure additive payload extension в `events.payload_json`.
- **ShareEventTypeKey enum extended** 39 → ~78 entries. All new entries **default OFF** (mirrors Track-1 D3 semantic facts pattern).

## OAuth re-auth UX

- **Red dot** на Connections tab при scope mismatch (новый ShipState `connectedScopeOutdated`).
- **Banner в Home**: "Leaf needs to refresh access to GitHub to unlock M new event types" (suppressible via per-provider dismiss).
- **Connections per-provider screen** показывает granted scopes vs required scopes с explainer per missing scope.
- **"Re-authorize" CTA** → existing OAuth flow с extended scope list.
- **Old tokens работают** до момента re-auth — graceful degrade на старых event_kinds.

## Acceptance criteria (per sub-phase)

- **D1:** All 9 Linear endpoints poll'ятся w/o errors на real workspace, 12 new event_kinds emit'ятся, ShareEventTypeKey registry shows 51 entries (39 + 12 default OFF), GraphQL complexity remains under per-hour limit, no scope bump UX needed.
- **D2:** Re-auth flow works end-to-end (red dot → Connections → re-authorize → granted), 16 new event_kinds emit'ятся, audit_log opt-in respects admin scope (graceful skip без admin), secret/code/dependabot alerts gracefully degrade без `security_events` scope.
- **D3:** Re-auth flow works (8-9 new scopes granted), 14 new event_kinds emit'ятся, canvas content NEVER captured (title-only per ADR-010), per-channel `pins.list` / `bookmarks.list` Tier-3 rate-limit respected.
- **D4:** FTS dispatcher includes new kinds (test: query against canvas titles surfaces hits), detector pipeline runs over new body kinds, Share Controls UI navigable for 78 entries (visual smoke: scroll + filter), scope-status UI accurately reflects per-provider state.

## Dependencies

- Track-1 D2 substrate (FTS + event_links) — landed ✅
- Track-1 D3 substrate (DetectorPipeline) — landed ✅
- Track 2 D4 substrate (LeafSection / LeafButton / LeafCard / LeafBadge) — landed ✅
- Re-auth UX needs новую "Permissions" sub-screen в Connections или extension of existing per-provider screen.

## Open questions

- **OQ-1:** GitHub audit log есть только в Enterprise / Team plan orgs. Skip-if-personal-account graceful degrade или surface "not available on your plan" message? **Recommendation:** detect at scope-grant time + show inline disabled state.
- **OQ-2:** Slack canvas content — confirmed title + URL + lastEditedAt only per ADR-010 won't-list. Verify в D3 implementation что `conversations.canvases` API не возвращает body inadvertently.
- **OQ-3:** Linear `comment.reactions` fragment cost — current GraphQL complexity ~75 pts/page. Reactions extends. Benchmark в D1 implementation session.
- **OQ-4:** Codespaces scope name (`codespace` vs `repo`-included) — verify in D2 implementation session.
- **OQ-5:** Slack DM / private channel reaction capture — `reactions:read` scope покрывает все channels включая DM. Privacy walkback? **Recommendation:** filter to channels опубликованные через existing share controls only (don't capture reactions в private DM unless explicitly opt-in).

## Risk

- **Re-auth fatigue:** D2 + D3 — два consecutive re-auth ceremonies. Mitigation — clear copy per ceremony объясняющий что unlock'ается, low-pressure dismissible banner (не forced modal).
- **Rate-limit blow-up на cold daily endpoints:** audit log + gists pagination + projectsV2 могут спайкнуть на large workspaces. Mitigation — page caps + daily cooldown + retry-after-handling.
- **Linear GraphQL complexity ceiling:** D1 piggy-back fragments могут push query over 2M/hr limit на high-traffic workspaces. Mitigation — fallback to separate queries если main query rejected (mirror Track 4.7.C documents legacy-workspace graceful degrade).

## Phase decomposition order

D1 → D2 → D3 → D4. Sequential. Каждый ship'ается на feature branch + acceptance gate (manual smoke на собственных рабочих данных). Collective merge после D4. Whitepaper sync deferred до post-D4 collective merge (public-safe architectural framing only — implementation moat остаётся в коде).
