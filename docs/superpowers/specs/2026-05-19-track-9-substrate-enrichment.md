# Track-9 — Substrate enrichment (post-Track-8)

**Status:** STUB. Brainstorm pending in a separate session with fresh Discovery pass.
**Source:** Track-8 master spec §9.1 carry-overs unresolved after Phase 8.9 wrap + a11y audit carry-forwards.

---

## Carry inventory

### Theme A — YOU·NOW depth

Substrate-side enrichment to bring the YOU·NOW row up to master spec §3 mockup parity (currently substrate output covers only first line: app + contextLabel).

- **C-5** LocalAppsStore reactivity — app-root `.environmentObject` injection instead of per-view `@StateObject`. UserDefaults reads stay consistent across instances, but reactivity is bounded by `InsightsReader.refresh()` tick. (Spec §9.1 line 391.)
- **C-6** inMeeting `ical://` deep-link — Calendar URL scheme research + tap modifier extension to gate on `.inMeeting` (currently only `.away` is tappable). Pairs with C-9 enrichment so the meeting payload carries the data needed to construct a deep-link. (Spec §9.1 line 392.)
- **C-9** YouNowMeeting substrate enrichment — read meeting title from `meeting_state_entered` payload (per ADR-010 allow-list), fetch `endsAtMs` from same payload, merge `zoom_meeting_started` snapshots into source `.both` when overlap window matches. (Spec §9.1 line 395.)

Plus the YOU·NOW depth task statement in `.claude/shared/current-state.md`:

- **Git polling deriver** — read git HEAD from Track-6 P2 workspace path captured in `xcode_active_doc_changed` payload → walk up to `.git/HEAD` → branch + LinearIDExtractor → real branch + LEAF-NN populated (today `currentTaskIdentity()` scrapes window-title regex which never matches Xcode title).
- **Intensity bars** — wire Track-4 S3 IntensityAggregator (default OFF, Input Monitoring TCC dual-prompt) via Settings → System Observers → Intensity toggle ON with discoverable UX hint that YOU·NOW row benefits from enabling.
- **Label tweak** — `Started HH:MM · Xm` → `X min focused` for spec §3 wording parity (or hybrid).
- **`.away` / `.deepWorkFocus` rich enrichment** — corresponding substrate-side gaps so non-`.active` states render with parity to mockup.

### Theme B — Empty state + presence enrichment

- **C-10** WithYouOnThisBlock empty CTA missing N count — substrate needs either new `totalActiveTeammates` deriver or plumb teammate list through `InsightsSnapshot`. Privacy surface expansion considered. Phase 5.4 enrichment. (Spec §9.1 line 399.)
- **C-13** `TeammateMatch.durationSec` hardcoded 0 — compute duration from earliest task-matching snapshot per teammate (`SameTaskMatcher.makeMatch:73`). Phase 5.4 / Track-9. (Spec §9.1 line 402.)

### Theme C — Route + URL plumbing

- **C-12** Row tap routes to Team tab without teammate selection — need Team-tab teammate detail screen + `RouteCoordinator.pushTeam(memberID:)`. Track-9 / separate feature. (Spec §9.1 line 401.)
- **C-15** `RouteCoordinator.openURL(_:URL)` extraction — if P7 WHERE STOPPED or future blocks also need external URL open, centralise: telemetry hook, error surface, URL allow-list per privacy review. (Spec §9.1 line 407.)
- **C-16** `InboxItem.sourceURL` nil for D3-derived items — propagate `context_ref` (slack_thread_ts / linear_issue_ref / github_pr_ref) into detection tables and synthesise `sourceURL` at deriver boundary. Phase 4.8/4.9 backend pairing. (Spec §9.1 line 408.)

### Theme D — WHERE STOPPED enrichment

- **C-20** Line 2 dedicated last-commit subject — separate SQL helper `recentLastCommit(maxAgeMs:)` on `DerivedInsights` + LeafCorePrivate query against `events WHERE event_kind = 'git_commit' AND timestamp >= now - 4h ORDER BY timestamp DESC LIMIT 1`. Master spec §4.5 mockup. (Spec §9.1 line 412.)
- **C-21** `anchorEventId → file path:line` resolution — add file_path+line to `events` payload allow-list for AX / FSEvents collectors + add `WhereStoppedSnapshot.anchorFilePath: String?` + `.anchorLine: Int?` fields. Pairs with C-20. (Spec §9.1 line 413.)

### Theme E — Analytics surface

