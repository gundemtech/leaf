# Track 6 — Existing-Surface Depth Contract

**Status:** Draft (2026-05-15). Promoted to "Active" after first sub-phase (P1) spec is reviewed against it.
**Owners:** Authors of P1–P7 sub-phase specs.
**Audience:** Anyone writing a spec for any sub-phase of Track 6.

---

## 1. Purpose & status

This document is a **reference contract**, not an implementation plan. Track 6 ("existing-surface depth") decomposes into 7 sub-phases (P1–P7); each owns its own design + plan; this contract fixes the constants between them so a choice in one sub-phase does not surprise another.

**Track 6 brings the apps currently covered at "surface" or "narrow" depth to the depth-parity that Slack / Linear / GitHub reached through Track 3.** Today's substrate for these apps is intentionally minimal — Claude Code captures the four core hook flavours; Track-4 S1/S2 give AppleScript active-document signals for Xcode / Zoom / Safari and EventKit basics for Calendar; AX window-title fallbacks cover GPT / vscode / JetBrains / Chrome. None of these surfaces yet land the rich event_kind vocabulary, per-flavour parsers, presence-state writes, MCP queries, and cross-link substrate that the Layer B providers gained in Track 3 D1–D4.

**Track 6 scope is intentionally constrained** — it brings *existing* surfaces to depth parity. It does **not** introduce net-new providers (Notion / Jira / Gitlab / Figma / Discord / Gmail), which live in a future track. It does **not** ship IDE extensions or Chrome extensions (Layer D V2, separate track).

**Out of Track 6 scope:**

