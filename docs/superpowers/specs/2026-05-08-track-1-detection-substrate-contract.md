# Track 1 — Detection Substrate Contract

**Status:** Draft (2026-05-08). Promoted to "Active" after first sub-phase (D1) spec is reviewed against it.
**Owners:** Authors of D1–D3 sub-phase specs.
**Audience:** Anyone writing a spec for D1 / D2 / D3 of Track 1, or Track 2 (team distribution) once Track 1 ships.

---

## 1. Purpose & status

This document is a **reference contract**, not an implementation plan. Track 1 ("solo detection substrate") decomposes into 3 sub-phases (D1, D2, D3); each owns its own design + plan; this contract fixes the constants between them so a choice in one sub-phase does not surprise another.

**Track 1 scope is intentionally narrow:** make the four existing detection sources — **Claude Code, GitHub, Linear, Slack** — capture what's actually needed to answer the 7 product use cases, plus pattern-based derive layer over what's captured. **No LLM, no embeddings, no Summarizer, no AI-tool diversity beyond Claude Code, no AST parsing, no calendar deepening.** Those belong to later tracks.

Whitepaper (`leaf-docs`, v0.1-beta) remains source of truth for public-facing product decisions. Implementation moat (precise patterns, exact thresholds, body-encoding internals, prompt strings, exact rate-limit budgets) lives in `LeafCorePrivate`, not here.

This is a **living document.** Amendments over Track 1 lifetime are expected.

---

## 2. Goal — fitness function

Track 1 is **done** when the following 5 use cases work end-to-end on a solo user (one Mac, no team), executed via MCP from Claude Code / other clients. The Leaf side returns a **structured JSON** payload — the AI client formulates the narrative answer itself from the structured timeline + flagged decisions / open questions / blockers / links.

| # | User question (in MCP client) | Structured response shape |
|---|---|---|
| **UC1** | "что я делал в пятницу по auth?" | Topic-filtered timeline: commits in `src/auth/` with messages + CI status, Slack messages from `#leaf-architecture` with body excerpts + open-question flags, Linear ticket descriptions linked via ID |
| **UC3** | "что менялось в `/payments` за 2 недели?" | Path-history timeline + Linear ticket descriptions for each linked commit + raw flags from issue bodies (no LLM extraction — AI client reads body excerpts) |
| **UC4** | "почему мы вынесли OAuth refresh на сервер?" | Decision record from `decisions` table: timestamp, initiator, raw reasoning excerpts from Linear description + Slack thread, links to implementation commits |
| **UC5** | "что мне знать до ревью PR #142?" | PR metadata + commits + linked Linear ticket + relevant Slack thread bodies (via `event_links`) + absence flag computed on-the-fly ("design choice X surfaced in thread, no reply from `@reviewer`") |
| **UC6** | "что мы решили по бэкапам?" | Decision record (same shape as UC4). Slack-bot surface (channel `/leaf` command) is **out of Track 1 scope** — Track 2. |

**UC2** ("что Саша делал сегодня?") and **UC7** ("team weekly summary") remain in Track 2 (team distribution) — they need cross-device sharing, not just detection.

Each sub-phase spec lists which use cases it unblocks and writes integration tests against that mapping.

**Why no LLM in Track 1.** AI clients (Claude Code, Cursor, etc.) already excel at turning structured input into prose. A rich structured response is more useful to the LLM-on-the-other-side than a pre-baked narrative. We keep summarization out of our process — that's a separate later track if/when we want non-LLM-equipped surfaces (Slack-bot, Native UI prose mode).

---

