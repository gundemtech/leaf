# Track-10 T5 — SINCE YOU WERE LAST ACTIVE phase spec

**Linear**: GUN-47
**Status**: SHIPPED 2026-05-23. Authored from approved Stage 4 plan
`~/.claude/plans/recursive-prancing-rabin.md` after Stages 1-2 brainstorm
(Q1..Q10 closed) + Stage 4.5 CTO meta-review (2 passes, 13 findings — 0
outstanding CRITICAL/HIGH; 13 dispositioned inline). Stages 5-8
(implementation / review / verification / ship) landed in one session.

**Branch**: `feature/GUN-47-track-10-T5-since-last-active` (off
`feature/track-10-operational-home` tip `0495152e` = T4 SHIPPED).

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — §4 T5 · §3.5 · §5.4 · §5.5 · §6.3 · §7.2.

**Precedent specs**:
- T4 NEEDS YOU (pure-UI-refactor precedent): `docs/superpowers/specs/2026-05-22-track-10-T4-needs-you.md`.
- T2.5 follow-up (CTO meta-review pattern + dev-launch-reliability infra): `docs/superpowers/specs/2026-05-22-track-10-T2-5-operational-followup.md`.

---

## 1. Goal

New Zone-5 Home block **SINCE YOU WERE LAST ACTIVE** — per-event activity
timeline since user last clicked `[Mark all as seen]`. Composed from a new
substrate API `DerivedInsights.recentActivityFeed(since:limit:)` plus
14-key verb-mapped renderer with 5-chip filter strip
(All / Linear / GitHub / Slack / Detections).

Unlike T4 (pure UI refactor), T5 is a **substrate-additive** track that
adds ONE new public API + ONE moat impl file + ONE walkback test. Substrate
purity constants held:

- 0 new event_kinds (registry frozen at 198).
- 0 new SQLCipher migrations (30 tables preserved).
- 0 new MCP tools (15 frozen).
- 0 new `ShareEventTypeKey` entries.
- T5 stops being **§6 EXEMPT** — adds 1 sentinel-injection walkback test
  `LEAKED_SENTINEL_T5_RECENT_FEED` in `RelayBodyLeakageTests`.

Net diff: 11 new files / 5 modified / ~870 +LOC across 6 atomic + 1
fix-bundle + 1 SHIPPED docs commit.

---

## 2. Brainstorm decisions

| Q | Decision |
|---|---|
| Q1 cursor default | **24h ago** on first read; persists immediately to UserDefaults. (Master spec amendment from "process boot timestamp"). |
| Q2 compose strategy | **Option B substrate-min** — new `recentActivityFeed(since:limit:)` LeafCore protocol method. Per-event UX. |
| Q3 verb scope | **14-key narrow** allow-list (matches Track-9 T8 precedent). |
| Q4 detection chip | Single **`[Detections]` umbrella** chip (5 total: All / Linear / GitHub / Slack / Detections). |
| Q5 mark-all scope | **Global cursor** (1 UserDefaults key `leaf.ui.lastSeenAtMs`); filter is view-side narrowing only. |
| Q6 row cap | Inline `"+N older changes"` expand toggle, `@State`-per-block, cap = 20. |
| Q7 severity | **Reuse `InboxSeverity`** (.danger / .warn / .muted) — single shared severity model with NEEDS YOU. |
| Q8 chip primitive | **Dual-ship `SinceFilterRow.swift` file-local** — rule-of-three carry to T6/T8/T9 (C-T5-2). |
| Q9 cursor pattern | **`@Observable LastSeenCursor` + `@Environment(LastSeenCursor.self)`**. LocalAppsStore stays ObservableObject (C-5 carry preserved). |
| Q10 commits | **7 atomic + 1 SHIPPED docs commit** + 1 review fix-bundle. |

---

## 3. Surface contract

### 3.1 New value types (`LeafCore/Insights/`)

- **`ActivityFeedItem`** (Sendable, Hashable, Codable) — per-event substrate
  row returned by `DerivedInsights.recentActivityFeed`:
  - `ts: Int64`, `source: SinceSource`, `eventKind: String`,
    `actorDisplay: String?`, `actorIsMe: Bool`, `targetTitle: String?`,
    `targetRef: String?`, `repoHint: String?`, `sourceURL: URL?`.
- **`SinceSource`** (String enum, CaseIterable) — 4 cases in fixed order:
  `.linear`, `.github`, `.slack`, `.detection`.