- Net-new providers (Layer C MCP-aggregator candidates — separate track).
- IDE / browser extensions (Layer D V2 — separate track).
- Tier-based summarization or new Derived Insights tools (Phase 4.9).
- Cross-provider Derived Insights (Phase 4.9).
- Vendor surfaces with no further depth available (GPT — captured as P7 won't-list confirmation, not implementation).
- vscode / JetBrains plugin work (Layer D V2).

Whitepaper (`leaf-docs`, v0.1-beta) remains source of truth for public-facing product decisions. Implementation moat (exact hook payload field names, sqlite watcher cadences, FSEvents path patterns, AppleScript dictionary entries chosen) lives in `LeafCorePrivate` or per-collector private modules, not here.

This is a **living document.** Amendments over Track 6 lifetime are expected.

---

## 2. Goal — fitness function

For each app in scope, Track 6 is **done** when:

1. **Ceiling-mapped.** The realistic ceiling per available mechanism (Layer A hooks / AppleScript / AX / FSEvents / vendor REST API / local sqlite watch) is documented in a research doc co-located with the phase spec. The decision "this is the deepest we can go without an extension" is explicit, not implicit.
2. **Event vocabulary lands.** New `event_kind` discriminators capture the user-meaningful state changes on that surface. Targeted depth: comparable order-of-magnitude to Linear (32 kinds) / GitHub (52) / Slack (27) for apps where ceiling supports it; documented lower for ceiling-constrained surfaces.
3. **Parser correctness.** Per-flavour parsers tolerate edge cases (cold-start, version drift, locale variants, hardened-sandbox refusal) — same posture as Track-3 D1/D2/D3.
4. **Privacy contract preserved.** Every new payload field walks back through ADR-010: no message bodies, no compiler/build output, no debugger state, no URL content beyond the per-folder/per-domain allow-list pattern. Track-3 `RelayBodyLeakageTests` extended to cover new event_kinds.
5. **Share Controls.** ShareEventTypeKey registry append, default OFF for every new entry. Naming convention matches Track-3/4: `<app>_<verb>_<noun>`.
6. **Smoke verified.** Per-app acceptance smoke runs on author's Mac under realistic load and produces expected `events` rows + populates aggregations where relevant.

---

## 3. Mandatory pre-phase research stage

**Every phase (P1–P7) MUST start with a Stage 0 — Deep Research pass BEFORE brainstorming.** Output: a research companion doc next to the phase spec, named `YYYY-MM-DD-track-6-PN-<app>-research.md`.

**Why explicit.** Surface ceiling-mapping is the highest-leverage decision in this track. Picking the wrong mechanism (e.g. AppleScript when FSEvents is available; AX title when official hooks exist; vendor REST when local file watch gives richer signal) bakes in shallow capture for the lifetime of the collector. Track 6's whole point is depth — getting Stage 0 right is the only way that point is met.

### 3.1 Research checklist per app

For each phase, the research doc covers:

1. **Official vendor surfaces.** Read vendor docs cover-to-cover for the relevant surface area (Apple Developer / Google API console / vendor-specific docs). Use `mcp__plugin_context7_context7__query-docs` to pull current API surface — training-data snapshots are stale for vendor APIs.
2. **WWDC / vendor sessions.** Where an Apple framework is involved (FSEvents, AppleScript Automation, EventKit, AX, AVCaptureSession, etc.), pull relevant WWDC transcripts via the `apple-docs-research` skill. Note version cutoffs: which signals require macOS 14+ vs 13+.
3. **OSS reconnaissance.** Search GitHub for the top 3 OSS projects doing similar capture for that app (e.g. ActivityWatch / RescueTime open components / Wakatime extensions / IDE telemetry plugins). Read their per-app collectors end-to-end. Extract: what they capture, what they explicitly do not, TCC posture, how they handle the long tail of edge cases.
4. **TCC / sandbox audit.** Per app: does the new mechanism trigger a new TCC prompt? Does it fail under hardened sandbox? What is the realistic prompt drop-off risk? Does it work for non-author users (other macOS versions, other app versions, locale variants)?
5. **Ceiling-vs-effort table.** At the end of the research doc, list every viable signal with: **(a)** mechanism, **(b)** effort estimate (S/M/L), **(c)** value tier — `Critical` (must land) / `Strong` (should land) / `Marginal` (skip unless trivial). Skip `Marginal` unless effort is S.
6. **Anti-patterns from prior tracks.** Read `.claude/shared/current-state.md` Open Tensions + carry-overs from Track-3 / Track-4 phases. Don't repeat known-bad patterns (cold-start race vs warm tick #1, dispatcher parity drift, raw third-party IDs in payloads, sentinel-leak regressions).
7. **Phase-level question to user.** Surface 1–3 questions in the research doc that need a product call before brainstorming (e.g. "Chrome history watcher is L4 — opt-in flow per-domain or per-folder? Per-domain matches Slack allow-list pattern."). These get answered before Stage 2 brainstorm starts.

**Result.** Brainstorming starts from "here's the real ceiling and the realistic shape of the work", not "let me guess what's possible from training data".

---

## 4. Architecture

Track-6 piggybacks on existing substrate; net-new components are rare.

- **Collectors.** New per-app capture modules live in `Packages/LeafCore/Sources/LeafCore/Collectors/` co-located with their family (Track-3 directory for API-polling providers; Track-4 directory for Layer A surfaces; AI-collab directory for hook-based AI tooling).
- **Schema additions.** Most phases need only **new event_kinds** + ShareEventTypeKey entries (no new tables). Net-new tables only for: provider OAuth state (Google Calendar API in P4), per-app aggregation derivations where a separate aggregator is the right shape (Claude Code AI session rollup in P1, optional).
- **MCP tools.** Track 6 generally does **not** add new MCP tools. The depth lands as event_kinds + payload richness; consumers (Phase 4.9 Derived Insights, Track-5 Team feed) read from `events` table directly. Exceptions ratified in per-phase brainstorming only when a new user-facing query genuinely requires structured access.
- **Cross-link substrate.** Where Track-1 `event_links` substrate applies (e.g. Xcode → Linear via in-file references, Calendar event → Zoom meeting), per-phase brainstorming proposes link kinds to add to the cross-link table.
- **Existing Track-4 collectors.** Where a Track-4 S2 AppleScript collector already captures a shallow signal (e.g. `xcode_active_doc_changed`, `safari_tab_count_changed`), the phase extends — not replaces — that collector. The shallow event_kind stays; new event_kinds layer on.

---

## 5. Sub-phase decomposition

```
   ┌──────────────────────────────────────────┐
   │  P1 — Claude Code Deep                   │   independent
   │  Per-tool event_kinds + session timing   │
   │  + idle-within-session + AI ratio derive │
   └──────────────────────────────────────────┘

   ┌──────────────────────────────────────────┐
   │  P2 — Xcode Deep                         │   independent
   │  DerivedData FSEvents (build/test) +     │
   │  AppleScript scheme/target depth         │
   └──────────────────────────────────────────┘

   ┌──────────────────────────────────────────┐
   │  P3 — Browsers Deep (Safari + Chrome)    │   independent
   │  AppleScript tab enum +                  │
   │  History sqlite watch +                  │
   │  L4 per-domain / per-folder opt-in flow  │
   └──────────────────────────────────────────┘

   ┌──────────────────────────────────────────┐
   │  P4 — Google Calendar Deep               │   independent
   │  Layer B Google Calendar API REST +      │
   │  RSVP + recurring detect +               │
   │  EventKit overlap reconciliation         │
   └────────────┬─────────────────────────────┘
                ▼
   ┌──────────────────────────────────────────┐
   │  P5 — Zoom Deep                          │   depends on P4
   │  Title parsing + duration tracker +      │
   │  Calendar event cross-link               │
   └──────────────────────────────────────────┘

   ┌──────────────────────────────────────────┐
   │  P6 — IDEs Surface Cap (vscode + JB)     │   independent
   │  Window-title workspace inference +      │
   │  FSEvents in user project folders +      │
   │  Documented ceiling (no extension)       │
   └──────────────────────────────────────────┘

   ┌──────────────────────────────────────────┐
   │  P7 — GPT Cap Documented                 │   independent
   │  Confirm ceiling, document permanent     │
   │  won't-list, no new capture              │
   └──────────────────────────────────────────┘
```

| Phase | App(s) | Sequential dep | Primary mechanism family |
|---|---|---|---|
| **P1** | Claude Code | none | Layer A hooks (existing) + jsonl parser extension |
| **P2** | Xcode | none | AppleScript depth + FSEvents (DerivedData / xcresult) |
| **P3** | Safari + Chrome | none | AppleScript per-tab + History sqlite watch + L4 opt-in |
| **P4** | Google Calendar | none | Layer B REST + OAuth + EventKit reconciliation |
| **P5** | Zoom | P4 (Calendar cross-link) | AppleScript title parse + duration tracker + cross-link |
| **P6** | vscode + JetBrains | none | AX + FSEvents (project folders) + ceiling doc |
| **P7** | GPT (ChatGPT Desktop) | none | Confirm ceiling, no implementation |

**Ordering.** P1 / P2 / P3 / P4 / P6 / P7 parallel-safe (different files, different surfaces). P5 sequential on P4 because Calendar cross-link is a substrate dependency. Within Track-6 work, the only true dependency is P4 → P5.

**Parallelism with Track 5.** All Track-6 phases are parallel-safe with Track 5 (Sasha's collaboration redesign). Collision zones are minor:
- Migration counter: Track-5 books M019–M023; Track-6 takes M024+.
- ShareEventTypeKey registry: append-only, merges cleanly.
- `ActivityFeedMapper`: switch-case append, merges cleanly.
- No shared schema tables touched by both tracks.

---

## 6. Schema changes — overview

### 6.1 Migrations (reserved range)

- **M024** — Claude Code AI session aggregation table (P1, optional — may inline into existing events table if just new event_kinds).
- **M025** — Xcode build/test event metadata flavor (P2, optional — likely just new event_kinds without new table).
- **M026** — Browser history watch substrate (P3 — per-domain allow-list table + watcher cursor table).
- **M027** — Google Calendar OAuth state + integrations row (P4 — mirrors Linear/GitHub pattern: integrations row + provider-specific cursor table).
- **M028+** — reserved for Phase 4.9 Derived Insights (not Track 6).

Final migration numbers + table shapes ratified in per-phase brainstorming. Pre-reserved here only to avoid mid-track renumbering.

### 6.2 ShareEventTypeKey registry

Each phase appends to the registry. Default OFF for all new entries. Naming convention: `<app>_<verb>_<noun>` matching Track-3/4 pattern.

Estimated additions (will be tightened in per-phase brainstorming after Stage 0 research narrows ceiling):

- **P1** Claude Code: order of ~10 entries (per-tool variants + session timing).
- **P2** Xcode: order of ~6 entries (build / test / scheme / target / config / clean).
- **P3** Browsers: order of ~8 entries combined (per-tab nav, bookmark, download, history-visit).
- **P4** Calendar: order of ~6 entries (RSVP / created / declined / recurring / overlap-with-focus / organizer-of).
- **P5** Zoom: order of ~3 entries (title-observed / duration-recorded / calendar-linked).
- **P6** IDEs: order of ~3 entries (workspace_changed / project_folder_active / file_focused — capped without extension).
- **P7** GPT: 0 entries.

Baseline current **152** → target **≈190** if all Critical+Strong signals from research docs land. (Final delta locked in research stage.)

---

## 7. Privacy contract

ADR-010 walkbacks reaffirmed per phase. Specifically:

- **P1 Claude Code.** Prompt / response content remains permanently forbidden. New per-tool event_kinds capture metadata only (tool name, file path, timestamp, success/fail, byte counts), never tool *inputs* or *outputs* beyond a count or hash. `RelayBodyLeakageTests` extended.
- **P2 Xcode.** File path / scheme name / target name capture allowed at L4. Build log content, compiler error text, test failure assertion messages, debugger state — forbidden. xcresult bundles parsed only for structural metadata (pass/fail counts, duration), not failure messages.
- **P3 Browsers.** Full URLs are L4-L5 content. Default OFF. Opt-in per-domain allow-list pattern (mirror Track-3 Slack channel allow-list). History sqlite watcher reads URLs only when allow-list matches. Bookmark titles never captured. Cookies / form data / autofill — permanently forbidden.
- **P4 Google Calendar.** Event title allowed at L4 (mirrors EventKit current behaviour). Attendee PII, event description / body, meeting notes — forbidden. Recurring rule structure (frequency / interval) allowed without rule body.
- **P5 Zoom.** Meeting title parsing from window title is L4 (already implicit in current AppleScript). Participant list, screen-share content, chat messages, recording state — forbidden.
- **P6 IDEs.** Workspace name from window title at L3. File contents, console output, debugger state, terminal output, search query strings — forbidden. FSEvents in project folders captured only for already-watched folder bookmarks (existing Track-1 substrate).
- **P7 GPT.** No new capture. Ceiling documented as permanent won't-list entry in whitepaper.

---

## 8. UI surface contract

No new top-level UI screens.

- **Settings → Local Apps** (Track-4 S2) gains per-app sub-toggle groups for P2 / P5.
- **Settings → System Observers** (Track-4 S3) gains the browser history watcher toggle (P3) and DerivedData watcher toggle (P2).
- **Settings → Connections** (existing) gains Google Calendar provider entry (P4) following Linear/GitHub/Slack pattern.
- **Settings → AI Tools** (existing Claude Code section) extends with the new P1 sub-toggles.
- **Privacy walkback dashboard** (existing Track-2 D4 surface) re-renders with new event_kinds.

Per-phase brainstorming spec'es exact toggle copy + grouping.

---

## 9. Per-phase 8-stage workflow

Each phase runs the full 8-stage cycle from `.claude/shared/conventions.md` "Одна phase = одна сессия", with Stage 0 prepended:

0. **Deep Research** (per Section 3) — output `*-research.md` companion doc; user answers any product-level questions surfaced.
1. **Discovery** — `Explore` subagent snapshot of relevant collectors / parsers / schema / share-event registry; main session cross-checks key files.
2. **Brainstorm** — `superpowers:brainstorming` skill in full flow, with research doc as anchor; approaches with tradeoffs; design sections with per-section approval.
3. **Spec write** — `docs/superpowers/specs/YYYY-MM-DD-track-6-PN-<app>.md`; self-review (placeholders / consistency / scope / ambiguity); user gate.
4. **Plan** — `superpowers:writing-plans`; step-by-step atomic-per-commit with acceptance criteria.
5. **Implementation** — `superpowers:test-driven-development` per step, sequential; all tests pass + build green between steps.
6. **Independent review** — `superpowers:code-reviewer` subagent against spec + plan; main session via `superpowers:receiving-code-review`. Every comment addressed.
7. **Verification** — `superpowers:verification-before-completion` skill: all tests pass (verified), all builds green; per-app smoke (golden path + edge cases).
8. **Ship** — final commit `docs(shared): Phase Track-6 PN landed — current-state update`; PR with review verdict; merge + branch cleanup.

**Stage 0 is the explicit addition vs Track 5.** Without it, brainstorming starts from incorrect ceiling assumptions for surfaces whose maximum signal we have not yet probed.

---

## 10. Acceptance criteria — track level

Track-6 is **complete** when:

- All 7 phases shipped to `main` (or P7 = won't-list documented + closed without code change).
- ShareEventTypeKey registry updated, total ≈190 with default-OFF posture preserved.
- `RelayBodyLeakageTests` extended for every new event_kind; passes.
- `DispatchCoverageTests` parity fence extended where new mapper branches added.
- Per-app smoke from author's Mac shows realistic-load capture and parser correctness under cold + warm tick paths.
- `.claude/shared/current-state.md` updated with Track-6 closing summary (depth-parity ambition, per-app ceiling outcome).
- Whitepaper sync per `/sync-docs` for any contract-level decisions surfacing publicly (depth-parity ambition is public-safe; specific FSEvents paths / sqlite schemas / hook field names are moat, stay private).

---

## 11. Out of scope (won't-list this track)

- Net-new providers (Notion / Jira / Gitlab / Figma / Discord / Gmail) — Track 7+.
- IDE / browser extensions (vscode plugin / Chrome extension / JetBrains plugin) — Layer D V2 separate track.
- Tier-based summarization — Phase 4.9.
- Cross-provider Derived Insights tools (new MCP tools spanning multiple Track-6 surfaces) — Phase 4.9.
- GPT API integration for personal activity — vendor-blocked, permanent won't-list (P7 documents this).
- Cursor / Windsurf / continue dev hooks — separate AI-collab track (architecture's Layer A v1.1 plan).
- Discord RPC local socket capture — separate track if/when prioritised.
- Gmail metadata-only capture — separate track; low value-on-effort given ADR-010 forbids subjects/bodies.

---

## 12. Decision log placeholder

(Section reserved. Per-phase spec PRs that surface contract-level amendments append here with date + rationale + reference to discussion.)
