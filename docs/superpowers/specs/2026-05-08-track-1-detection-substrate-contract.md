# Track 1 — Detection Substrate Contract

**Status:** Draft (2026-05-08). Promoted to "Active" after first sub-phase (D1) spec is reviewed against it.
**Owners:** Authors of D1–D4 sub-phase specs (current authors visible in `feature/track-1-*` branch graph).
**Audience:** Anyone writing a spec for sub-phase D1 / D2 / D3 / D4 of Track 1, or Track 2 (team distribution) once Track 1 ships.

---

## 1. Purpose & status

This document is a **reference contract**, not an implementation plan. Track 1 ("solo detection substrate") decomposes into 4 sub-phases (D1, D2, D3, D4); each owns its own design + plan; this contract fixes the constants between them so a choice in one sub-phase does not surprise another.

Whitepaper (`leaf-docs`, v0.1-beta) remains source of truth for public-facing product decisions. This contract supplements with engineering specifics that don't belong on the public site. Implementation moat (precise patterns, exact thresholds, body-encoding internals, prompt strings) lives in `LeafCorePrivate`, not here.

This is a **living document.** Amendments over Track 1 lifetime are expected.

---

## 2. Goal — fitness function

Track 1 is **done** when the following 7 use cases work end-to-end on a solo user (one Mac, no team), executed via MCP from Cursor / Claude Code / Claude Desktop, returning a markdown response within < 3 s:

| # | User question (in MCP client) | Expected response shape |
|---|---|---|
| **UC1** | "что я делал в пятницу по auth?" | Timeline: commits in `src/auth/` for LEAF-127, last commit message + CI status, Slack discussion in `#leaf-architecture` with body excerpt + open-question flag |
| **UC2** | "что Антон делал сегодня?" *(Track 2 — deferred)* | Same shape, scoped via Share Controls. **Track 1 contract: solo path must work; team path becomes Track 2.** |
| **UC3** | "что менялось в `/payments` за 2 недели?" | Path-history timeline + Linear ticket descriptions for each commit + flag of called-out concerns from issue body |
| **UC4** | "почему мы вынесли OAuth refresh на сервер?" | Decision record: timestamp, initiator, reasoning excerpts from Linear description + Slack thread, links to implementation commits |
| **UC5** | "что мне знать до ревью PR #142?" | PR + commits + linked Linear ticket + relevant Slack thread bodies + absence flag ("design choice X was not discussed with you") |
| **UC6** | "что мы решили по бэкапам и почему?" | Decision record (same as UC4) — surfaced via MCP. Slack-bot surface (channel `/leaf` command) is **out of Track 1 scope** — it shares the same Query Engine but is a separate surface. |
| **UC7** | "team weekly summary" *(Track 2 — deferred)* | Per-member composite + open questions + blockers. Track 1 contract: solo per-day / per-week summary works; team aggregation becomes Track 2. |

**Solo-path subset for Track 1 acceptance:** UC1, UC3, UC4, UC5, UC6 must pass on a single user's data. UC2 / UC7 remain in scope of Track 2 and are not gated by Track 1 acceptance.

Each sub-phase spec must list which use cases it unblocks and write integration tests against that mapping.

---