## 3. Three-layer architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Surface (existing)                                          │
│  MCP server · Native UI · CLI                                │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  Layer 3 — Structured Query API     (D3, NEW)                │
│  ─ 3 high-level MCP tools (returning structured JSON):       │
│      leaf_query_activity / leaf_get_decision /               │
│      leaf_current_work                                       │
│  ─ Composes timeline + linked entities + detector outputs    │
│  ─ NO LLM call — AI client narrates from JSON                │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  Layer 2 — Index + Derive            (D2 + D3, NEW)          │
│  ─ FTS5 keyword index over bodies (D2)  — topic search       │
│  ─ Cross-source link graph (D2)         — Linear ID, branch, │
│    file path, Slack-thread → PR refs                         │
│  ─ Decision detector (D3)               — pattern-based      │
│  ─ Open-question detector (D3)          — pattern-based      │
│  ─ Blocker detector (D3)                — Linear stuck +     │
│    pattern-based                                             │
│  ─ Where-stopped deriver (D3)           — last-WIP signal    │
│  ─ Absence flag (D3)                    — computed at query  │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  Layer 1 — Capture           (D1, EXTEND existing)           │
│  ─ Bodies: Linear (issue.description, comment.body),         │
│    Slack (message.text + thread replies),                    │
│    GitHub (pr.body, issue_comment.body, pr_review_comment    │
│    body, commit.message)                                     │
│  ─ Attachment metadata (filename / mime / size; no content)  │
│  ─ Phase 4.8 PR metadata: files_count, +/- lines,            │
│    requested_reviewers, mention_count, link_count            │
│  ─ Claude Code hook completeness review (no expansion to     │
│    other AI tools)                                           │
│  ─ Layer A + Layer B baseline (already shipped Phase 1-4.10) │
└──────────────────────────────────────────────────────────────┘
```

The 12 existing low-level MCP tools (`get_timeline`, `find_last_activity`, `get_current_session`, `get_ai_activity`, `get_linear_activity`, `get_github_activity`, `get_slack_activity`, `get_uninterrupted_window`, `get_current_presence`, `get_workload_pulse`, `get_review_activity`, `get_cross_provider_thread`) **remain** as debug / power-user surface. The 3 new high-level structured tools sit on top of the same layers.

---

## 4. Sub-phase decomposition

```
   ┌───────────────────────────────────┐
   │  D1 — Capture extension           │   foundation, sequential
   │  bodies + attachments + Phase 4.8 │
   │  + Claude Code hook review        │
   └────────────┬──────────────────────┘
                ▼
   ┌───────────────────────────────────┐
   │  D2 — Index + link graph          │   sequential after D1
   │  FTS5 over bodies +               │
   │  CrossSourceLinkGraph             │
   └────────────┬──────────────────────┘
                ▼
   ┌───────────────────────────────────┐
   │  D3 — Detectors + structured MCP  │   sequential after D2
   │  Decision / OpenQuestion /        │
   │  Blocker / WhereStopped /         │
   │  AbsenceFlag + 3 new MCP tools    │
   └───────────────────────────────────┘
