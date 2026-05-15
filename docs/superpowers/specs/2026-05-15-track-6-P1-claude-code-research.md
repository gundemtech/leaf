# Track 6 P1 — Claude Code Deep · Stage 0 Research

**Stage:** Stage 0 (Deep Research) — companion to upcoming phase spec
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Date:** 2026-05-15
**Author:** Dmitrii + Claude (research subagents: Explore / claude-code-guide / general-purpose)

This doc is the **input to brainstorm (Stage 2)**, not a plan. It maps the realistic ceiling of Claude Code capture, surfaces the deltas between substrate and ceiling, and surfaces 4 product questions for the user to answer before brainstorm starts.

---

## 1. Current substrate (where we stand)

Source: `Packages/LeafCore/Sources/LeafCore/Collectors/ClaudeCodeCollector.swift`, `Packages/LeafCorePrivate/Prod/Collectors/ClaudeCodeJSONLParser.swift`, `Packages/LeafCore/Sources/LeafCore/Insights/AIActivityBreakdown.swift`, `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift`.

| Dimension | Current state |
|---|---|
| **Capture mechanism** | jsonl tail-read only on `~/.claude/projects/<slug>/*.jsonl`. **No live hooks installed.** Byte-offset persistence via `CollectorOffsets` table (inode tracking for truncate/rotate). |
| **event_kinds emitted** | **2 total:** `tool_use`, `user_prompt` (in `ClaudeCodeJSONLParser.swift:101,148`). |
| **Payload fields** | `tool_use`: `session_id, source_msg_uuid, cwd, git_branch, tool_name, file_path`. `user_prompt`: `session_id, source_msg_uuid, cwd, git_branch`. |
| **DB shape** | Single `events` table with `signalType=aiCollaboration`. **No separate `ai_events` table** (architecture doc line 103 is stale — says separate table; actual implementation is one table with discriminator). |
| **ShareEventTypeKey entries** | **0** for Claude Code. `tool_use` / `user_prompt` are NOT share-controllable today — they are filtered only by signal-type level, not per-event-kind. |
| **Aggregations** | `aiRatio(period:) → Double` and `aiActivityBreakdown(period:) → AIActivityBreakdown` already shipped (`DerivedInsights.swift:29,32`). Breakdown surfaces `ratio, aiActiveSeconds, totalActiveSeconds, sessionCount, topTools, topProjects`. Ratio = `minutes_with_ai / (minutes_with_ai + minutes_with_attention)`. |
| **TCC posture** | **None.** `~/.claude/projects/` is in user home, no TCC prompt. No `Accessibility` / `Automation` / `FullDiskAccess` involved. |
| **ActivityFeedMapper.mapAI** | `ActivityFeedMapper.swift:78–123`. Reads `tool_name, file_path, cwd` for `tool_use`; `cwd` only for `user_prompt`. Privacy-clean: no prompt body, no thinking, no tool_input/output read. |
| **Tests** | `ClaudeCodeCollectorTests.swift`, `ClaudeCodeJSONLParserTests.swift`, `ClaudeCodeCollectorCrossHookTests.swift`, `RelayBodyLeakageTests.swift`. |

**Architecture-doc drift to fix during P1 ship:** line 103 in `.claude/shared/architecture.md` says "ai_events — separate table"; reality is unified `events` table with `signalType=aiCollaboration`. Either rename the doc reference or accept the discrepancy explicitly.

---

## 2. Vendor ceiling — Claude Code hook + jsonl surface (2026)

Source: claude.com / code.claude.com docs, observed jsonl structure, Anthropic changelog.

### 2.1 Hook event registry (9 documented flavors)

| Hook | Triggers | Blocking? | Key payload fields |
|---|---|---|---|
| `SessionStart` | Session begins | Exit-2 blocks | `session_id, source` (startup\|resume\|clear\|compact), `model, cwd, transcript_path` |
| `SessionEnd` | Session ends | Informational | `session_id, reason` (clear\|resume\|logout\|prompt_input_exit\|...) |
| `UserPromptSubmit` | User submits prompt (pre-Claude) | Exit-2 blocks | `prompt, permission_mode, session_id` |
| `PreToolUse` | Before tool fires | Exit-2 / `permissionDecision: deny` blocks | `tool_name, tool_input, tool_use_id, permission_mode, effort.level, session_id` |
| `PostToolUse` | After tool succeeds | Informational | `tool_name, tool_input, tool_result, tool_use_id, duration_ms` (2.1.121+), `session_id` |
| `Stop` | Claude finishes turn / API error | Informational | `stopReason, session_id, turnNumber` |
| `SubagentStop` | Subagent done | Informational | `agent_type, agent_id, session_id` |
| `Notification` | Permission prompt / UI status | Informational | `notificationType, message` |
| `PreCompact` | `/compact` about to fire | Exit-2 blocks (2.1.105+) | `session_id, estimatedTokenCount, targetTokenCount, trigger` (manual\|auto) |