## 3. Three-layer architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Surface (existing)                                          │
│  MCP server · Native UI · CLI · (Slack bot, Track 2)         │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  Layer 3 — Compose + LLM     (D4, NEW)                       │
│  ─ Summarizer protocol (Apple FM / Ollama / Anthropic /      │
│    OpenAI BYOK)                                              │
│  ─ 3 high-level MCP tools:                                   │
│      leaf_query_activity / leaf_get_decision /               │
│      leaf_current_work                                       │
│  ─ Context-window pre-filter, system-prompt assembly,        │
│    summarization-cache lookup                                │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  Layer 2 — Derive            (D2 + D3, NEW)                  │
│  ─ Embedding index (D2)        — topic search                │
│  ─ Decision detector (D3)      — fact: "this is a decision"  │
│  ─ Open-question detector (D3) — fact: "unresolved dilemma"  │
│  ─ Blocker detector (D3)       — fact: "stuck N days"        │
│  ─ Where-stopped deriver (D3)  — last-WIP signal per session │
│  ─ Cross-source link graph (D3) — extension of LinearID rgx  │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  Layer 1 — Capture           (D1, EXTEND existing)           │
│  ─ Bodies: Linear (issue.description, comment.body),         │
│    Slack (message.text), GitHub (pr.body, issue_comment.body,│
│    pr_review_comment.body)                                   │
│  ─ Attachment metadata (filename / mime / size; no content)  │
│  ─ AST symbols on FSEvents writes (function names, class     │
│    names — via SourceKit / lightweight parser)               │
│  ─ AI-tool diversity: Cursor v1.7+ hooks, Windsurf Cascade,  │
│    Continue.dev jsonl                                        │
│  ─ Calendar attendees + title (relaxed privacy, see §6)      │
│  ─ Layer A + Layer B baseline (already shipped Phase 1-4.10) │
└──────────────────────────────────────────────────────────────┘
```

The 12 existing low-level MCP tools (`get_timeline`, `find_last_activity`, `get_current_session`, `get_ai_activity`, `get_linear_activity`, `get_github_activity`, `get_slack_activity`, `get_uninterrupted_window`, `get_current_presence`, `get_workload_pulse`, `get_review_activity`, `get_cross_provider_thread`) **remain** and become debug / power-user surface. The 3 new high-level tools sit on top of the same Derive + Capture layers.

---

## 4. Sub-phase decomposition

```
                ┌───────────────────────────────┐
                │  D1 — Capture extension       │   foundation, sequential
                │  bodies, attachments, AST,    │
                │  AI-tool diversity, calendar  │
                └─────────┬─────────────────────┘
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
    ┌──────────────────┐     ┌─────────────────────┐
    │  D2 — Embedding  │     │  D3 — Semantic      │
    │  index           │     │  detectors          │   parallel after D1
    │  ─ on-write      │     │  decision / openQ / │
    │  ─ topic search  │     │  blocker / where-   │
    │                  │     │  stopped / link     │
    └─────────┬────────┘     └──────────┬──────────┘
              │                         │
              └───────────┬─────────────┘
                          ▼
            ┌─────────────────────────────┐
            │  D4 — Compose + LLM         │   sequential, after D2 + D3
            │  Summarizer + 3 high-level  │
            │  MCP tools                  │
            └─────────────────────────────┘
```

| Sub-phase | Sequential dep | Parallel-OK with |
|---|---|---|
| **D1** Capture extension | none (foundation) | — |
| **D2** Embedding index | D1 (needs bodies to embed) | D3 |
| **D3** Semantic detectors | D1 (needs bodies to detect) | D2 |
| **D4** Compose + LLM | D2 + D3 (needs both topic search and detector outputs) | — |

Each sub-phase = its own brainstorm-session per `conventions.md` 8-stage workflow → its own spec → its own implementation plan → its own feature branch.

**Sub-phase naming convention:** `D1` / `D2` / `D3` / `D4` (Track 1 sub-phases). Spec filename: `docs/superpowers/specs/YYYY-MM-DD-track-1-DN-<topic>.md`.

---

## 5. Schema changes — overview

Sub-phase specs own exact migration content; this is the cross-phase shape.

### 5.1 New tables (D2 + D3)

| Table | Owner phase | Purpose |
|---|---|---|
| `event_embeddings` | D2 | `(event_id PK, vector BLOB, model_version TEXT, indexed_at INTEGER)` — 384-dim vector per event for topic search |
| `decisions` | D3 | `(id PK, event_id, topic_keywords JSON, reasoning_excerpt TEXT, confidence REAL, detected_at INTEGER)` — flagged decision events with reasoning extracted from bodies |
| `open_questions` | D3 | `(id PK, event_id, question_excerpt TEXT, alternatives_json JSON, resolved_by_event_id NULLABLE, opened_at, resolved_at NULLABLE)` |
| `blockers` | D3 | `(id PK, target_kind TEXT, target_id TEXT, started_at, blocker_excerpt TEXT, resolved_at NULLABLE)` — Linear-issue-stuck OR Slack-blocked-on signal |
| `event_links` | D3 | `(from_event_id, to_event_id, link_kind TEXT, confidence REAL)` — cross-source association graph (Linear ID, branch name, file path, Slack thread → PR) |
| `summarization_cache` | D4 | `(query_hash PK, response_markdown TEXT, model_version, ttl_at)` — TTL 1h |

### 5.2 Extended existing tables (D1)

| Table | Change | Owner phase |
|---|---|---|
| `events.payload` | Add JSON fields: `body`, `attachments` (filename / mime / size only), `ast_symbols` (file events only) | D1 |
| `sessions` | Add `wip_signals JSON`, `where_stopped_excerpt TEXT NULLABLE` | D3 |
| `ai_events` | Extend AI-tool source enum to include Cursor / Windsurf / Continue.dev | D1 |

### 5.3 New ShareEventTypeKey entries

D3 adds keys for new derived event flavours: `decision_detected`, `open_question_opened`, `open_question_resolved`, `blocker_started`, `blocker_resolved`. All default OFF in Share Controls registry — they expose semantic facts, must be opt-in per current Share Controls model.

---

## 6. Privacy model — refined

Track 1 **explicitly relaxes** the prior `won't-list` ban on bodies, **but only on-device**. The boundary becomes:

