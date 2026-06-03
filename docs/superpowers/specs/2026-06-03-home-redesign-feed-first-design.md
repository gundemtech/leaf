# Home Redesign — Feed-First Information Architecture

**Date:** 2026-06-03
**Status:** Design — pending plan
**Author:** brainstorm w/ Dmitrii

## Problem

The current Home screen renders six stacked surfaces (RESUME, TODAY metrics card,
NEEDS YOU + its own search/filter strip, SINCE LAST ACTIVE + a second filter strip,
YOU'RE ON, RECAP + EOD). It fails the project's own criterion — "каждый экран понятен
за 10 секунд" — for three reasons:

1. **Duplication.** `dev · +22 ahead of main` appears in both RESUME and YOU'RE ON.
   RECAP ("morning brief") and EOD ("end-of-day") show near-identical commit lists.
2. **Meaningless rows.** NEEDS YOU and SINCE rows render the identifier twice
   (title = `GUN-52`, subtitle = `GUN-52`) — zero human context.
3. **Visual noise.** Two filter-chip strips stack within one scroll; no clear hero,
   so the eye has nothing to anchor on.

## Decisions (from brainstorm)

- **Primary job of Home = feed-first** ("что было в команде / в работе, пока меня не было").
  Activity feed becomes the hero; personal context demotes to a thin strip.
- **NEEDS YOU and SINCE stay as two distinct sections** (need-response vs FYI), but
  NEEDS YOU compresses to a compact block and SINCE becomes the hero feed.
- **Personal blocks collapse to one Status line + Resume.** RESUME, TODAY card, and
  YOU'RE ON merge into a single status strip. Full metrics + standup move behind a tap.
- **Metrics + Digest live in a popover** opened by tapping the Status strip.
- **RECAP + EOD merge into one "Digest"** block (time-of-day switches which face shows)
  inside that popover.
- **Search moves from NEEDS YOU to the feed** — it filters ACTIVITY.

## Target structure

Three visible sections + one popover (down from six stacked surfaces):

```
┌───────────────────────────────────────────────────────────┐
│ ● dev +22 ahead · 6h15m focused · AI 26%        [Resume ▸] │  STATUS (1 line)
│                                          tap → metrics + Digest popover │
├───────────────────────────────────────────────────────────┤
│ NEEDS YOU · 2                                          [→]  │  compact
│ • GUN-52  Fix OAuth refresh — review                       │  real title + reason
│ • GUN-31  Relay heartbeat — question                       │  up to 2–3 rows
├───────────────────────────────────────────────────────────┤
│ ACTIVITY                                              [⌕]   │  HERO
│ [All 70] [Linear 3] [GitHub 66] [Slack 0] [Detections 1]   │  one filter strip
│                                                             │
│ ● you merged    Fix OAuth refresh     PR#1 · 2m            │  real titles
│ ● you completed Wire relay invite     GUN-51 · 1w         │
│ ● …                                                         │
│                                        [Mark all as seen]   │
└───────────────────────────────────────────────────────────┘
```

## Components

### 1. StatusStrip (new)
Replaces ResumeHeroBlock + TodayBlock card + YoureOnBlock on the default view.
- One line: presence dot · branch + ahead/behind · focused duration · AI ratio.
- Trailing **Resume** button (the RESUME card's primary CTA; opens last anchor / Linear / diff).
- Tappable surface (whole strip, ≥44pt) → presents **StatusPopover**.
- Single source of truth for branch/WIP — kills the RESUME↔YOU'RE ON duplicate.

### 2. StatusPopover (new)
Opened from StatusStrip. Contains the demoted detail:
- Full TODAY metrics grid (focused / AI ratio / sessions / switches / commits).
- **Digest** — RECAP and EOD merged into one block; time-of-day picks the default face
  (morning → recap, evening → eod), with a manual toggle. Reuses existing
  StandupComposer output; dedupes the identical commit-list bug by composing once.

### 3. NeedsYouBlock (compress)
- Header `NEEDS YOU · N` + `[→]` expand affordance.
- Default: count + up to 2–3 rows showing **real title + reason** (review / question / mention).
- Remove the inline search field and the NeedsYouFilterRow from the default surface
  (full list + filters available on expand).

### 4. ActivityFeed (was SinceLastActiveBlock) — hero
- Section label `ACTIVITY`.
- Keep the single SinceFilterRow (All / Linear / GitHub / Slack / Detections).
- Add a **search field** (relocated from NEEDS YOU) that filters the feed rows.
- Rows render human-readable titles (see Data fixes).
- Keep "Mark all as seen" + "+N older" expand.

## Data fixes (separate workstream — required for readability)

Titles are already captured and persisted (privacy model allows self-authored labels:
issue title, PR title, branch name). The composers just don't use them.

- **SINCE / ActivityFeed (Linear branch):** `ProdInsights+RecentActivityFeed.swift`
  sets `targetTitle` from the Linear *issueKey* (~line 143/157) instead of the stored
  `title` in the event payload (`LinearCollector.makeEvent` line 348). Fix: read the
  persisted `title`, fall back to ref only when absent.
- **NEEDS YOU feeders:** `ProdInsights+InboxItems.swift` populates `InboxItem.title`
  with bare refs/synthetic text for every feeder (Linear comments ~355, GitHub
  comments ~167, review requests ~218, notifications ~302). Fix: pass through the real
  persisted title where available; keep ref + reason in `sourceMeta`.
- GitHub ActivityFeed branch already uses the real title (`title ?? ref`, ~line 186) —
  use it as the reference pattern.

## Out of scope (YAGNI)

- No new MCP tools, no schema changes — titles already persisted.
- No change to Team / Connections / Organization / Settings tabs.
- Global cross-section search deferred (search is feed-scoped only in v1).

## Testing

- Composer unit tests: feed/inbox items surface the real title when payload carries one,
  fall back to ref when it doesn't. Privacy regression: title is only ever a
  self-authored label (no body/excerpt leakage into title).
- View smoke (manual, per project UI discipline): Home renders 3 sections + popover,
  no duplicate branch line, no duplicate commit list, rows show titles.

## Acceptance criteria

1. Home default view shows exactly: StatusStrip, NeedsYouBlock (compact), ActivityFeed.
2. Tapping StatusStrip opens StatusPopover with metrics + single Digest (no duplicated list).
3. No `dev +22 ahead` duplication; YOU'RE ON no longer a separate card.
4. NEEDS YOU and ACTIVITY rows display human-readable titles, not ID-twice.
5. Exactly one filter strip on the default view (ActivityFeed's).
6. Search filters the feed.
7. `just preflight` green.