- **C-23** Analytics surface real content — dedicated brainstorm + spec for substrate additions (`DerivedInsights.weeklyMetrics(now:)` or equivalent), LeafCorePrivate Prod impl, full surface design (charts, streaks, deltas, peak-hour, WoW). Phase 8.8 shipped a placeholder. (Spec §9.1 line 415.)
- **C-24** `InsightsSnapshot.recentActivity` orphan drop — Phase 8.8 deleted `ActivityView` (the only consumer); `InsightsReader.refresh()` still fetches ~200 rows per tick for zero UI consumers. LeafMCP `RecentActivityTool` calls `recentActivity` via its own reader, so substrate stays. Drop only the `InsightsSnapshot` field + refresh-tick fetch once Analytics surface design is settled. (Spec §9.1 line 416.)

### Theme F — Reader state machine

- **C-1** Hybrid surface pills — semantic per-surface units: capture surfaces show attention-time (`Claude Code · 1h 47m`), Layer B providers show action-noun count (`Linear · 3 issues`). Extend `SurfacePill` shape, add 3 SQL queries in `ProdInsights+TodayMetrics.swift`, close Phase 8.1 emission gap (Layer B router branch is dead code today). (Spec §9.1 line 387.)
- **C-2** Error-state last-known retention — refactor `InsightsReader.State.error(message: String)` → `error(message: String, lastKnown: InsightsSnapshot?)` + `HomeView` rendering so `.error` shows banner above `HomeContent(snapshot: lastKnown)` instead of full-page banner. (Spec §9.1 line 388.)

### Theme G — InboxBlock SQL re-fetch

- **C-14** Search debounce / SQL re-fetch — either 150 ms `Task` cancellation debounce on `searchQuery` change, or push filter/query down into `InsightsReader.refresh(inboxFilter:inboxQuery:)` with per-keystroke SQL re-fetch. Carry until Layer B Phase 4.8/4.9 lights up cardinality > 1000 in busy team accounts. (Spec §9.1 line 406.)

### Theme H — Localization

- **C-19** `InboxItemRow.severityWord` hardcoded English ("Urgent" / "Needs response" / "Informational"). Touchpoint when broader `Localizable.strings` extraction lands. Track-9 / Localization track. (Spec §9.1 line 411.)

### Phase 5.6 dependency

- **C-11** WithYouOnThisBlock offline / stale footer — muted footer "Team data stale ({lastSync} ago). Reconnecting…" when relay disconnected OR last `presence_history` sync > 10 min. No relay status signal in `InsightsSnapshot` today; pairs with relay status plumbing in Phase 5.6. (Spec §9.1 line 400.)

### v1.1 deferred

- **C-8** Resume CTA branch-deletion staleness — validate via `LinearIDExtractor` registry refresh or `git branch --list` check before showing CTA. Master spec tags v1.1, not blocking ship. (Spec §9.1 line 394.)

---

## Phase 8.9 a11y audit carry-forwards

Findings from the general-purpose a11y audit subagent run during P9 polish that exceed view-level inline-fix budget:

- **Design-system primitive a11y audit** — `LeafPill`, `LeafInput`, `LeafIconChip` semantics when used as Button label or inside Button hierarchy. Currently each view-level consumer is responsible for wrapping correctly; primitive-level fix would centralise this.
- **WhereStoppedBlock `headerText` time refresh** — `headerText` recomputes `Date()` on every body eval; VoiceOver may re-read stale value on focus return. Needs Timer-driven invalidation or fresh-on-focus pattern. Non-trivial.
- **TodayBlock pill `accessibilityLabel` vs `accessibilityHint` semantic separation** — current uses label for "Xcode — open details"; should split label = visible text + hint = action description per HIG.
- **InboxFilterRow selection-change announcement** — VoiceOver users don't hear filter changes; needs `.accessibilityValue("Selected")` or `UIAccessibility.post` notification.
- **WithYouOnThisBlock teammateRow label/hint split** — accessibilityLabel concatenates "tap to open Team tab" which should be hint not label.
- **Pluralization** — "Show N more surfaces" / "+N more" singular case (N=1) not handled. Localization-adjacent.

---

## Next step

Spec written via `superpowers:brainstorming` skill in a new session with full Discovery pass over Theme A-H surfaces + a11y carry-forwards. Track-9 is multi-phase (likely T1..T9 mirroring theme split, with the a11y primitive audit as a cross-cutting sweep).

---

## References

- Master spec: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §9.1 (canonical backlog)
- P9 spec: `docs/superpowers/specs/2026-05-19-phase-8-9-polish.md`
- Phase 8.x per-phase specs (8.3..8.8) in `docs/superpowers/specs/`
- Current-state Track-9 paragraph: `.claude/shared/current-state.md` (YOU·NOW depth task statement)