| Surface | Bodies in plaintext? |
|---|---|
| `events.sqlite` (SQLCipher, on-device) | ✅ Yes — bodies stored encrypted-at-rest, decrypted only by Agent / MCPServer / MenuBarApp processes |
| `event_embeddings` (on-device) | ✅ Yes (vectors derived from bodies) |
| `summarization_cache` (on-device) | ✅ Yes (cached LLM responses can include body excerpts) |
| Apple FM / Ollama (on-device LLM) | ✅ Yes — body bytes pass through model, never leave device |
| BYOK Anthropic / OpenAI (user-owned cloud LLM) | ⚠️ Bodies cross to user's own cloud account — disclosed via Settings copy ("when BYOK is selected, body excerpts are sent to your selected provider") |
| **Team relay** (Cloudflare DO / Supabase) | ❌ **Never.** Only LLM-summarized output, E2E encrypted, filtered through Share Controls. Track 2 enforces this. |
| Crash logs / error reports | ❌ Never. Bodies must be stripped from any diagnostic that leaves the device. |

**ADR-010 amendment.** Won't-list moves from "bodies forbidden everywhere" to "bodies forbidden in any data egress beyond the user's chosen LLM provider; on-device storage is allowed for the Detection Substrate." Whitepaper sync is required when Track 1 ships (sync target: `leaf-docs/docs/privacy-security/what-we-dont-capture.md` + `leaf-docs/docs/memory-architecture/storage.md`).