```

| Sub-phase | Sequential dep |
|---|---|
| **D1** Capture extension | none (foundation) |
| **D2** FTS5 + link graph | D1 (needs bodies + Phase 4.8 metadata) |
| **D3** Detectors + structured MCP | D2 (detectors use FTS for topic context, link graph for absence flag) |

D2 and D3 are sequential because D3's `AbsenceDetector` and topic-matching for `leaf_query_activity` reuse FTS results from D2. If a future spec finds D2 / D3 can run in parallel — fine, amend this contract.

Each sub-phase = its own brainstorm-session per `conventions.md` 8-stage workflow → its own spec → its own implementation plan → its own feature branch.

**Sub-phase naming convention:** `D1` / `D2` / `D3` (Track 1 sub-phases). Spec filename: `docs/superpowers/specs/YYYY-MM-DD-track-1-DN-<topic>.md`.

---

## 5. Schema changes — overview

Sub-phase specs own exact migration content; this is the cross-phase shape.

### 5.1 New tables

| Table | Owner phase | Purpose |
|---|---|---|
| `events_fts` | D2 | SQLite FTS5 virtual table over `events.payload.body` (and `commit.message`, `linear.description`, etc.). Tokenizer `unicode61` + `remove_diacritics 2` for ru/en mix |
| `event_links` | D2 | `(from_event_id, to_event_id, link_kind TEXT, confidence REAL)` — cross-source association graph (Linear ID, branch name, file path, Slack thread → PR refs) |
| `decisions` | D3 | `(id PK, event_id, topic_keywords JSON, reasoning_excerpt TEXT, confidence REAL, detected_at INTEGER)` — flagged decision events with reasoning extracted from bodies |
| `open_questions` | D3 | `(id PK, event_id, question_excerpt TEXT, alternatives_json JSON, resolved_by_event_id NULLABLE, opened_at, resolved_at NULLABLE)` |
| `blockers` | D3 | `(id PK, target_kind TEXT, target_id TEXT, started_at, blocker_excerpt TEXT, resolved_at NULLABLE)` — Linear-stuck + Slack-blocked-on signals |

### 5.2 Extended existing tables (D1)

| Table | Change | Owner phase |
|---|---|---|
| `events.payload` | Add JSON fields: `body`, `attachments[]` (filename / mime / size only) | D1 |
| `events.payload` (GitHub PR events) | Add `files_count`, `additions`, `deletions`, `requested_reviewers[]`, `mention_count`, `link_count` (Phase 4.8 carry-over) | D1 |
| `where_stopped_log` (NEW) | New table `(id PK, generated_at_ms, anchor_event_id NULLABLE → events, excerpt TEXT, wip_signals_json JSON)`. Replaces planned `sessions` extension — `sessions` table not present in substrate (Derived Insights Engine computes sessions on-the-fly); D3 introduces dedicated log to keep scope minimal. | D3 |

> **Amendment 2026-05-09 (D3 spec):** §5.2 `sessions` extension replaced with dedicated `where_stopped_log` table. Reason: substrate does not have a `sessions` table — Derived Insights Engine computes sessions on-the-fly. Creating the table only for `WhereStopped` output would be scope creep. Living-doc process per §14.

### 5.3 New ShareEventTypeKey entries (registered for future Track 2)

D3 registers keys for new derived event flavours: `decision_detected`, `open_question_opened`, `open_question_resolved`, `blocker_started`, `blocker_resolved`. Default OFF in Share Controls registry — they expose semantic facts, must be opt-in. Track 2 wires them into the relay; Track 1 only registers them so future Track 2 doesn't migrate the registry.

---

## 6. Privacy model — refined

Track 1 **explicitly relaxes** the prior `won't-list` ban on bodies, **but only on-device**. The boundary becomes:

| Surface | Bodies in plaintext? |
|---|---|
| `events.sqlite` (SQLCipher, on-device) | ✅ Yes — bodies stored encrypted-at-rest, decrypted only by Agent / MCPServer / MenuBarApp processes |
| `events_fts` (on-device) | ✅ Yes (FTS index derived from bodies, lives in same SQLCipher file) |
| MCP server response over stdio (on-device) | ✅ Yes — body excerpts go to the AI client process running on the same Mac |
| **Team relay** (Cloudflare DO / Supabase) | ❌ **Never.** Track 1 doesn't write to relay. Track 2 will, but only filtered structured payloads — never raw bodies. |
| Crash logs / error reports | ❌ Never. Bodies must be stripped from any diagnostic that leaves the device. |

**ADR-010 amendment.** Won't-list moves from "bodies forbidden everywhere" to "bodies forbidden in any data egress beyond the user's own AI client running on the same device; on-device storage and same-device MCP delivery are allowed for the Detection Substrate." Whitepaper sync required when Track 1 ships (sync target: `leaf-docs/docs/privacy-security/what-we-dont-capture.md` + `leaf-docs/docs/memory-architecture/storage.md`).