*Note:* the vendor-survey agent listed several speculative hooks (`PermissionRequest`, `PermissionDenied`, `FileChanged`, `CwdChanged`, `InstructionsLoaded`, `PostToolUseFailure`, `StopFailure`) — these are **not documented** in current canonical sources and are excluded from this ceiling. Treat as anti-pattern: don't bake speculative hooks into spec.

### 2.2 Tool name registry (`tool_name` in PreToolUse/PostToolUse)

Built-in: `Bash, Edit, Read, Write, Glob, Grep, WebFetch, WebSearch, NotebookEdit, Task, TodoWrite, SlashCommand, AskUserQuestion, Skill, Agent, KillBash, BashOutput, ListMcpResourcesTool, ReadMcpResourceTool, ToolSearch, NotebookRead`.

MCP: `mcp__<server>__<tool>` (e.g. `mcp__linear__list_issues`). Wildcard `mcp__*` matches all MCP tools from any server.

Subagent dispatch: uses `Agent` or `Task` tool; subagent type in `tool_input.subagent_type`.

### 2.3 Session metadata

Stable across hooks: `session_id, cwd, model, version, transcript_path, gitBranch` (if repo), `permission_mode` (plan\|auto\|acceptEdits\|bypassPermissions\|default), `source` enum (startup\|resume\|clear\|compact), `effort.level` (low\|medium\|high), `entrypoint` (cli\|vs-code\|jetbrains\|desktop\|web).

Env vars exposed to subprocesses (NOT in hook JSON but available in shell tool wrappers): `CLAUDE_CODE_SESSION_ID, CLAUDE_PROJECT_DIR, CLAUDE_EFFORT`.

### 2.4 jsonl transcript format

Location: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. Append-only, one event per line.

Entry types observed:
- `user-message` — `content, parentUuid, timestamp, sessionId, cwd, version, gitBranch, entrypoint, userType` (external\|agent), `isSidechain`
- `assistant-message` — `content, stopReason, model, tokens-used` (per-turn token count, **NOT in hook stream**)
- `tool-use` — `toolName, toolInput, toolUseID, timestamp`
- `tool-result` — `toolUseID, toolResult, isError, timestamp`
- `file-history-snapshot` — `messageId, snapshot.timestamp, snapshot.trackedFileBackups` (metadata only, not contents)
- `attachment` (hook_success) — captures hook stdout, exit_code, durationMs
- `attachment` (hook_additional_context) — content injected by SessionStart hooks
- `compact-marker` — `compactedAt, newSessionId` if resumed