**What stays forbidden, even on-device:**
- File contents (the file's body itself — only AST symbols / metadata)
- Screen captures, OCR, keystrokes
- AI prompt / response content (still no — see ADR-010 AI collaboration)

---

## 7. Capture extension scope (D1 contract)

D1 spec must cover all of these. Anything dropped from D1 is dropped permanently from Track 1, not deferred — Track 1 acceptance depends on UC1–UC6 working, which require this full set.

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

Linear attachments, Slack file uploads, GitHub PR-attached files: capture `filename`, `mime`, `size_bytes`. **Not** content. Attachment metadata enables UC4-shaped responses ("Антон приложил `design.fig` к thread'у").

### 7.3 AST symbols on FSEvents

When FSEvents fires for a watched file with extension matching a known language (Swift, TS / JS, Python, Go, Rust, …), parse the file (best-effort, lightweight — SourceKit for Swift, tree-sitter or regex fallbacks elsewhere) and extract top-level symbols (function names, class names, type names) into `events.payload.ast_symbols`. Failure to parse is non-fatal — write event without symbols.

### 7.4 AI-tool diversity

Adds capture for additional AI clients beyond Claude Code:

- **Cursor Hooks v1.7+** — `beforeSubmitPrompt` / `afterFileEdit` / `postToolUse` / `stop` (metadata only — prompt / response content forbidden, see ADR-010)
- **Windsurf Cascade Hooks** — `.windsurf/hooks.json`
- **Continue.dev** — `.continue/dev_data/*.jsonl` via FSEvents

GitHub Copilot (org-aggregate via REST `/copilot/usage` — no per-event API) and ChatGPT Desktop ("Work with Apps" one-way) remain "surface forever" — handled by AX window-title fallback, no first-class capture.

### 7.5 Calendar relaxation

EventKit was previously limited to `in_meeting` boolean. D1 expands to `meeting_title` + `attendees[].name` + `attendees[].email`, gated by an explicit Settings opt-in ("share my calendar event titles and attendees with my Leaf — used to detect meeting context, never shared with team relay").

### 7.6 GitHub PR metadata expansion (Phase 4.8 carry-over)

Phase 4.8 was previously carved out and not designed; D1 absorbs it. Capture per PR / per push event:

- `files_count`, `additions`, `deletions` (PR-level totals)
- `requested_reviewers[]` (login + assignment timestamp)
- `mention_count` (`@user` mentions parsed from body)
- `link_count` (URLs in body — used by `CrossSourceLinkGraph` and `AbsenceDetector`)
- Expression index on `payload.event_kind` for fast filter in D4 composer

---

## 8. Embedding pipeline (D2 contract)

D2 spec owns implementation; this fixes cross-phase invariants.

| Decision | Value | Reason |
|---|---|---|
| Vector dim | 384 | Compatible with both Apple FM embedding API and `bge-small-en-v1.5` Ollama model |
| Storage | `event_embeddings` BLOB column (1536 bytes per vector, fp32) | Simpler than separate vector DB; SQLite VSS extension OR in-memory KNN on startup is fine for < 100 k events |
| Backend default | `AppleFoundationEmbedder` (macOS 26+) | On-device, free, fast |
| Backend fallback | `OllamaEmbedder` with `bge-small-en-v1.5` | macOS 14–25, or explicit user choice |
| Write rate | Per-event on capture path, async queue | ~30 ms per event on M-series → not in hot path |
| Re-index trigger | `model_version` column mismatch on read | If user switches backend, re-index lazily |
| Search API | `topic_search(query: String, period: DateInterval, top_k: Int) -> [EventID]` | Used by D4 composer + Native UI search |

`Embedder` protocol mirrors `Summarizer` protocol (D4) — pluggable backends behind a single interface. Both protocols live in `LeafCore/LLM/`.

---

## 9. Semantic detectors (D3 contract)

Each detector is a separate Swift type implementing a common protocol; runs on capture-write or on-batch (per-detector decision in D3 spec).

| Detector | Trigger | Output table | v0 strategy |
|---|---|---|---|
| `DecisionDetector` | On Slack `message.text` write, Linear `issue.description` / `comment.body` write, GitHub `pr.body` / `issue_comment.body` write | `decisions` | Pattern matcher (regex + keyword list — "решено" / "decided" / "let's go with" / "agreed" / "выбираем X вместо Y" / etc.; exact list in `LeafCorePrivate`). LLM classifier upgrade in v1. |
| `OpenQuestionDetector` | Same triggers as `DecisionDetector` | `open_questions` | Pattern: question marks + alternative connectors ("or" / "или" / "vs" / "should we") + no resolution event in 48 h → mark unresolved. Resolution detected when subsequent message in same thread / linked entity is flagged by `DecisionDetector`. |
| `BlockerDetector` | Linear status-change events + Slack message bodies | `blockers` | Linear: issue without status change > N days = stuck (N in `LeafCorePrivate`). Slack: pattern "blocked on" / "stuck on" / "заблокирован" / "I need help with" in own messages. |
| `WhereStoppedDeriver` | End-of-day batch (idle > 30 min after work hours) | `sessions.where_stopped_excerpt` | Last 3 events of day + WIP signals (commit message starts `wip:` / failing CI / mid-AX-window-edit at idle) → 1-line excerpt |
| `CrossSourceLinkGraph` | On every event write | `event_links` | Extension of `LinearIDExtractor`: + branch-name parsing (`feature/LEAF-127-foo`) + file-path matching (commits and AX-window events sharing a path) + Slack-thread → PR linking (PR URL or `#PR-NNN` references in message body) |
| `AbsenceDetector` | On D4 query for `leaf_query_activity` with PR-context filter (computed on-demand, not stored) | composed flag in response | Given a PR + linked Slack thread (`event_links`) + reviewer set (`requested_reviewers` from D1 §7.6), detect "design choice surfaced in thread but no reply from designated reviewer" → flag in markdown response. No table — pure derivation. |

All detector v0 strategies are pattern-based — no LLM call on capture path. Optional v1 upgrade path (D3 spec calls out which detectors get LLM classifier batch in v1) is allowed but not gating Track 1 acceptance.

---

## 10. Compose + LLM (D4 contract)

D4 is the user-facing payoff. Sub-phase spec covers prompt design, context budget, streaming.

### 10.1 Summarizer protocol

```swift
protocol Summarizer {
    func summarize(events: [Event], userQuery: String, systemPrompt: String) async throws -> String
    var capabilities: SummarizerCapabilities { get }
}

struct SummarizerCapabilities {
    let maxContextTokens: Int
    let supportsStreaming: Bool
    let estimatedLatencyMs: Int
    let costPerKToken: Double?  // nil for on-device
}
```

Implementations:

| Impl | Default? | Backend |
|---|---|---|
| `AppleFMSummarizer` | macOS 26+ | Apple Foundation Models |
| `OllamaSummarizer` | macOS 14-25 | Local Ollama (model user-selected) |
| `AnthropicBYOKSummarizer` | user opt-in | api.anthropic.com (user's key) |
| `OpenAIBYOKSummarizer` | user opt-in | api.openai.com (user's key) |
| `LeafCloudSummarizer` | future | Track 2+ |

### 10.2 New high-level MCP tools

| Tool | Inputs | Output |
|---|---|---|
| `leaf_query_activity` | `period` (date range / preset), `filter` (topic) | Markdown narrative; pipeline: topic-search → time-filter → composite timeline → pre-filter → Summarizer → markdown |
| `leaf_get_decision` | `topic`, optional `period` | Markdown decision record: when, who initiated, reasoning excerpt, links to implementation. Reads `decisions` table + composes via Summarizer |
| `leaf_current_work` | (no params) | Markdown: current app, current branch, current file, in-progress Linear ticket, last commit, last open question, current blocker if any |

The 12 existing low-level tools coexist (debug / power use). All 15 tools route through the same Query Engine (permission-aware in Track 2).

### 10.3 Pre-filter and context budget

Each tool's pipeline applies:
1. Topic + period filter via D2 search
2. Sort by `(relevance_score * recency_decay)` descending
3. Truncate to top-N events / M tokens (per `Summarizer.maxContextTokens` minus system-prompt + reserved-for-response budget)
4. If truncated, attach a footer note: `"Showed N of M events; refine query for more"`

### 10.4 Cache

`summarization_cache` keyed on `hash(query + event_ids + model_version + tier)`. TTL 1 h. Bypass on `?fresh=true` MCP arg.

---

## 11. Open questions deferred to sub-phase specs

Each item must be answered in the named sub-phase spec; not gated on this contract.

| # | Question | Resolved in |
|---|---|---|
| OQ-1 | Exact body-storage encoding (UTF-8 plaintext vs JSON-escaped) and column type (`TEXT` vs `BLOB`) | D1 |
| OQ-2 | Slack `conversations.replies` fan-out budget (max threads / max replies per tick) under Slack rate limit | D1 |
| OQ-3 | AST parser stack per language — SourceKit binding strategy, tree-sitter vendoring, fallback regex | D1 |
| OQ-4 | Embedding write-queue back-pressure when capture rate > embedding rate | D2 |
| OQ-5 | Embedding model version migration (re-index in background vs lazy on read) | D2 |
| OQ-6 | Detector pattern library curation — language coverage (en + ru), false-positive rate target | D3 |
| OQ-7 | `BlockerDetector` Linear stuck-threshold value (N days) — empirically tuned, kept private | D3 |
| OQ-8 | `WhereStoppedDeriver` idle-trigger threshold for end-of-day batch | D3 |
| OQ-9 | LLM context budget per provider — exact token reservations for system prompt + response headroom | D4 |
| OQ-10 | Streaming response handling for MCP — does protocol surface chunks, or buffer until done | D4 |
| OQ-11 | Settings UX for Summarizer-tier switching — single radio vs per-tool override | D4 |
| OQ-12 | BYOK key storage — Keychain item per provider, surface for revocation | D4 |
| OQ-13 | Calendar attendees field — dedup against `team_members` to mark intra-team meetings | D1 |

---

## 12. Out of scope (deferred to Track 2 or later)

- **`leaf_query_team` MCP tool** + cross-device E2E summary distribution → Track 2.
- **Slack-bot surface** (`/leaf` slash command in Slack channel for UC6) → Track 2.
- **Native UI redesign** to surface decisions / open questions / blockers as first-class panels → post-Track-1, decided after dogfooding D4.
- **`LeafCloudSummarizer`** — hosted-LLM tier → after Track 2 + Sec/Trust review.
- **Layer C connectors** (Notion, Figma, Jira, Gmail, Calendar deep) → V1.5+ as in current architecture.md.

---

## 13. Whitepaper sync expectations

When Track 1 ships, sync these public-facing edits:

| File | Change |
|---|---|
| `leaf-docs/docs/memory-architecture/capture.md` | Update won't-list (bodies now stored on-device); add AST symbols, attachment metadata |
| `leaf-docs/docs/memory-architecture/summarization.md` | Reflect 3 high-level tools as the primary surface |
| `leaf-docs/docs/memory-architecture/storage.md` | Add new tables (decisions, open_questions, blockers, event_links, event_embeddings, summarization_cache); document body-encryption-at-rest |
| `leaf-docs/docs/privacy-security/what-we-dont-capture.md` | Refine bodies stance per §6 above |
| `leaf-docs/docs/reference/mcp-tools.md` | Document the 3 new tools alongside existing 12 |
| `leaf-docs/docs/reference/changelog.md` | Patch entry per `leaf-docs/CLAUDE.md` rules |

Implementation moat (exact decision-keyword list, blocker thresholds, body-encoding internals, prompt strings, exact rate-limit budgets) stays in `LeafCorePrivate`, not whitepaper.

---

## 14. Track 1 acceptance gate

Track 1 is **shipped** when:

1. UC1, UC3, UC4, UC5, UC6 work end-to-end on a fresh-install Mac with seeded data (integration test fixture).
2. All 4 sub-phase specs (D1, D2, D3, D4) are merged to `main` with their feature branches.
3. SPM test suite passes; xcodebuild on all 5 schemes is green.
4. Manual smoke on user's own working data — each of UC1, UC3, UC4, UC5, UC6 returns a sensible markdown response in Cursor / Claude Code / Claude Desktop within 3 s.
5. Whitepaper sync (§13) merged to `leaf-docs/main`.
6. `current-state.md` in shared memory updated to reflect Track 1 shipped.

UC2 and UC7 are **not** in the Track 1 acceptance gate — they belong to Track 2.

---

## 15. Living document — amendment process

Anything in this contract can change as Track 1 progresses. Process:

1. Author proposes edit (PR to this file).
2. Edit ships before any sub-phase spec relying on the new shape lands.
3. Sub-phase specs already merged stay valid for their phase as written; new dependencies on the amendment go through future sub-phases.

When all of D1–D4 ship, this contract is marked **`Status: Active → Closed`** and Track 2 starts its own contract.