**What stays forbidden, even on-device:**
- File contents (the file's body itself)
- Screen captures, OCR, keystrokes
- AI prompt / response content (still no — see ADR-010 AI collaboration)

---

## 7. Capture extension scope (D1 contract)

D1 spec must cover all of these. Anything dropped from D1 is dropped permanently from Track 1, not deferred.

### 7.1 Layer B body fields

| Provider | Field | Source query |
|---|---|---|
| Linear | `issue.description` | Add to `LeafPoll` GraphQL fragment |
| Linear | `comment.body` | Existing nested-comments fragment + body field |
| Slack | `message.text` | `conversations.history` already returns; was previously dropped — keep |
| Slack | `thread_replies` (parent + N replies bodies) | New per-thread `conversations.replies` fan-out (bounded — sub-phase decides budget) |
| GitHub | `pull_request.body` | Existing PushEvent / PR fetch |
| GitHub | `issue_comment.body` | Existing event |
| GitHub | `pr_review_comment.body` | Phase 4.7.A event_kind |
| GitHub | `commit.message` | Already captured (Phase 1) |

### 7.2 Attachment metadata

Linear attachments, Slack file uploads, GitHub PR-attached files: capture `filename`, `mime`, `size_bytes`. **Not** content. Enables UC4-shaped responses ("Саша приложил `design.fig` к thread'у").

### 7.3 GitHub PR metadata expansion (Phase 4.8 carry-over)

Phase 4.8 was previously carved out and not designed; D1 absorbs it. Capture per PR / per push event:

- `files_count`, `additions`, `deletions` (PR-level totals)
- `requested_reviewers[]` (login + assignment timestamp)
- `mention_count` (`@user` mentions parsed from body)
- `link_count` (URLs in body — used by `CrossSourceLinkGraph` and `AbsenceDetector`)
- Expression index on `payload.event_kind` for fast filter in D3 query path

### 7.4 Claude Code hook completeness review

Already shipped: `PostToolUse`, `SessionStart`, `SessionEnd`, `UserPromptSubmit` + jsonl fallback. D1 verifies:
- All four hooks emit events with consistent shape across hook types
- jsonl fallback parser still aligns with current Claude Code session-file schema
- AI tool / file attribution is present on every event (otherwise AI activity rolls up wrong)

**Out of scope for Track 1:** Cursor v1.7+ hooks, Windsurf Cascade, Continue.dev jsonl, Copilot org-aggregate, ChatGPT Desktop. Those are deferred to a future track.

---

## 8. FTS5 keyword index + cross-source link graph (D2 contract)

### 8.1 FTS5

Single FTS5 virtual table `events_fts(event_id UNINDEXED, body, body_kind)`:
- `body` — concatenated text from `events.payload.body` + child fields (commit message, Linear description, comment bodies, Slack message + thread replies, PR body)
- `body_kind` — provenance tag (`commit_msg` / `linear_desc` / `linear_comment` / `slack_msg` / `slack_thread_reply` / `gh_pr` / `gh_issue_comment` / `gh_pr_review_comment`) for boost / filter at query time
- Tokenizer `unicode61` with `remove_diacritics 2` and `tokenchars '_-'` for code identifiers
- BM25 ranking; Swift wrapper exposes `topicSearch(query: String, period: DateInterval, limit: Int) -> [EventID]`
- Maintained on event write — no async queue, FTS5 inserts are cheap

### 8.2 CrossSourceLinkGraph

`event_links(from_event_id, to_event_id, link_kind TEXT, confidence REAL)`. Extension of `LinearIDExtractor`:
- Linear ID regex (existing) — boosted to graph row instead of just metadata
- Branch name parsing (`feature/LEAF-127-foo`) → links commit events to Linear
- File-path matching (commits and AX-window events sharing a path) → links across capture sources
- Slack-thread → PR linking (PR URL or `#PR-NNN` references in message body)
- GitHub `requested_reviewers` → Slack-thread participant matching (heuristic — used by `AbsenceDetector`)

Populated on every event write. Confidence is a constant per `link_kind` in v0; tunable in v1.

---

## 9. Semantic detectors + structured MCP tools (D3 contract)

### 9.1 Detectors

Each detector is a separate Swift type implementing a common protocol; runs on capture-write or on-batch (per-detector decision in D3 spec).

| Detector | Trigger | Output table | v0 strategy |
|---|---|---|---|
| `DecisionDetector` | On Slack `message.text` write, Linear `issue.description` / `comment.body` write, GitHub `pr.body` / `issue_comment.body` write | `decisions` | Pattern matcher (regex + keyword list — "решено" / "decided" / "let's go with" / "agreed" / "выбираем X вместо Y" / etc.; exact list in `LeafCorePrivate`) |
| `OpenQuestionDetector` | Same triggers as `DecisionDetector` | `open_questions` | Pattern: question marks + alternative connectors ("or" / "или" / "vs" / "should we") + no resolution event in 48 h → mark unresolved. Resolution detected when subsequent message in same thread / linked entity is flagged by `DecisionDetector` |
| `BlockerDetector` | Linear status-change events + Slack message bodies | `blockers` | Linear: issue without status change > N days = stuck (N in `LeafCorePrivate`). Slack: pattern "blocked on" / "stuck on" / "заблокирован" / "I need help with" in own messages |
| `WhereStoppedDeriver` | End-of-day batch (idle > 30 min after work hours) | `sessions.where_stopped_excerpt` | Last 3 events of day + WIP signals (commit message starts `wip:` / failing CI / mid-AX-window-edit at idle) → 1-line excerpt |
| `AbsenceFlag` | Computed on-the-fly inside `leaf_query_activity` when scoped to a PR | composed flag in response | Given a PR + linked Slack thread (`event_links`) + reviewer set (`requested_reviewers` from D1 §7.3), detect "design choice surfaced in thread but no reply from designated reviewer" → flag in JSON. No table — pure derivation |

All detectors are pattern-based — **no LLM call anywhere** in Track 1. Pattern lists live in `LeafCorePrivate` as moat.

### 9.2 Structured MCP tools

Three new tools in MCP server, returning structured JSON. AI client formulates narrative.

| Tool | Inputs | Output |
|---|---|---|
| `leaf_query_activity` | `period` (date range / preset), `filter` (topic — passed to FTS5) | Structured JSON: `{period, filter, events[], decisions_in_period[], open_questions[], links[], absence_flags[]}` |
| `leaf_get_decision` | `topic`, optional `period` | Structured JSON: `{decision: {ts, initiator, reasoning_excerpt, links_to_implementation[]}, related_events[]}` — read from `decisions` + composed via `event_links` |
| `leaf_current_work` | (no params) | Structured JSON: `{current_app, current_branch, current_file, in_progress_linear_ticket, last_commit, current_open_questions[], current_blockers[]}` |

The 12 existing low-level tools coexist (debug / power use). All 15 tools route through the same Query Engine.

### 9.3 Result-set budget

Structured payload size budget: **≤ 200 events** OR **≤ 64 KB JSON** per response, whichever hits first. If truncated, response includes a `truncation_note` field and the AI client can refine the query.

---

## 10. Open questions deferred to sub-phase specs

Each item must be answered in the named sub-phase spec; not gated on this contract.

| # | Question | Resolved in |
|---|---|---|
| OQ-1 | Exact body-storage encoding (UTF-8 plaintext vs JSON-escaped) and column type (`TEXT` vs `BLOB`) | D1 |
| OQ-2 | Slack `conversations.replies` fan-out budget (max threads / max replies per tick) under Slack rate limit | D1 |
| OQ-3 | FTS5 reindex strategy when bodies are added retroactively to existing events | D2 |
| OQ-4 | `event_links` confidence values per `link_kind` | D2 |
| OQ-5 | Detector pattern library curation — language coverage (en + ru), false-positive rate target | D3 |
| OQ-6 | `BlockerDetector` Linear stuck-threshold value (N days) — empirically tuned, kept private | D3 |
| OQ-7 | `WhereStoppedDeriver` idle-trigger threshold for end-of-day batch | D3 |
| OQ-8 | Structured-payload schema version field — how breaking changes propagate to AI clients consuming via MCP | D3 |
| OQ-9 | `AbsenceFlag` reviewer-Slack-participant matching heuristic (login → display-name fuzz) | D3 |

---

## 11. Out of scope (deferred to later tracks)

- **LLM Summarizer protocol** + Apple FM / Ollama / BYOK Anthropic / BYOK OpenAI — Track 1 returns structured JSON; AI client narrates. Summarizer is a future track if/when non-LLM-equipped surfaces (Slack-bot, Native UI prose mode) need it.
- **Embedding index + semantic vector search** — FTS5 keyword search is the Track 1 substrate. Vectors are a future upgrade if FTS5 proves insufficient.
- **AST symbol extraction from FSEvents** — file events carry path only; symbol-level capture is a future track.
- **AI-tool diversity beyond Claude Code** — Cursor v1.7+ hooks, Windsurf Cascade, Continue.dev jsonl, Copilot org-aggregate, ChatGPT Desktop "Work with Apps" — future track.
- **Calendar deepening** — `meeting_title`, `attendees[]` — future track. Track 1 keeps existing `in_meeting` boolean only.
- **`leaf_query_team` MCP tool** + cross-device E2E summary distribution → Track 2.
- **Slack-bot surface** (`/leaf` slash command for UC6 in a Slack channel) → Track 2.
- **Native UI redesign** to surface decisions / open questions / blockers as first-class panels → post-Track-1, decided after dogfooding D3.
- **Layer C connectors** (Notion, Figma, Jira, Gmail) → V1.5+ as in current `architecture.md`.

---

## 12. Whitepaper sync expectations

When Track 1 ships, sync these public-facing edits:

| File | Change |
|---|---|
| `leaf-docs/docs/memory-architecture/capture.md` | Update won't-list (bodies now stored on-device for Linear/GitHub/Slack); add Phase 4.8 PR metadata fields |
| `leaf-docs/docs/memory-architecture/storage.md` | Add new tables (decisions, open_questions, blockers, event_links, events_fts); document body-encryption-at-rest |
| `leaf-docs/docs/privacy-security/what-we-dont-capture.md` | Refine bodies stance per §6 above |
| `leaf-docs/docs/reference/mcp-tools.md` | Document the 3 new structured tools alongside existing 12 |
| `leaf-docs/docs/reference/changelog.md` | Patch entry per `leaf-docs/CLAUDE.md` rules |
| `leaf-docs/docs/memory-architecture/summarization.md` | Add note that Track 1 returns structured JSON; LLM Summarizer is a future track |

Implementation moat (exact decision-keyword list, blocker thresholds, body-encoding internals, exact rate-limit budgets) stays in `LeafCorePrivate`, not whitepaper.

---

## 13. Track 1 acceptance gate

Track 1 is **shipped** when:

1. UC1, UC3, UC4, UC5, UC6 work end-to-end on a fresh-install Mac with seeded data (integration test fixture).
2. All 3 sub-phase specs (D1, D2, D3) merged to `main` with their feature branches.
3. SPM test suite passes; xcodebuild on all 5 schemes is green.
4. Manual smoke on user's own working data — each of UC1, UC3, UC4, UC5, UC6 returns a coherent structured JSON response in Claude Code via MCP, and Claude Code formulates a sensible narrative from it within 3 s end-to-end.
5. Whitepaper sync (§12) merged to `leaf-docs/main`.
6. `current-state.md` in shared memory updated to reflect Track 1 shipped.

UC2 and UC7 are **not** in the Track 1 acceptance gate — they belong to Track 2.

---

## 14. Living document — amendment process

Anything in this contract can change as Track 1 progresses. Process:

1. Author proposes edit (PR to this file).
2. Edit ships before any sub-phase spec relying on the new shape lands.
3. Sub-phase specs already merged stay valid for their phase as written; new dependencies on the amendment go through future sub-phases.

When all of D1–D3 ship, this contract is marked **`Status: Active → Closed`** and Track 2 starts its own contract.