- **`SinceLastActiveItem`** (Sendable, Hashable) — UI-tier composed row:
  `severity: InboxSeverity`, `verb: String`, `actorPrefix: String`,
  `targetTitle: String`, `sourceMeta: String`, `tsMs: Int64`,
  `source: SinceSource`, `sourceURL: URL?`. NO UUID — `uniqueKey` derived
  from content composition for SwiftUI ForEach stable identity.

### 3.2 `LastSeenCursor` (`LeafCore/Share/LastSeenCursor.swift`)

`@Observable @MainActor` class wrapping UserDefaults key
`leaf.ui.lastSeenAtMs: Int64`. First read seeds `now() - 24h` and persists
immediately; subsequent reads return persisted verbatim.
`markAllAsSeen(now:)` advances cursor to `now()`. Injected in `LeafApp`
root via `@State` + `.environment(LastSeenCursor.self)`. Constructor
defaults `defaults: .standard`, `clock: Date.init` for production;
test-injected suiteName + frozen-clock pattern in LastSeenCursorTests.

### 3.3 `recentActivityFeed` protocol method + moat impl

`DerivedInsights.recentActivityFeed(since: Int64, limit: Int) throws -> [ActivityFeedItem]`.
Default extension impl returns `[]`. Moat
`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+RecentActivityFeed.swift`
(gitignored) queries `events` filtered to 9-kind allow-list:

- Linear: `status_transition`, `linear_comment_authored_to_me`.
- GitHub: `gh_pr_opened`, `gh_pr_merged`, `gh_pr_review_authored`,
  `gh_pr_review_requested`, `gh_commit_pushed`.
- Slack: `slack_huddle_state_change` (`in_a_huddle` only),
  `slack_mention_received_aggregate`.

Plus a UNION over Track-1 D3 `open_questions` and `blockers` (both
filtered to `resolved_at_ms IS NULL` AND opened/started since cursor).
ORDER BY `ts DESC` LIMIT `min(limit, 200)`. Source discrimination via
explicit `payload.source` field (verified upstream Layer B contract).
Linear status_transition's bare `event_kind` is synthesized client-side
to `linear_status_transition.{to_state_type}` at the read boundary for
UI verb-map lookup; outside the 4-state allow-list
(started/completed/canceled/reopened) → row dropped.

### 3.4 `InsightsSnapshot.sinceLastActiveItems` + compose

48th defaulted-init field (`[SinceLastActiveItem] = []`). 11th iteration
of defaulted-init blast-radius invariant; fixture callsites preserve via
default. `SinceLastActiveItem.compose(from:)` static factory maps the
14-key allow-list to UI rows per the verb + severity table:

| event_kind | verb | severity |
|---|---|---|
| `linear_status_transition.started` | "started" | .muted |
| `linear_status_transition.completed` | "completed" | .muted |
| `linear_status_transition.canceled` | "canceled" | .muted |
| `linear_status_transition.reopened` | "reopened" | **.warn** |
| `linear_comment_authored_to_me` | "commented on" | **.warn** |
| `gh_commit_pushed` | "pushed" | .muted |
| `gh_pr_opened` | "opened" | .muted |
| `gh_pr_merged` | "merged" | .muted |
| `gh_pr_review_authored` | "reviewed" | .muted |
| `gh_pr_review_requested` | "requested your review on" | **.warn** |
| `slack_huddle_state_change` | "joined a huddle" | .muted |
| `slack_mention_received_aggregate` | "mentioned you in" | **.warn** |
| `open_question` | "open question:" | **.warn** |
| `blocker` | "blocker:" | **.danger** |

Unmapped `eventKind` → `compose` returns `nil`. Actor-prefix logic:
`.detection → ""`, `actorIsMe → "you"`, else `actorDisplay ?? "@teammate"`.
`sourceMeta` per-source: GitHub `"PR#142 · leaf"`, Linear `"LEAF-208"`,
Slack `"#engineering"`, Detection `"Track-1 D3"` (both blocker and
open_question live in M014 D3 substrate — single shared label).

### 3.5 `InsightsReader.refresh()` ordinal-22

After `gitDelta` read (line ~219), reads `lastSeenCursor?.lastSeenAtMs`
on MainActor before the detached Task, then inside the detached block
calls `insights.recentActivityFeed(since: cursorMs, limit: 100)` and
composes via `SinceLastActiveItem.compose`. `cursorMs == nil` (pre
`configure(lastSeenCursor:)` call) → returns `[]` so snapshot eq-Hash
invariant is preserved.

`configure(lastSeenCursor:)` is the two-phase init entrypoint called
from LeafApp root via `.task` modifier:

```swift
.task {
    reader.configure(lastSeenCursor: lastSeenCursor)
}
```