**Critical asymmetry:** token usage per turn is in jsonl (`tokens-used` on `assistant-message`) but **NOT in the hook stream** as of 2026-05 (filed: Claude Code #11008, #11535). For token-attributed AI ratio we must parse jsonl, not rely on hooks.

### 2.5 Idle / waiting signals — NONE explicit

No `SessionIdle` hook, no `Thinking` hook. Must derive from gaps:
- `PreToolUse → PostToolUse` gap = tool wall-clock (now available as `duration_ms` field 2.1.121+).
- `PostToolUse → next PreToolUse` gap = either model thinking or human reading output.
- `UserPromptSubmit → first PreToolUse` gap = model first-token latency + thinking.
- No event for >60s = blocked / hung / user away.

`Notification` hook fires when permission prompt shown to user — proxy for "Claude is blocked waiting on me", but unreliable (also fires for benign UI updates).

---

## 3. OSS reconnaissance — what others do

Source: top-3 distillation from OSS recon subagent (full citations in subagent output).

### 3.1 Continue.dev — cleanest event taxonomy

**Schema dir:** `continuedev/continue/packages/config-yaml/src/schemas/data/`. Per-event Zod schemas with **`all` / `noCode` variants** — `noCode` strips prompts/completions/code, keeps tokens/timing/filepath/line-counts. Exact pattern Leaf needs.

Event types (v0.2.0): `autocomplete, quickEdit, chatFeedback, tokensGenerated, chatInteraction, editInteraction, editOutcome, nextEditOutcome, toolUsage`.

`editOutcome` is the most informative: `previousCode, newCode, previousCodeLines, newCodeLines, lineChange, filepath, accepted, modelName, provider`. `noCode` keeps line counts + filepath + model + accepted — strips code. **Direct analogue for our PostToolUse on Edit/Write/NotebookEdit + tool_input.file_path.**

Known bug: `editOutcome` silently not emitted in some builds (Continue #6795) — track per-event-kind cadence ourselves; surface "this kind stopped firing 7d ago" coverage signal.

### 3.2 vscode-wakatime — anti-pattern reference

LOC-heuristic AI detection: flips `isAICodeGenerating` on (a) URI scheme matches `vscode-chat-code-block`/`openai-codex`/contains `"claude"`, (b) single content change >50 chars OR >2 newlines, (c) lineCount delta >50 within 60s. **Broken in practice** (Cursor users misattributed as human — issue #476, open since 2025).

**Lesson:** structural detection without producer self-declare is unreliable. We have producer self-declare (Claude hooks + jsonl) — use it; don't bake LOC heuristics.

### 3.3 ActivityWatch — macOS TCC discipline

`aw-watcher-window` history: AX permission lost on every release pre-v0.12.0 because subprocess Python AX-prompted under wrong CDHash. Fix: codesign the bundle, AX-prompt from parent `.app`, subprocess delegation.

**Relevant for P1: NOT directly applicable.** Our Claude Code collector is TCC-free (passive file-read on `~/.claude/`). But the lesson "AX-prompt from parent bundle" still applies for Track 4 collectors — out of scope here.

### 3.4 Cursor / Cline / aider — quick reference

- **Cursor Hooks v1.7+**: `beforeSubmitPrompt, beforeShellExecution, beforeMCPExecution, beforeReadFile, afterFileEdit, stop`. Cleaner blocking story than Claude (per-event allow/deny response shape). Same conceptual shape — file path + edit count + bytes_delta. Defer to v1.1 AI-collab track (architecture line 67) but our P1 schema should be portable.
- **Cline / Roo**: stores per-task JSON with full prompts+responses under `~/Library/Application Support/Code/User/globalStorage/...`. Reading would violate ADR-010. Treat as "task started/stopped via FSEvents on parent dir + `task_metadata.json` mtime" — defer.
- **aider**: `~/.aider/analytics.jsonl` has token-cost per `message_send`, no per-file attribution. Auto-commits with `aider:` prefix — recoverable via git polling cross-link.

---

## 4. TCC / sandbox audit

| Mechanism | TCC prompt? | Hardened sandbox? | Locale variants? | Cross-user reliability |
|---|---|---|---|---|
| jsonl tail-read on `~/.claude/projects/` | **No** (user home, no TCC scope) | Works | N/A — jsonl is structural | Universal; works on every Mac with Claude Code installed |
| Live hooks via `~/.claude/settings.json` install | **No** (we write user's config file; user already trusted us with `~/Library/Application Support/Leaf/`) | Works | N/A | Universal; requires user's `claude` CLI to find our hook command path |
| Hook-invoked subprocess (Leaf-Agent IPC) | **No** (subprocess inherits parent's grants) | Subprocess inherits Hardened Runtime entitlements; need to verify subprocess doesn't trip `com.apple.security.cs.allow-jit` etc. | N/A | Requires Leaf.app installed at known path or `claude` binary in PATH |
| Reading `~/.claude/projects/*.jsonl` for token counts | **No** | Works | N/A | Same as current |

**Net:** P1 has **zero new TCC prompts.** Lowest-risk surface in Track 6 from a privacy-friction standpoint.

---

## 5. Ceiling-vs-effort table

Per Section 3.1 of the contract — every viable signal, mechanism, effort estimate, value tier.

### 5.1 Per-tool event_kinds (PostToolUse expansion)

Today: 1 generic `tool_use`. Vendor surface enables splitting by `tool_name`:

| Proposed event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `claude_bash_executed` | PostToolUse `tool_name=Bash` | S | **Critical** | Distinct from edit work; shell commands are coordination signal. Capture: `cwd`, `command_length_chars`, `exit_code`, `duration_ms`. **NEVER command string.** |
| `claude_file_edited` | PostToolUse `tool_name=Edit\|NotebookEdit` | S | **Critical** | Already partially captured. Add: `bytes_added` / `bytes_removed` (from old_string/new_string lengths), `is_new_file=false`. |
| `claude_file_written` | PostToolUse `tool_name=Write` | S | **Critical** | New-file write; distinct semantic. Capture: file_path, byte_count, `is_new_file=true`. |
| `claude_file_read` | PostToolUse `tool_name=Read` | S | **Strong** | Read-only signal; useful for "exploration ratio". Capture: file_path, line_range_count. |
| `claude_glob_executed` | PostToolUse `tool_name=Glob` | S | Marginal | Pattern shape only (`*.swift` etc.) — ambiguous moat. Skip unless trivial. |
| `claude_grep_executed` | PostToolUse `tool_name=Grep` | S | Marginal | Same as glob. Skip. |
| `claude_web_fetched` | PostToolUse `tool_name=WebFetch\|WebSearch` | S | **Strong** | Distinct mode signal (research vs code). Domain only via existing L4 allow-list pattern. |
| `claude_subagent_dispatched` | PostToolUse `tool_name=Task` + `SubagentStop` | M | **Strong** | Nested session; cross-link via parent session_id. Critical for understanding "I'm running parallel agents" pattern. |
| `claude_mcp_tool_invoked` | PostToolUse `tool_name=mcp__*` | S | **Strong** | Per-server bucket (e.g. `mcp__linear__*`, `mcp__figma__*`). Massive signal of cross-tool workflow. |
| `claude_slash_command_invoked` | PostToolUse `tool_name=SlashCommand` | S | **Strong** | Skill / command invocation; signals "I'm in workflow X". |
| `claude_todo_updated` | PostToolUse `tool_name=TodoWrite` | S | Marginal | Useful but coarse. Land if S effort. |

### 5.2 Session lifecycle event_kinds

| Proposed event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `claude_session_started` | SessionStart hook | S | **Critical** | Today inferred from first jsonl entry — direct signal richer (`source` enum tells startup vs resume vs compact). |
| `claude_session_ended` | SessionEnd hook | S | **Critical** | Today inferred. Direct signal: clean end vs `prompt_input_exit` vs logout. |
| `claude_session_compacted` | PreCompact hook | S | **Strong** | Signal of long-running session; context-pressure proxy. |
| `claude_prompt_submitted` | UserPromptSubmit hook | S | **Critical** | Today via jsonl. Add `prompt_length_chars` (NOT prompt content), `permission_mode` at time of submit, `effort_level`. |
| `claude_turn_ended` | Stop hook | S | **Strong** | Per-turn boundary; enables turn-duration histogram. `stopReason` enum. |
| `claude_notification_shown` | Notification hook | M | Marginal | Signal of "Claude waiting on me" — but unreliable (also fires for benign UI). Skip MVP. |

### 5.3 Timing / derived signals

| Proposed signal | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| Per-tool `duration_ms` | PostToolUse field (2.1.121+) | S | **Critical** | Wall-clock per tool. Enables latency histogram across Bash/Edit/WebFetch/Read. Distinct from "session active time". |
| `tokens_used_per_turn` | jsonl `assistant-message.tokens-used` | M | **Strong** | NOT in hooks. Requires jsonl parser extension. Enables token-attributed AI ratio. Capture: `prompt_tokens, completion_tokens, model`. **NO model output content.** |
| Idle-within-session derive | gap between PostToolUse events | M | **Strong** | New `aiSessionGaps(period:)` insight. Gap >60s = "thinking or away". Gap >5min = session boundary candidate. |
| AI-ratio refinement | augment existing `aiRatio` with per-tool weights | M | **Strong** | Today: minutes-with-AI vs minutes-with-attention. Refine: weight `Edit`/`Write` heavier than `Read`/`Grep` (active vs passive). |
| Cross-link to Linear/GitHub | `LinearIDExtractor` already shipped (Track 3 D2) | M | Marginal | Run extractor on `cwd` path + `git_branch` name. Defer to Phase 4.9. |

### 5.4 What we DON'T capture (Won't-list confirmation)

- **Prompt body, response body, thinking blocks** — permanently forbidden (ADR-010 / whitepaper Won't-list).
- **`tool_input` / `tool_result` content** beyond size/count.
- **Bash command strings, file contents, web-fetched body** — only sizes / domains.
- **Skill / command argument strings** — only command name.
- **MCP tool inputs / outputs** — only server name + tool name.
- **`Notification.message` text** — only fact that notification fired (and skipped MVP anyway).

`RelayBodyLeakageTests` extended to walk every new event_kind payload tree for sentinel strings.

---

## 6. Schema deltas

Recommended:

- **No new tables for P1.** All new signal lands as event_kind discriminators in `events.payload_json`. Architecture-doc drift on `ai_events` table reconciled by renaming the doc reference (events table with `signalType=aiCollaboration` is the actual storage).
- **ShareEventTypeKey registry:** **+~12 entries** (per §5.1, §5.2), all default OFF. Naming convention `claude_<verb>_<noun>` per Track-3/4 pattern. **Existing emit-without-share-key** for `tool_use` and `user_prompt` becomes mid-track migration: add their share-keys as default ON to preserve existing behavior (or default OFF + carry data-loss; user decision).
- **DispatchCoverageTests:** extend parity fence — `ActivityFeedMapper.mapAI` switch gains ~12 new cases.
- **Migration counter:** none consumed (P1 takes M024 reservation back — only schema delta needed is `claude_session_history` IF we want per-session rollup table; deferred unless brainstorm decides explicit table beats query-on-events).

---

## 7. Anti-patterns from prior tracks

Carry-overs from `.claude/shared/current-state.md` "Open tensions" + Track 3/4 reviews:

1. **Cold-start race** (Track 3 D3 Slack, Track 4 S4). Cold tick #1 emits before warm state established → fan-out skips. **Mitigation:** new event_kinds added with explicit cold-vs-warm tick branch; integration test simulating cold start.
2. **Dispatcher parity drift** (Track 4 S4 MAJOR-1 review reject). Payload keys in collector ≠ keys in `ActivityFeedMapper.mapAI` → display blank. **Mitigation:** canonical key names defined once (consider extending `Schema.BodyKinds`); `DispatchCoverageTests` fence per new event_kind.
3. **Sentinel-leak regression** (Track 4 S3). New payload tree must be walked end-to-end for forbidden fields. **Mitigation:** `RelayBodyLeakageTests` per-flavor + integration test sentinel-injection walking entire payload JSON for every new event_kind.
4. **Raw third-party IDs in payloads** (Track 4.7.C linear_assignee). Subagent dispatch surfaces subagent agent_id — is this safe to record? Investigate during brainstorm; default = capture only subagent_type (skill name), drop ephemeral agent_id.
5. **Silently-missing event types** (Continue #6795 / Claude Code own subagent hooks not always firing). **Mitigation:** per-event-kind cadence tracking — surface in Activity feed if event_kind drops to zero for >24h despite session activity. Defer impl to Phase 4.9; flag now as known.
6. **Concurrent multi-window sessions** writing same project. Multiple Claude Code windows on same `cwd` → two `session_id` values interleaved in same project. **Mitigation:** sessions keyed by `session_id` not by `cwd`; jsonl naming already enforces this (`~/.claude/projects/<slug>/<session-uuid>.jsonl`).
7. **Body-kind dispatcher tuple refactor** (Track 4 S4). If new event_kinds carry non-canonical user-authored strings (file names? subagent skill names?), dispatcher needs the tuple-style signature. P1 likely fine — file paths are canonical. Subagent skill name (e.g. `superpowers:brainstorming`) is canonical too — string is a registry value, not free user text.

---

## 8. Decisions (locked-in 2026-05-15, brainstorm anchor)

User directive: "сделать охуенно с первого раза без больших доработок после". Decisions optimize for substrate-correctness up front, not minimal-MVP. Each decision below moves brainstorm scope from "open question" to "implement this way unless brainstorm surfaces a concrete reason against".

### D1 — Hybrid capture (jsonl floor + opt-in hooks ceiling)

**Decision:** ship both surfaces.

- **jsonl tail-read stays as floor** — historical backfill, zero-config baseline, works for users who refuse hook install or whose `claude` binary path is unstable.
- **Live hooks installed at onboarding** — opt-in toggle "Install Claude Code hooks for richer signal? (recommended)" with default ON, paired with a "Why this is safe" walkback (we write a single `hooks` block in `~/.claude/settings.json` pointing at the Leaf-Agent binary; ADR-010 still applies — we drop content fields before write).
- **Single collector consumes both.** Hook path emits richer payload (`duration_ms`, `effort.level`, `source`, `permission_mode`). Jsonl path emits fallback. Dedup via `tool_use_id` (stable across both surfaces; jsonl `toolUseID` == hook `tool_use_id`). Where both arrive: hook payload wins (richer); jsonl backfill skipped for that `tool_use_id`.
- **Hook install discipline** — write only inside an idempotent JSON block keyed by name (e.g. `"_leaf_managed": true`); on uninstall, remove only that block; never clobber user's other hooks. Settings-file race: read-modify-write under a 1s file-lock; if conflict, retry once then surface "couldn't update hooks — open Settings → AI Tools to retry".
- **Why:** loses no historical data; gains every signal Anthropic adds without rewriting; preserves zero-config trial install (user can defer hooks without losing all AI capture).

### D2 — Token attribution: capture in P1

**Decision:** new event_kind `claude_tokens_used` lands in P1.

- **Mechanism:** extend jsonl parser (`ClaudeCodeJSONLParser.swift`) to read `assistant-message.tokens-used` per turn. Hooks don't expose tokens (Anthropic #11008/#11535) — jsonl is the only source for now.
- **Payload (privacy-clean):** `session_id, source_msg_uuid, model, prompt_tokens, completion_tokens, cwd, git_branch`. **NO model output content, NO prompt content.** `RelayBodyLeakageTests` walkback per turn payload.
- **ShareEventTypeKey:** `claude_tokens_used`, default OFF.
- **Why P1, not 4.9:** deferring forces a future migration that re-tests existing capture path. Token attribution is a known moat (no competitor has per-turn-per-project tokens on macOS); shipping in P1 anchors `aiActivityBreakdown` refinement work (token-weighted ratio) in the same release. Cost is ~50 LOC parser + 1 event_kind + 1 share-key — well-bounded.
- **Derived consequence:** Phase 4.9 `aiRatio` gets a second flavor — `aiRatioByTokens()` complements existing `aiRatioByTime()`. Define both in P1; primary is by-time (existing semantics preserved), by-tokens additive.

### D3 — Subagent dispatch: full depth

**Decision:** capture subagent's own `tool_use` / `tool_result` events as separate `events` rows, linked to parent via `parent_session_id` payload field.

- **Mechanism:** the subagent's `transcript_path` is its own jsonl file (and emits its own hooks if hooks installed). Tail-read picks it up automatically. Each child event carries `parent_session_id` and `subagent_type` in payload.
- **Double-count guard:** parent's `claude_subagent_dispatched` event carries `duration_ms` = full subagent wall-time (already includes child work). Insights queries that surface "tool usage breakdown" must filter `parent_session_id IS NULL` to avoid counting child events in parent's per-tool histogram, OR explicitly opt into depth (e.g. `aiActivityBreakdown(includeNestedSubagents:)` flag).
- **Why depth, not rollup:** parallel-agent dispatch is a fast-growing user pattern (this session itself spawned 3 research subagents). Rollup hides "3 agents collectively did 12 reads + 4 greps" — a real loss for user-facing "what did I just do this hour" recall. Cost is row volume — acceptable, well within WAL discipline.
- **Subagent ID anonymization:** capture `subagent_type` (registry value like `Explore`, `general-purpose`, `claude-code-guide`) — these are public names. Ephemeral subagent_id (UUID) NOT captured (per Track-4.7.C anonymization pattern).

### D4 — `tool_use` / `user_prompt` share-keys: default OFF (no migration toast needed)

**Decision:** add ShareEventTypeKey entries for the two existing event_kinds with default OFF.

- **Why OFF:** Track-6 contract §2.5 fitness criterion explicit on default OFF. Privacy-first posture compounds across track.
- **Why no migration toast (Stage 1 correction):** `share_event_types` is **pure-code today** — no DB persistence yet. The registry comment at `ShareEventTypeRegistry.swift:6-9` defers runtime UPSERT to "Phase 5 prep / отдельная mini-migration". Therefore users never had a per-event-kind toggle for `tool_use` / `user_prompt` (they were emitted unconditionally, with no per-key filter UI). Adding the two share-keys default OFF is a **first-time control surface**, not a behavior change against an existing UI toggle. No migration toast needed.
- **Downstream:** the share-filter consumer code path (currently sieves on signal-type level only for AI) gains per-event-kind sieving for AI as a side-effect of D1's UI work. Whether to ship the filter sieve in P1 or defer with the rest of `share_event_types` table is a brainstorm question (see §8a).

### D5 — Catch-all: implementation discipline anchored in prior-track anti-patterns

Decisions to bake in without re-debating per phase:

- **Dispatcher tuple refactor.** New event_kinds with non-canonical payload keys (none anticipated in P1, but `subagent_type` lives outside the canonical body field — verify in brainstorm) flow through the Track-4 S4 `Schema.BodyKinds` dispatcher tuple. `DispatchCoverageTests` parity fence extended per new event_kind.
- **Sentinel-injection walkback** per new event_kind in `RelayBodyLeakageTests`. Walks the entire `payload_json` tree for forbidden sentinels: prompt sentinel, tool_input sentinel, tool_result sentinel, thinking sentinel, command-string sentinel.
- **Cold-vs-warm tick branch** per new collector path (live hooks: cold = settings.json just installed, no events yet; warm = receiving events). Integration test simulates cold start race per surface.
- **Per-event-kind cadence health (deferred to 4.9).** Flag now as known carry-over: surface "this event_kind stopped firing for 24h despite session activity" as coverage signal. Continue.dev #6795 lesson — events silently fail to emit.

---

## 8a. Brainstorm-stage open mini-questions (technical, not product)

These don't block Stage 1 / 2 but should be answered during brainstorm before plan-write:

- Exact hook-install file format inside `~/.claude/settings.json` (matcher patterns, command path, timeout, `_leaf_managed` block shape).
- `claude_session_started` payload — include `source` enum (startup\|resume\|clear\|compact) and `model`, but what about `version`? (Probably yes — useful for cohort cuts.)
- `claude_mcp_tool_invoked` payload — keep full `mcp__<server>__<tool>` string or split into `mcp_server` + `mcp_tool` fields? (Splitting feels right — easier filter queries.)
- Subagent's own jsonl is in same `~/.claude/projects/<slug>/` directory — confirm `parent_session_id` is recoverable from jsonl alone (the subagent's first message should reference parent via `parentUuid` chain).
- Whether to land an `events` index on `(payload_json->'$.parent_session_id')` for fast subagent rollup queries, or defer to first slow query in DerivedInsights.

---

## 9. Estimated registry delta (post-decisions)

Per Track-6 contract §6.2, refined by §8 decisions.

Per-tool (D1 hybrid surface): `claude_bash_executed, claude_file_edited, claude_file_written, claude_file_read, claude_web_fetched, claude_subagent_dispatched, claude_mcp_tool_invoked, claude_slash_command_invoked` (8).

Per-session (D1 hooks ceiling): `claude_session_started, claude_session_ended, claude_session_compacted, claude_prompt_submitted, claude_turn_ended` (5).

Token (D2): `claude_tokens_used` (1).

Subagent depth (D3): nested event_kinds reuse the same `claude_*` discriminators with `parent_session_id` payload field — **no extra registry entries**. (Filtering by parent_session_id is a query-time concern, not a share-key concern.)

Retroactive (D4): `tool_use, user_prompt` share-keys added — default OFF (2).

**Registry baseline 152 → P1 target ≈168** (8 + 5 + 1 + 2 + existing 152). All default OFF.

Contract §6.2 estimate was "~10 entries"; refined to 14 net-new (+ 2 retroactive = 16 total). Within contract envelope of "comparable order-of-magnitude to Linear/GitHub/Slack" for ceiling-supported surfaces.

---

## 10. References

- Phase contract: `docs/superpowers/specs/2026-05-15-track-6-existing-surface-depth-contract.md`
- Architecture: `.claude/shared/architecture.md` (Layer A AI collab — lines 59-65; storage — lines 84-95)
- Current-state: `.claude/shared/current-state.md` (Phase 4.7 / Track-3 / Track-4 carry-overs)
- ADR-010 / Won't-list: whitepaper `docs/privacy-security/wont-list.md`
- Claude Code docs: code.claude.com/docs/en/hooks
- Continue.dev event schemas: `continuedev/continue/packages/config-yaml/src/schemas/data/`
- vscode-wakatime AI detection bug: github.com/wakatime/vscode-wakatime/issues/476
- Claude Code token-in-hooks request: github.com/anthropics/claude-code/issues/11008, #11535
- ActivityWatch macOS TCC discipline: github.com/ActivityWatch/aw-watcher-window PR #41

---

## 11. Stage 1 Discovery findings (anchor for brainstorm)

Discovery ran 2026-05-15 via Explore subagent + main-session cross-check on `ShareEventTypeRegistry.swift` and `ActivityFeedMapper.swift`. Findings are pinned here so brainstorm and plan-write speak in concrete file:line and types.

### 11.1 Registry & parity fence — concrete shape

- `ShareEventTypeKey` is a pure-Swift enum with `String` rawValue at `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift:18`. Adding an entry = (a) append enum case, (b) append `.init(key:, defaultEnabled:)` line in `ShareEventTypeDefaults.all` (line 232+).
- **No `share_event_types` DB table today.** Comment at lines 6-9 explicit: runtime UPSERT deferred to Phase 5 prep / separate mini-migration.
- `DispatchCoverageTests` parity-fence (file `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift`) currently fences only `GitHubEventKindKey.allCases` and `SlackEventKindKey.allCases` against `ShareEventTypeKey.allCases`. **There is no `ClaudeCodeEventKindKey` enum today** — Claude Code event_kinds are inline string constants in the parser. Brainstorm question §8a-Q1 below.
- Defaults pattern: outcome-bearing events default ON (baseline GitHub/Slack/Linear push/PR/issue events); detection / deep-sweep / system-observer events default OFF. Per D4 we land all `claude_*` entries default OFF.

### 11.2 Collector path — write site for new event_kinds

- `ClaudeCodeCollector` (`Packages/LeafCore/Sources/LeafCore/Collectors/ClaudeCodeCollector.swift`) is an actor; `start()` spawns 5s-settle-then-loop calling `performTick(now:)` at `intervalSec` (from `AgentThresholds`).
- Per-file state: `collector_offsets` row keyed `(collector_id=claudeCodeJSONL, source_id=canonicalPath)` with `byte_offset, inode, size, last_modified_ms`. Truncate/rotate detection: `inode` mismatch or `size < stored.byteOffset` → reset offset.
- **Subagent jsonl is a separate file in `~/.claude/projects/<slug>/`** — gets its own `collector_offsets` row automatically. **This makes D3 depth basically free at the tail-read level** — each subagent transcript is tail-read independently; parent linkage happens at parser level via `parent_session_id` in payload.
- Persist site: `database.writeEventsAndOffset(allEvents, offset:)` — single TX per tick, events + offset atomic. Error path drops events (no retry queue). Acceptable; we own the cursor advance.
- Parser entry: `ClaudeCodeJSONLParser.swift` (private moat). Today's switch on jsonl entry `type`: `"assistant"` → emit `tool_use` per nested `tool_use` element; `"user"` → emit `user_prompt`; everything else `.irrelevant`. File-ops tools (`Read, Edit, Write, Glob, MultiEdit, NotebookEdit`) extract `file_path`. P1 adds: per-tool kind split, session-lifecycle emit from `"system"` SessionStart/End markers, token-attrib emit from `"assistant"` `tokens-used` field.

### 11.3 Mapper — coverage NOT fenced

- `ActivityFeedMapper.mapAI` (lines 78-123) already has a default branch that handles unknown future AI kinds via `tool_name`/`agent`/`file_path`/`cwd` fallback. So new `claude_*` event_kinds **render gracefully without mapper changes** — but generically (no per-kind copy). For high-quality feed rows we add explicit cases (e.g. `claude_subagent_dispatched` → "Subagent: Explore" copy).
- **Crucial gap:** there is no DispatchCoverageTests assertion that `mapAI` covers all AI event_kinds. (The S1+S2+S3 `mapLocalOS` has `trackFourLocalOSKinds` whitelist + `EventKindIconTests.testAllTrack4VisibleKindsMapped` parity assertion, but no equivalent for `mapAI`.) Brainstorm question §8a-Q2.
- New event_kinds we want to suppress from the feed (e.g. high-cadence `claude_tokens_used` per turn could flood) go into `ActivityFeedMapper.skippedKinds` set. Brainstorm question §8a-Q3.

### 11.4 Hook installer — net-new file-write mechanism

- **No code in the repo today writes to `~/.claude/settings.json`** — verified by explore. D1 hybrid requires net-new write path.
- Recommended ownership: **MenuBarApp** (Leaf.app), not Agent. Rationale: settings install is a user-consent moment (onboarding toggle), tied to UI, idempotent JSON merge — natural fit for the app process. Agent stays passive (tail-read jsonl) — it doesn't need to know whether hooks are installed; the hook command resolves to the same Agent binary regardless.
- File-write discipline (concrete shape for plan): read-modify-write under a 1-second `flock`-style file lock; merge inside an idempotent block keyed `"_leaf_managed": true`; on uninstall remove only that block.

### 11.5 Onboarding & Settings → AI Tools — does not exist yet

- `OnboardingView.swift` steps today: `welcome → ax → fda → observers → team → done` (line 19-20). No AI-tools step.
- **No Settings → AI Tools view exists** despite Track-6 contract §8 referencing it. Brainstorm question §8a-Q4 — where exactly does the "Install Claude Code hooks" toggle land? Options: (a) new onboarding step inserted after `observers` (`hooks`?); (b) Settings section "AI Tools" net-new; (c) sub-section under existing Settings → System Observers (since hook install is observer-class).

### 11.6 Migration counter

- Schema migrations: M001..M018 shipped (latest = `M018_IntensityAggregates` from Track-4 S3, 2026-05-13).
- Track-5 reserved range: M019..M023 per current-state.md.
- **Track-6 P1 starts at M024** per contract §6.1. P1 likely needs **zero new migrations** (decision per §6 of this doc — all signal lands as event_kind discriminators + ShareEventTypeKey appends). M024 stays reserved for later P1 brainstorm output if it surfaces a real table need.

### 11.7 Tests pattern

- Pure-Swift XCTest, no simulator. Fixture pattern: temp directory + write jsonl strings + instantiate collector with mock or real parser + `await collector.performTick()` + assert via `database.events(in:)`.
- New event_kind smoke test template lives in `ClaudeCodeCollectorTests.swift`. Per-event-kind detailed assertions live in private `ClaudeCodeJSONLParserTests.swift` (gitignored — moat).
- `RelayBodyLeakageTests` sentinel pattern: inject sentinel into payload[`body`], write events + presence in one TX, assert sentinel absent from `presence_state.state_json`. For P1 we add a sentinel test per new event_kind walking the full payload tree (per Track-4 S4 lesson).

---

## 8a (extended) — Brainstorm-stage open mini-questions

Original §8a + new questions surfaced by Discovery:

- **Q1 (Discovery-surfaced).** Land a `ClaudeCodeEventKindKey` enum to mirror `GitHubEventKindKey` / `SlackEventKindKey` patterns? Pros: DispatchCoverageTests parity fence extends naturally (one new assertion block), single source of truth for the ~14 new kinds, type-safe call sites in parser. Cons: more boilerplate vs inline strings. **Lean: yes — parity with existing patterns wins.**
- **Q2 (Discovery-surfaced).** Extend DispatchCoverageTests with a `mapAI` coverage assertion (every `claude_*` ShareEventTypeKey case has a non-default-branch case in `mapAI` switch — or is explicitly whitelisted in a `claudeCodeSkippedKinds` set)? Symmetry with Track-4 S4's `EventKindIconTests.testAllTrack4VisibleKindsMapped`. **Lean: yes — gap is a known anti-pattern.**
- **Q3 (Discovery-surfaced).** Which new event_kinds belong in `ActivityFeedMapper.skippedKinds` (i.e. excluded from chronological feed and surfaced only via Live Presence / Derived Insights)? Candidates: `claude_tokens_used` (per-turn → 1/turn → flood-level if active session), `claude_turn_ended` (Stop hook fires per turn — also flood). Subagent-depth events (`claude_*` rows with `parent_session_id IS NOT NULL`) — filter at query level, not mapper, since they're useful in deep-dive but flood in feed.
- **Q4 (Discovery-surfaced).** UI placement for "Install Claude Code hooks" toggle — Settings → AI Tools (net-new section), or sub-toggle under Settings → System Observers, or new onboarding step? Likely new section since AI Tools surface is named in architecture and Track-6 §8 of the contract. **Lean: new Settings → AI Tools section + sub-toggle list (start with just "Install Claude Code hooks" + reuse it for Cursor / Continue.dev in future P-tracks).**
- **Q5 (carried from §8a original).** Exact hook-install file format inside `~/.claude/settings.json` (matcher patterns, command path, timeout, `_leaf_managed` block shape).
- **Q6.** `claude_session_started` payload — include `source` enum (startup\|resume\|clear\|compact) and `model` and `version` and `permission_mode`?
- **Q7.** `claude_mcp_tool_invoked` payload — keep full `mcp__<server>__<tool>` string or split into `mcp_server` + `mcp_tool` fields?
- **Q8.** Subagent's own jsonl is in same `~/.claude/projects/<slug>/` directory — confirm `parent_session_id` is recoverable from jsonl alone (subagent's first message references parent via `parentUuid` chain, or via `isSidechain` field).
- **Q9.** Whether to land an `events` index on `payload_json->>'parent_session_id'` for fast subagent rollup queries, or defer to first slow query in DerivedInsights.

---

**Next step:** Stage 2 Brainstorm anchored on §8 decisions + §8a Q1–Q9. Decisions D1–D5 locked unless brainstorm surfaces concrete reason against (in which case contract §12 decision log gets an amendment). Brainstorm-stage answers Q1–Q9 in the brainstorm session itself, then Spec write (Stage 3) lands.