`configure` sets the stored property and triggers an explicit
`refresh()` so the SINCE feed populates on first window appearance.

### 3.6 View tier

3 new files in `Leaf/Views/Window/Home/Blocks/`:

- **`SinceLastActiveBlock`** (~118 LOC) — header `"SINCE YOU WERE LAST
  ACTIVE"` + `LeafCard` with chip strip + content body (empty / no-match /
  populated). Populated body shows `min(visible, 20)` rows then
  `"+N older changes"` toggle + `"Mark all as seen"` footer. Two
  empty-state variants: `"Nothing new since you last looked."` (no data)
  vs `"No matches in this filter."` (filter mismatch, CTA `"Show all"`
  resets to `.all`).
- **`SinceFilterRow`** (~62 LOC) — file-local 5-chip strip with per-chip
  count suffix `"All · N"` / `"Linear · N"` etc. `LeafPill(tone: .accent)`
  for selected, `.neutral` otherwise. Q8 dual-ship discipline acknowledged
  in module comment.
- **`SinceLastActiveRow`** (~100 LOC) — per-item row mirror NeedsYouRow
  shape: `LeafDot(tone:)` from severity + `actorPrefix verb targetTitle`
  composition + `sourceMeta · relativeAge` caption. Tap-to-open
  `sourceURL` via `NSWorkspace.shared.open`; nil URL → inert
  informational row (no `.disabled` so VoiceOver remains reachable).
  `formatRelative(_:)` uses cached `RelativeDateTimeFormatter` with
  `<1m → "now"` rule per T1 line-249 master spec (carry C-T5-9 for
  shared helper when 3rd block adopts).

### 3.7 HomeView Zone-5 callsite

After NeedsYouBlock (Zone-4), full-width `SinceLastActiveBlock` callsite.
`HomeContent` gains `@Environment(LastSeenCursor.self)` +
`@Environment(InsightsReader.self)` injections. `onMarkAllAsSeen`
callback advances cursor and triggers `reader.refresh()` to repopulate
snapshot (Q5 single-cursor decision).

LOC: HomeView 278 → 292 (≤ 310 master spec §7.2 gate 6).

### 3.8 Test coverage (20 new tests)

- `ActivityFeedItemTests` — 3 tests (Codable round-trip, allCases order, rawValue stability).
- `SinceLastActiveItemTests` — 3 tests (content-Equatable, uniqueKey composition, Set de-dup).
- `LastSeenCursorTests` — 5 tests (24h seed, persistence, second-read, markAllAsSeen flow + persistence).
- `SinceLastActiveItemComposeTests` — 13 tests (PR merged, review requested, commit, blocker, open question, unmapped→nil, all 4 status sub-discriminators, comment-to-me, slack mention, slack huddle).
- `ProdInsightsRecentActivityFeedTests` (moat tests, gitignored) — 10 tests (empty DB, cursor filter, ts-desc ordering, limit cap, Linear/Slack/GitHub mapping, D3 detections, sentinel walkback).
- `test_recentActivityFeed_DoesNotLeakBodyFields_TrackTen_T5` in `RelayBodyLeakageTests` — 1 walkback regression (10 forbidden fields).

### 3.9 Privacy walkback / sentinel-injection

Moat reads ONLY allow-listed payload fields via `json_extract`:
`$.source`, `$.event_kind`, `$.issue_key`, `$.to_state_type`,
`$.to_state_name`, `$.linear_issue_url`, `$.repo`, `$.title`,
`$.number`, `$.branch`, `$.pr_url`, `$.channel`, `$.state`, `$.count`.
D3 reads pull `question_excerpt`/`blocker_excerpt` (D3 substrate-
sanctioned 80-char excerpts, not raw bodies — already inside D3 privacy
contract). NEVER reads `body` / `comment_body` / `note_body` /
`email_subject` / `file_contents` / `raw_prompt` / `tool_input` /
`tool_response` / `prompt` / `diff`. Sentinel-injection regression test
in `RelayBodyLeakageTests` injects all 10 forbidden fields into a
seeded event and asserts none reach any `ActivityFeedItem` field. T5
stops being §6 EXEMPT — formal walkback discipline restored.

### 3.10 Substrate-purity diff invariants

| Invariant | T5 ship |
|---|---|
| `ShareEventTypeRegistry.swift` diff | 0 lines |
| SQLCipher migrations diff | 0 lines (30 tables preserved) |
| MCP tools | 15 (unchanged) |
| `event_kind` registry | 198 (frozen) |
| New public protocol methods | +1 (`recentActivityFeed`) |
| New public value types | +3 (`ActivityFeedItem`, `SinceSource`, `SinceLastActiveItem`) |
| New `@Observable` stores | +1 (`LastSeenCursor`) |
| Sentinel-injection walkback tests | +1 (T5 no longer EXEMPT) |
| HomeView LOC | 292 (≤ 310) |
| `InsightsReader.refresh()` SQL calls | 22 → 23 (+1 monotonic) |

---

## 4. Implementation commits

| # | Hash | Subject |
|---|---|---|
| C1 | `3a648f4d` | feat(GUN-47): ActivityFeedItem + SinceSource + SinceLastActiveItem types |
| C2 | `9d25fc42` | feat(GUN-47): LastSeenCursor @Observable store + LeafApp injection |
| C3 | `2aadf506` | feat(GUN-47): recentActivityFeed substrate + sentinel-injection regression |
| C4 | `c7e06e2e` | feat(GUN-47): InsightsSnapshot.sinceLastActiveItems + compose verb/severity |
| C5 | `f85b5656` | feat(GUN-47): SinceLastActiveBlock + SinceFilterRow + Row view tier |
| C6 | `276d1801` | feat(GUN-47): HomeView Zone-5 wiring + SinceLastActiveBlock callsite |
| fix | `aa6cbfa0` | fix(GUN-47): review fix-bundle — D3 label correctness + actorIsMe precondition |
| C7 | this commit | docs(GUN-47): SHIPPED — Track-10 T5 phase spec landing + current-state update |

---

## 5. Stage 6 — independent review findings

`general-purpose` subagent (Sonnet) reviewed C1..C6 against
`feature/track-10-operational-home` baseline. Verdict: **APPROVE** —
0 CRITICAL / 0 HIGH outstanding.

| # | Severity | Disposition |
|---|---|---|
| F1 | MEDIUM | **FIXED INLINE** (`aa6cbfa0`) — `makeSourceMeta` mislabelled `blocker` as "Track-3 D3"; both detection kinds live in Track-1 D3 substrate. Single shared label + test fixture updated. |
| F2 | MEDIUM | **FIXED INLINE** (`aa6cbfa0`) — `actorIsMe: true` default implicitly trusts upstream viewer-filtered Layer B feeds. Added PRECONDITION comment to moat header documenting the trust boundary + carry C-T5-12 hook for Phase 5.4 team-presence broadcast expansion. |
| F3 | LOW | DEFER (carry C-T5-9 region) — empty `sourceMeta` for `slack_huddle_state_change` leaves relative-age caption stand-alone. Cosmetic. |
| F4 | LOW | RISK-ACCEPT (documented) — `LastSeenCursor.lastSeenAtMs` getter seeds-and-persists on first read. Documented at L17; surprising-but-intentional Q5 single-cursor pattern. |
| F5 | LOW | APPROVE — two-phase configure race documented and verified at moat callsite. |
| F6 | LOW | APPROVE — `.animation` cross-fade safe (value-stable `[SinceLastActiveItem]` identity on time-tick). |
| N1, N2 | NIT | praise — cached `RelativeDateTimeFormatter` + 13 compose tests strong coverage. |

---

## 6. Stage 7 — verification (all 9 gates green)

| # | Gate | Result |
|---|---|---|
| 1 | 5/5 Debug schemes BUILD SUCCEEDED | ✅ (`just build-all` exit=0) |
| 2 | SPM tests green (~3035 + 20 new) | ✅ (0 failures across full sweep) |
| 3 | `just check-tokens` 3-tier clean | ✅ "Token-discipline guard passed." |
| 4 | Privacy walkback grep | ✅ Only doc-comment hits in `ActivityFeedItem.swift` (intent-statement listing forbidden fields) |
| 5 | Sentinel-injection T5 test green | ✅ `test_recentActivityFeed_DoesNotLeakBodyFields_TrackTen_T5` passed (0.012s) |
| 6 | HomeView LOC ≤ 310 | ✅ 292 |
| 7 | `InsightsReader.refresh()` SQL count 22 → 23 (+1) | ✅ 23 (`grep -cE "try insights\." Leaf/Models/InsightsReader.swift`) |
| 8 | 0 SQLCipher migrations | ✅ 0 lines in `git diff -- Packages/LeafCore/Sources/LeafCore/DB/` |
| 9 | 0 ShareEventTypeKey entries | ✅ 0 lines in `git diff -- ShareEventTypeRegistry.swift` |

Manual smoke A..H (Дима driver post-launch) pending; carry C-T5-12
documents the teammate-author rows aspirational-pre-Phase-5.4 caveat
for scenario C.

---

## 7. Carries (post-T5)

- **C-T5-1** — Actor display unification when Phase 5.4 team identity lights up. Currently "@teammate" fallback; carry to TeammatePresenceReader-fed display map.
- **C-T5-2** — Extract `LeafFilterChipStrip<T: CaseIterable & Hashable>` generic primitive when 3rd similar chip strip lands (T6 TEAM·N or T8 standup). Rule-of-three discipline.
- **C-T5-3** — Per-source cursor (Q5 Option B) if telemetry shows users want filtered mark-all.
- **C-T5-4** — Verb mapping localization (English hardcoded — Track-9 C-19 lineage).
- **C-T5-5** — Extend `recentActivityFeed` to 25+ kinds (Q3 Option A) when first-ship validates UX.
- **C-T5-6** — `LastSeenCursor` cross-process reactivity via NotificationCenter (Agent doesn't share state with main app today; cosmetic — cursor writes are user-driven from main app only).
- **C-T5-7** — `SinceLastActiveBlock` view-layer unit tests when framework adoption lands (Track-9 §9.3 C-43).
- **C-T5-8** — `linear_status_transition.<to_state_type>` sub-discriminator encoding in moat — verify Track-3 D1 parser emits `to_state_type` for all 4 transition flavors (started / completed / canceled / reopened); cross-tab integration test recommended.
- **C-T5-9** — Extract shared `formatRelative(msAgo:)` helper from per-block copies (currently TodayBlock + WithYouOnThisBlock + SinceLastActiveRow) once 3rd block adopts the "<1m → now" pattern. Rule-of-three.
- **C-T5-10** — Same-content tsMs-tied row de-dup. If batch flush writes two events at same ts with same target, both render. Carry if telemetry surfaces duplicates.
- **C-T5-11** — Linear workspace slug resolution for `composeLinearURL(issueKey:)` helper — currently hardcoded "leaf"; read from `presence_state.linear.workspace_slug` (Phase 4.7.B substrate) once moat injection wired.
- **C-T5-12** — Master spec §4 T5 acceptance scenario "Anton merges a PR → SINCE shows it" is **aspirational pre-Phase 5.4**. GitHub `/users/me/events` returns ONLY my own events; teammate PR merges appear only via my `gh_pr_review_authored` (when I review) or Phase 5.4 team-presence broadcast (not shipped). T5 first ship realistically shows: my own commits/PR opens/merges/reviews/Linear transitions/Slack huddles + my received mentions + my comment-to-me + my D3 detections. Adjust manual smoke scenario C: replace "teammate push commit + wait for poll → SINCE shows it" semantic — this works (commit is MY action); expect NO teammate-author rows until Phase 5.4.

---

## 8. Master spec amendments captured

1. **§3.5 wording** — "Default = process boot timestamp on first read" → "Default = 24h ago on first read; persists immediately."
2. **§5.4 inventory** — +1 row `DerivedInsights.recentActivityFeed(since:limit:)` protocol method (returns `[ActivityFeedItem]`); `ActivityFeedItem` value type added to inventory.
3. **§5.4 location** — `LastSeenCursor` housed in `LeafCore/Share/` (not "Leaf (UI tier)") — test target reuse + LocalAppsStore precedent; still consumed via `@Environment` in Leaf views.
4. **§6.3 sentinel exemption** — T5 stops being EXEMPT; 1 walkback test
   `LEAKED_SENTINEL_T5_RECENT_FEED` added to `RelayBodyLeakageTests`.

---

## 9. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` (§4 T5 · §3.5 · §5.4 · §5.5 · §6.3)
- T1 foundation spec: `docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md`
- T2 RESUME hero spec: `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`
- T2.5 follow-up spec (CTO meta-review pattern precedent): `docs/superpowers/specs/2026-05-22-track-10-T2-5-operational-followup.md`
- T3 inline badge spec: `docs/superpowers/specs/2026-05-22-track-10-T3-younow-badge.md`
- T4 NEEDS YOU spec (pure-UI-refactor precedent): `docs/superpowers/specs/2026-05-22-track-10-T4-needs-you.md`
- LEAF-NN / GUN-NN tracking convention: `docs/conventions/leaf-id-tracking.md`
- Track-9 T8 NEEDS YOU substrate (InboxSeverity + 14-kind precedent): `docs/superpowers/specs/2026-05-21-track-9-T8-inbox-feeder-expansion.md`
- Track-1 D3 detection substrate (open_questions / blockers tables M014)
- `.claude/shared/architecture.md` — substrate baseline (registry 198 / 30 SQLCipher tables / 15 MCP tools — unchanged through T5)
- `.claude/shared/conventions.md` — 8-stage per-phase workflow
