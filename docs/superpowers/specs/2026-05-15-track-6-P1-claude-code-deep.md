# Track 6 P1 — Claude Code Deep · Design Spec

**Status:** Draft (2026-05-15). Promoted to "Active" after user review gate (Stage 3) closes.
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Stage 0 research:** `2026-05-15-track-6-P1-claude-code-research.md` (D1–D5 locked decisions + Q1–Q9 resolved in brainstorm)
**Authors:** Dmitrii + Claude (brainstorm session 2026-05-15)
**Stage in 8-stage workflow:** 3 (Spec write) — Stage 4 (`writing-plans`) follows after user approval.

---

## 1. Goal & scope

Bring the Claude Code surface from 2 generic event_kinds (`tool_use`, `user_prompt`) to **16 specific event_kinds + path-derived subagent depth + per-turn token attribution + opt-in hook bridge + Settings/Onboarding UI**, at depth-parity ambition with Slack / Linear / GitHub (Track 3).

Fitness function (per Track-6 contract §2):

1. **Ceiling-mapped.** Stage 0 research (`...P1-claude-code-research.md`) documents the realistic ceiling — hook surface (9 event flavours, `agent_id` linkage, `duration_ms` timing) + jsonl surface (`message.usage.*` token shape, `<parent>/subagents/` subagent transcripts).
2. **Event vocabulary lands.** 14 net-new `claude_*` event_kinds + 2 retroactive share-keys for existing `tool_use` / `user_prompt`. Registry 152 → 168.
3. **Parser correctness.** Per-flavour parsers in `LeafCorePrivate/Prod/Collectors/ClaudeCodeJSONLParser.swift` + new hook bridge stdin parser. Cold-start race + warm-tick + hook-vs-jsonl dedup tested.
4. **Privacy contract preserved.** `RelayBodyLeakageTests` sentinel walkback per new event_kind; ADR-010 walkbacks enumerated in §11.
5. **Share Controls.** All 16 entries default OFF in `ShareEventTypeDefaults.all`.
6. **Smoke verified.** Per-phase acceptance gate (§13) on author's Mac.

**In-scope:** capture pipeline (D1 hybrid), event vocabulary, subagent depth, token attribution, hook installer + IPC bridge, Settings → AI Tools + Onboarding step, M024 migration, type system + dispatcher fences, tests, acceptance smoke.

**Out-of-scope:** Phase 4.9 Derived Insights (`aiRatioByTokens()`, subagent rollup queries, per-event-kind cadence health); Cursor / Continue.dev / Codex hooks (separate AI-collab track); cross-provider links Claude → Linear/GitHub (Phase 4.9). Substrate landed here; consumer methods declared as stubs only.

---

## 2. Capture pipeline (hybrid, per D1)

Two converging surfaces — hook (rich, opt-in) + jsonl (floor, always-on). Both feed `ClaudeCodeCollector` → `ClaudeCodeJSONLParsing` → `RawEvent` → `database.writeEventsAndOffset`.

### 2.1 Hook flow (rich, opt-in)

```
claude CLI (active session)
  → reads ~/.claude/settings.json hooks block (only if Settings → AI Tools toggle ON)
  → for each hook event (PreToolUse, PostToolUse, UserPromptSubmit, Stop,
    SubagentStop, SessionStart, SessionEnd, PreCompact, Notification):
      → spawns `/Applications/Leaf.app/Contents/MacOS/leaf-hook-bridge <EventName>`
      → bridge reads JSON stdin (≤ ~5KB typical)
      → bridge connects to ~/Library/Application Support/Leaf/hooks.sock
      → writes one-line JSON `{kind, payload, ts_ms}` to socket
      → bridge exits 0 (target <50ms p99; fail-soft if socket absent)
  → Agent listens on socket via Network framework NWConnection (DispatchQueue serial)
  → per inbound line: parse → emit RawEvent(source: .hook)
  → batched flush to DB on 1s timer OR 32-event buffer (whichever first)
```

**Why bridge binary, not direct Agent invocation:** `claude` invokes hook commands synchronously per event. Spawning the Agent (~5MB Swift binary, ~100ms cold start) ×10–60/min would tank Claude UX. Bridge is ~50KB thin native binary; cold start ~5ms; only Network connect+write+exit.

**Bridge failure modes (fail-soft):**
- Socket missing (Agent restarting / not launched) → bridge writes warning to stderr, exits 0. Claude continues. jsonl floor backfills within 30s.
- Bridge missing (Leaf.app moved / uninstalled) → `claude` reports command-not-found per its standard hook error path. User sees error in CLI; jsonl floor still works.
- Hook event payload malformed → bridge exits 0 silently. Agent never sees it.

### 2.2 jsonl floor (always-on)

```
Agent ticks every `intervalSec` (default 5s, per AgentThresholds)
  → globs ~/.claude/projects/<slug>/*.jsonl                     ← top-level (existing)
  → globs ~/.claude/projects/<slug>/<parent>/subagents/agent-*.jsonl  ← NEW for P1
  → per file: lookup collector_offsets[claude_code_jsonl, abs_path]
  → tail-read from byte_offset; detect inode change → reset offset
  → per line: ClaudeCodeJSONLParsing.parse(line:source:now:)
  → on .events([RawEvent]): emit each with source=.jsonl
  → atomic writeEventsAndOffset(events, offset) per file
```

**Current collector limitation fixed:** `ClaudeCodeCollector.swift:131` explicitly skips deep subdirs ("Не используем deep `enumerator` чтобы не глядеть в случайные subdirs"). P1 extends discovery to walk exactly `<projectSlug>/<sessionUuid-dir>/subagents/*.jsonl` — known structure, no wildcard recursion.

### 2.3 Dedup (when hook + jsonl both surface same activity)

Hook fires fast (~5ms); jsonl appears within seconds. Both record the same `tool_use_id` (hook: `tool_use_id` field; jsonl: `toolUseID` field).

Per `ClaudeCodeCollector` writer:
- Maintain in-memory LRU set of last 2048 `tool_use_id` strings seen via hook path.
- When jsonl parser emits event with matching `tool_use_id` → skip (hook wins).
- LRU eviction by age — ~30min retention sufficient (jsonl tail-read is near-realtime).
- Hook events without `tool_use_id` use per-kind dedup tuples — hook fires at T0, jsonl line appears T0+1–5s, so timestamp-rounding-windows don't dedup reliably. Per-kind strategies:
  - `claude_session_started` — jsonl-only emit (no dedup needed; hook event observed for metric only).
  - `claude_session_ended` — dedup by `session_id` alone (one per session lifetime).
  - `claude_session_compacted` — hook-only (no dedup).
  - `claude_prompt_submitted` — dedup by `(session_id, prompt_length_chars)` within 60s window (length-collision in same session within a minute is acceptable false-merge).
  - `claude_turn_ended` — hook-only (no dedup).
  Exhaustive per-kind table refined in plan stage.

Rationale: jsonl path can't fully replicate `duration_ms` (only in hook), so hook payload is strictly richer when both arrive.

### 2.4 Source provenance

Every claude_* event gets payload field `source: "hook" | "jsonl"`. Lets us debug "where did this event come from" without log archaeology. Default-rendered in Activity feed secondaryText for AI-collab events as small badge ("via hook" / "via jsonl backfill") — informational only, no privacy concern.

---

## 3. Event vocabulary (14 net-new + 2 retroactive)

All rawValues prefixed `claude_` (new) or unchanged (retroactive). All default OFF in `ShareEventTypeDefaults.all`. Standard payload fields на каждом kind: `session_id, source_msg_uuid (if applicable), cwd, git_branch, source (hook|jsonl), agent_id? (if subagent)`.

### 3.1 Session lifecycle (5 kinds)

| event_kind | Source | Extra payload | Feed |
|---|---|---|---|
| `claude_session_started` | **jsonl only** | `source_enum` (startup\|resume\|clear\|compact), `model`, `version`, `permission_mode`, `entrypoint` | visible |
| `claude_session_ended` | hook + jsonl | `reason` (clear\|resume\|logout\|prompt_input_exit\|...), `duration_seconds` | visible |
| `claude_session_compacted` | hook only | `estimated_token_count`, `target_token_count`, `trigger` (manual\|auto) | visible |
| `claude_prompt_submitted` | hook + jsonl | `prompt_length_chars`, `permission_mode`, `effort_level` (low\|medium\|high) | visible |
| `claude_turn_ended` | hook only | `stop_reason`, `turn_number` | **skipped** |

**`claude_session_started` design note.** Real SessionStart hook payload (verified via claude.com/docs/en/hooks) carries only `{session_id, transcript_path, cwd, source, model}`. The other 3 fields (`version, permission_mode, entrypoint`) live in jsonl per-line context. To emit a single event with all 5 fields, P1 emits `claude_session_started` exclusively from jsonl path — on first parsed line of a new session_id. Latency 1 tick (~5s) is acceptable for rare event (~1/hr). Hook's `SessionStart` is observed but discarded for emit purposes (substrate-only).

### 3.2 Per-tool events (7 kinds)

| event_kind | Source | Extra payload | Feed |
|---|---|---|---|
| `claude_bash_executed` | hook + jsonl | `command_length_chars`, `exit_code?`, `duration_ms` (hook), `permission_mode` (hook) | visible |
| `claude_file_edited` | hook + jsonl | `file_path`, `bytes_added`, `bytes_removed`, `is_new_file=false` | visible |
| `claude_file_written` | hook + jsonl | `file_path`, `byte_count`, `is_new_file=true` | visible |
| `claude_file_read` | hook + jsonl | `file_path`, `line_range_count?` | visible |
| `claude_web_fetched` | hook + jsonl | `domain`, `url_path_hash`, `tool_name` (WebFetch\|WebSearch) | visible |
| `claude_mcp_tool_invoked` | hook + jsonl | `mcp_server`, `mcp_tool`, `tool_full_name`, `duration_ms?`, `permission_mode?` | visible |
| `claude_slash_command_invoked` | hook + jsonl | `command_name` | visible |

**MCP split rationale (Q7):** `mcp_server`, `mcp_tool`, `tool_full_name` all stored. Filter queries `WHERE mcp_server = ?` run without SUBSTR; `tool_full_name` preserved for forward-compat (single-source-of-truth) and debug.

### 3.3 Subagent + token (2 kinds)

| event_kind | Source | Extra payload | Feed |
|---|---|---|---|
| `claude_subagent_dispatched` | hook + jsonl | `subagent_type`, `description`, `agent_id` | visible |
| `claude_tokens_used` | **jsonl only** | `model`, `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `service_tier` | **skipped** |

**Subagent dispatch detail.** When parent fires `Task` tool:
- **hook path:** parent's `PostToolUse` for `tool_name=Task` carries `tool_input.subagent_type`. Bridge writes; collector emits `claude_subagent_dispatched` with `agent_id` from hook's `agent_id` field (Optional — present once the subagent is allocated).
- **jsonl path:** parent's jsonl shows `tool_use: Task` line; parser emits `claude_subagent_dispatched` with `agent_id = null` (not known parent-side via jsonl alone). Path-discovery side: when collector glob picks up new `agent-<id>.jsonl` file, parser emits subagent's own events with `agent_id` derived from filename.

Both paths deduplicate via `(parent_session_id, subagent_type, ts_ms_rounded_to_second)`.

### 3.4 Retroactive share-keys (2 kinds)

| event_kind | Note |
|---|---|
| `tool_use` | retroactive — existed before P1, no share-key control surface previously |
| `user_prompt` | same |

Default OFF (per D4 locked decision). No migration toast — `share_event_types` is pure-code today (Phase 5 prep / mini-migration deferred); P1 adds first-time control surface. The two retroactive entries simply gain runtime visibility through the existing share-filter dispatch once `share_event_types` DB lands later.

### 3.5 Activity feed coverage

- **Visible kinds:** 14 of 16 — explicit case in `ActivityFeedMapper.mapAI` switch + EventKindIcon SF Symbol + per-kind primaryText/secondaryText.
- **Skipped kinds:** `claude_tokens_used` + `claude_turn_ended` — high cadence per-turn (~10–30/hr on active session) would flood feed. Both populate `events` rows; consumed by Live Presence (token rollup aggregate) and Phase 4.9 Derived Insights (turn-duration histogram, cost-attribution).
- **Subagent-depth filter:** query-level — top-level Activity feed `WHERE json_extract(payload_json, '$.agent_id') IS NULL`. Deep-dive view (Phase 4.9 future) lifts the filter.

---

## 4. Subagent depth — path-derived linkage (per Q8)

### 4.1 Filesystem layout (verified concretely 2026-05-15)

```
~/.claude/projects/<encoded-cwd>/
    <parent-uuid>.jsonl                                ← parent session transcript
    <parent-uuid>/
        subagents/
            agent-<agentId>.jsonl                       ← subagent transcript
            agent-<agentId>.meta.json                   ← {"agentType":"...","description":"..."}
```

Parent's jsonl carries **NO** `isSidechain: true` entries in current Claude Code (≥2.1.140). All subagent activity lives exclusively in the subdir transcript file. Today's collector skips this subdir entirely (`ClaudeCodeCollector.swift:131`) → subagent capture broken since baseline. P1 first-time enables it.

### 4.2 Linkage discriminator

Discovered fields per subagent event:
- **`agent_id`** — derived from filename `agent-<id>.jsonl` (jsonl path) OR from hook's `agent_id` Optional field (hook path).
- **`agent_type`** — read from sibling `.meta.json` field `agentType` (cached in memory by `agent_id`; invalidated on inode change).
- **`description`** — read from `.meta.json` field `description` (cached same).
- **`session_id`** — same as parent's session_id. Subagents do NOT have their own top-level session_id; their transcript file is filed under the parent.

**Discriminator: `agent_id IS NOT NULL` ⇒ this is a subagent event.** No separate `parent_session_id` field needed — `session_id` already carries it.

### 4.3 Query patterns (substrate for Phase 4.9)

```sql
-- Top-level Activity feed (default filter)
SELECT * FROM events
WHERE signal_type = 'aiCollaboration'
  AND json_extract(payload_json, '$.agent_id') IS NULL
  AND ts_ms BETWEEN ? AND ?;

-- Subagent rollup for a given parent session
SELECT json_extract(payload_json, '$.event_kind') AS kind, COUNT(*)
FROM events
WHERE json_extract(payload_json, '$.session_id') = ?
  AND json_extract(payload_json, '$.agent_id') IS NOT NULL
GROUP BY kind;
```

### 4.4 Race conditions

- **Subagent file appears before meta.json:** parser tolerates missing `.meta.json` — `agent_type, description` fields set to `null` in payload; meta written by Claude moments after agent dir creation. On next tick if meta available, **no backfill update** (events are append-only). Some early subagent events ship with null agent_type — acceptable. Mitigation: collector reads meta lazily once per agent_id; if missing first time, retry on subsequent tick before processing any subagent events from that file.
- **Subagent finishes between ticks:** transcript file complete; meta.json present. Standard tail-read consumes all entries on tick.
- **Concurrent dispatch (4 subagents at once):** 4 separate `agent-<id>.jsonl` files; 4 separate `collector_offsets` rows; standard machinery handles parallel discovery.

---

## 5. Token attribution (per D2)

### 5.1 Source path

jsonl only. Hooks do not expose tokens as of Claude Code 2.1.142 (filed: anthropic/claude-code#11008, #11535). Future hook surface for tokens would land additively; current spec assumes jsonl is sole source.

### 5.2 Payload shape (verified from real jsonl, 2026-05-15)

```
payload {
  session_id: "<uuid>",
  source_msg_uuid: "<uuid>",
  cwd: "<abs path>",
  git_branch: "<branch>",
  source: "jsonl",
  model: "claude-opus-4-7",
  input_tokens: <int>,
  output_tokens: <int>,
  cache_creation_input_tokens: <int>,   // cache miss tokens (expensive)
  cache_read_input_tokens: <int>,        // cache hit tokens (cheap)
  service_tier: "standard" | "priority",
  agent_id?: "<id>"                      // if subagent
}
```

Per-turn (one row per `assistant-message` jsonl entry with `usage` block).

### 5.3 Forbidden fields (sentinel-walkback)

Never recorded in payload tree:
- `message.content[]` blocks (assistant text)
- `thinking[*].thinking` (thinking content)
- `thinking[*].signature` (cryptographic seal — content-derived)
- `iterations[*]` (intra-turn retries — derived from prompt)
- `stop_reason` on `assistant-message` (recorded on `claude_turn_ended` event only, not on token event)
- `server_tool_use.*` field group (server-side tool count — recorded into `claude_web_fetched` event, not duplicated here)

### 5.4 Phase 4.9 substrate

Method stubs declared in `DerivedInsights` (no body):

```swift
public func aiRatioByTokens(period: DateInterval) -> AIRatioByTokens {
    fatalError("Phase 4.9 — substrate landed in P1, consumer pending")
}
public func subagentRollup(parentSessionId: String) -> SubagentRollup {
    fatalError("Phase 4.9 — substrate landed in P1, consumer pending")
}
```

P1 ships data only. Stubs make accidental call obvious; Phase 4.9 supplies bodies.

---

## 6. Hook installer + IPC bridge

### 6.1 `~/.claude/settings.json` block shape

Idempotent merge under master toggle. Bridge command path captured at install in `LocalKVStore` (key `aiTools.claudeCode.bridgePath`).

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*",
        "hooks": [{ "type": "command",
                    "command": "/Applications/Leaf.app/Contents/MacOS/leaf-hook-bridge PreToolUse",
                    "timeout": 2 }] }
    ],
    "PostToolUse": [
      { "matcher": "*",
        "hooks": [{ "type": "command",
                    "command": "/Applications/Leaf.app/Contents/MacOS/leaf-hook-bridge PostToolUse",
                    "timeout": 2 }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*",
        "hooks": [{ "type": "command",
                    "command": "/Applications/Leaf.app/Contents/MacOS/leaf-hook-bridge UserPromptSubmit",
                    "timeout": 2 }] }
    ],
    "SessionEnd": [
      { "matcher": "*",
        "hooks": [{ "type": "command",
                    "command": "/Applications/Leaf.app/Contents/MacOS/leaf-hook-bridge SessionEnd",
                    "timeout": 2 }] }
    ],
    "PreCompact": [
      { "matcher": "manual|auto",
        "hooks": [{ "type": "command",
                    "command": "/Applications/Leaf.app/Contents/MacOS/leaf-hook-bridge PreCompact",
                    "timeout": 2 }] }
    ]
  }
}
```

5 hooks total. `SessionStart` not installed (P1 emits from jsonl only — see §3.1). `Stop`, `SubagentStop`, `Notification` not installed in P1 (no event_kinds depend on them; can add in future without spec rev). `matcher: "*"` for non-tool hooks matches all sessions/prompts.

### 6.2 Install/uninstall semantics

**MenuBarApp owns the file-write** (per Q4 — Settings UI lives here; Agent stays passive). New module:

```
Leaf/Models/AIToolsHookInstaller.swift
  func install() throws -> InstallResult       // .ok / .partial / .failed
  func uninstall() throws -> InstallResult
  func currentStatus() -> Status               // notInstalled / installed / drifted (path mismatch)
```

Algorithm (install):
1. Resolve current bundle path → `Bundle.main.bundlePath + "/Contents/MacOS/leaf-hook-bridge"`. Verify binary exists + is executable.
2. Acquire `flock` on `~/.claude/settings.json` (1s timeout; on conflict retry once, then surface `.failed`).
3. Read file (create empty `{}` if missing). Parse JSON (preserve key order via dictionary-of-arrays representation).
4. Ensure top-level `hooks` object exists.
5. For each of 5 event names: walk `hooks.<EventName>[]` array → remove any entry where `entry.hooks[].command` starts with the recorded bundle path OR contains the literal substring `"/leaf-hook-bridge "` (catches drift case where bundle moved).
6. Append Leaf entries per §6.1.
7. Pretty-print JSON (2-space indent — matches `claude` CLI's own write style).
8. Write atomically: temp file in same dir + `rename(2)`.
9. Release flock. Persist `bridgePath` in LocalKVStore.

Algorithm (uninstall): same except step 6 omitted.

**Why "*"-match for non-tool hooks:** `matcher` для `UserPromptSubmit / SessionEnd` per docs accepts any pattern; `*` is permissive (matches any source). For `PreToolUse / PostToolUse` matcher matches against tool_name regex — `*` matches all tools. For `PreCompact`, matcher accepts source enum — `manual|auto` is exhaustive.

### 6.3 IPC bridge

New binary target `leaf-hook-bridge` in Xcode project (separate from Agent / MenuBarApp). Lives in Leaf.app bundle's `Contents/MacOS/`. Target output ~50KB Swift binary.

```swift
// leaf-hook-bridge/main.swift
import Foundation
import Network

@main
struct LeafHookBridge {
    static func main() async {
        let eventName = CommandLine.arguments.dropFirst().first ?? "Unknown"
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard !stdinData.isEmpty else { exit(0) }              // fail-soft on empty stdin
        let socketPath = ("~/Library/Application Support/Leaf/hooks.sock"
                          as NSString).expandingTildeInPath
        do {
            try await sendOverUnixSocket(socketPath: socketPath,
                                         eventName: eventName,
                                         payload: stdinData,
                                         timeoutMs: 50)
        } catch {
            // Agent down or socket missing — fail-soft, jsonl floor will backfill
            FileHandle.standardError.write(Data("leaf-hook-bridge: \(error)\n".utf8))
        }
        exit(0)
    }
}
```

**Agent side** (new module `LeafCorePrivate/Prod/Collectors/HookSocketListener.swift` — moat by design, schema parsing lives here):

- `NWListener` on `unix-domain` endpoint at `~/Library/Application Support/Leaf/hooks.sock` (0600 perms).
- Accept queue → per-connection `NWConnection` → read line-delimited JSON envelope `{event_name, payload_json, ts_ms}`.
- Per envelope: pass to `ClaudeCodeHookParser` (also moat) → emit `RawEvent` with `source: .hook`.
- Buffer + batch flush as described in §2.1.

### 6.4 Permissions / TCC

No TCC prompt. `~/.claude/` is in user home; `~/Library/Application Support/Leaf/` is our own dir. Hardened Runtime on Agent allows POSIX IPC. Sandbox is OFF on Agent (existing posture).

---

## 7. UI surface (per Q4)

### 7.1 Settings → AI Tools (new section)

**New file:** `Leaf/Views/Window/Settings/AIToolsSettingsSection.swift` — mirrors `SystemObserversSettingsSection` shape.

```
LeafSection
  title:       "AI Tools"
  description: "Capture metadata from your AI coding sessions (Claude Code; Cursor / Continue.dev later).
                Tool inputs, prompts, responses — never captured. Default OFF until you opt in."
  rows: [AIToolRow per supported tool]

AIToolRow(Claude Code):
  icon:        "sparkles" SF Symbol
  displayName: "Claude Code"
  masterToggle: AIToolsStore.isEnabled("claude_code")
  statusBadge: enum { .notInstalled, .installed, .failed(String) }   // from AIToolsStore.lastInstallResult
  expander:    "Why this is safe" disclosureGroup
               • Inserts a hooks block into ~/.claude/settings.json
               • Hook bridge runs locally and writes to a local socket
               • Prompt content / tool inputs / outputs / thinking — never read
               • Uninstall via this toggle removes only Leaf entries
  secondaryToggle: "Token attribution" → AIToolsStore.isEnabled("claude_code.tokens")
               (jsonl-only path, default OFF; gates the `claude_tokens_used` event_kind only)
```

**Order in Settings sidebar:** General → Privacy → Local Apps → System Observers → **AI Tools** → (existing further sections).

### 7.2 Onboarding step (new step)

`OnboardingStep` enum (verified current shape `welcome, ax, fda, observers, team, done`) extended:

```swift
enum OnboardingStep: String, CaseIterable {
    case welcome, ax, fda, observers, aiTools, team, done
}
```

New view: `Leaf/Views/Onboarding/AIToolsStepView.swift`.

```
Title:     "AI tool capture"
Body:      "Detect when you work with Claude Code. Metadata only — file paths, durations, token counts.
            Prompts, tool inputs, AI responses — never captured. You stay in control."
Buttons:
  Primary:   "Install Claude Code hooks"     → install + advance
  Secondary: "Skip — use jsonl fallback"     → no install, advance (jsonl floor still works)
  Tertiary:  "Learn what gets captured"      → modal listing all 16 event_kinds with explainers
```

Skip path **does not** disable the jsonl floor — it works always-on without TCC. Only the hook bridge installation is gated.

### 7.3 AIToolsStore

**New file:** `Packages/LeafCore/Sources/LeafCore/Share/AIToolsStore.swift` — mirrors `LocalAppsStore` / `SystemObserversStore` shape.

```swift
@Observable
public final class AIToolsStore: @unchecked Sendable {
    private let defaults: UserDefaults                  // same suite as LocalAppsStore
    public init(defaults: UserDefaults = .standard) { … }

    public func isEnabled(_ key: String) -> Bool        // "claude_code" / "claude_code.tokens"
    public func setEnabled(_ key: String, _ value: Bool)
    public var lastInstallResult: InstallResult?         // observable for badge updates
}
```

Wired into `PermissionsService` as new field alongside `localAppsStore` / `systemObserversStore`.

### 7.4 Privacy walkback dashboard (existing)

Track-2 D4 walkback dashboard already enumerates `ShareEventTypeKey.allCases` — re-renders automatically with 14 new claude_* + 2 retroactive entries. No code changes needed there.

---

## 8. Schema delta

### 8.1 Migration M024

**New file:** `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M024_ClaudeCodeAISubagentIndex.swift`.

```swift
public extension DatabaseMigrator {
    mutating func registerMigration024ClaudeCodeAISubagentIndex() {
        registerMigration("024_claude_code_ai_subagent_index") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_events_ai_subagent
                ON events(json_extract(payload_json, '$.agent_id'))
                WHERE signal_type = 'aiCollaboration';
            """)
        }
    }
}
```

Single partial expression index. Covers Phase 4.9 subagent rollup queries (§4.3). No new tables. `MigrationTests` extended: idempotency test (run M024 twice — no error) + EXPLAIN QUERY PLAN test (assert SELECT with `WHERE json_extract($.agent_id) IS NOT NULL AND signal_type = 'aiCollaboration'` uses the index).

### 8.2 ShareEventTypeKey registry (152 → 168)

New enum cases (appended to `ShareEventTypeKey`):

```swift
// MARK: - Track-6 P1 — Claude Code Deep
case claudeCodeToolUse = "tool_use"                      // retroactive
case claudeCodeUserPrompt = "user_prompt"                // retroactive
case claudeSessionStarted = "claude_session_started"
case claudeSessionEnded = "claude_session_ended"
case claudeSessionCompacted = "claude_session_compacted"
case claudePromptSubmitted = "claude_prompt_submitted"
case claudeTurnEnded = "claude_turn_ended"
case claudeTokensUsed = "claude_tokens_used"
case claudeBashExecuted = "claude_bash_executed"
case claudeFileEdited = "claude_file_edited"
case claudeFileWritten = "claude_file_written"
case claudeFileRead = "claude_file_read"
case claudeWebFetched = "claude_web_fetched"
case claudeSubagentDispatched = "claude_subagent_dispatched"
case claudeMcpToolInvoked = "claude_mcp_tool_invoked"
case claudeSlashCommandInvoked = "claude_slash_command_invoked"
```

All 16 entries appended to `ShareEventTypeDefaults.all` with `defaultEnabled: false`.

### 8.3 New ClaudeCodeEventKindKey enum (Q1)

**New file:** `Packages/LeafCore/Sources/LeafCore/Collectors/ClaudeCodeEventKinds.swift` — mirrors `Integrations/GitHub/GitHubEventKinds.swift` shape.

```swift
public enum ClaudeCodeEventKindKey: String, CaseIterable, Sendable, Hashable {
    case toolUse = "tool_use"
    case userPrompt = "user_prompt"
    case sessionStarted = "claude_session_started"
    case sessionEnded = "claude_session_ended"
    case sessionCompacted = "claude_session_compacted"
    case promptSubmitted = "claude_prompt_submitted"
    case turnEnded = "claude_turn_ended"
    case tokensUsed = "claude_tokens_used"
    case bashExecuted = "claude_bash_executed"
    case fileEdited = "claude_file_edited"
    case fileWritten = "claude_file_written"
    case fileRead = "claude_file_read"
    case webFetched = "claude_web_fetched"
    case subagentDispatched = "claude_subagent_dispatched"
    case mcpToolInvoked = "claude_mcp_tool_invoked"
    case slashCommandInvoked = "claude_slash_command_invoked"
}
```

Parser (moat) emits via enum case (compile-time safety); mapper reads via `.rawValue`. RawValue identical to `ShareEventTypeKey` rawValue per §3.5 single-string-identity discipline.

### 8.4 ActivityFeedMapper changes (Q2 + Q3)

`Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift`:

```swift
// Existing skip-list — append:
static let skippedKinds: Set<String> = [
    /* …existing… */
    "claude_tokens_used",
    "claude_turn_ended",
]

// NEW whitelist (mirror trackFourLocalOSKinds shape)
static let claudeCodeAIKinds: Set<String> = [
    "tool_use", "user_prompt",
    "claude_session_started", "claude_session_ended", "claude_session_compacted",
    "claude_prompt_submitted",
    "claude_bash_executed", "claude_file_edited", "claude_file_written", "claude_file_read",
    "claude_web_fetched", "claude_subagent_dispatched",
    "claude_mcp_tool_invoked", "claude_slash_command_invoked",
]
```

`mapAI` switch gets explicit case per visible kind with per-kind primaryText/secondaryText copy. Generic default branch remains for forward-compat (new unknown AI kind from future track) but `DispatchCoverageTests` fence rejects it.

`EventKindIcon.symbol(forKind:)` (Track-4 S4 helper) extended per visible kind with SF Symbol mapping (`claude_bash_executed → "terminal"`, `claude_file_edited → "pencil.line"`, `claude_subagent_dispatched → "sparkles"` etc — final choices in plan stage).

---

## 9. Type system + dispatcher fences (Q2)

`DispatchCoverageTests` (Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift) extended with three new assertion blocks:

```swift
// #N — every ClaudeCodeEventKindKey case has a ShareEventTypeKey entry by rawValue
func testEveryClaudeCodeEventKindKeyAppearsInShareEventTypeRegistry() {
    let registry = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
    for kind in ClaudeCodeEventKindKey.allCases {
        XCTAssertTrue(registry.contains(kind.rawValue),
                      "ShareEventTypeKey missing entry for \(kind.rawValue)")
    }
}

// #N+1 — every case is either visible-mapped OR explicitly skipped
func testEveryClaudeCodeEventKindKeyMappedOrSkipped() {
    let visible = ActivityFeedMapper.claudeCodeAIKinds
    let skipped = ActivityFeedMapper.skippedKinds
    for kind in ClaudeCodeEventKindKey.allCases {
        let rv = kind.rawValue
        XCTAssertTrue(visible.contains(rv) || skipped.contains(rv),
                      "ClaudeCodeEventKindKey.\(kind) — neither in claudeCodeAIKinds nor skippedKinds")
    }
}

// #N+2 — every case has a ShareEventTypeDefaults entry, default OFF
func testEveryClaudeCodeEventKindKeyHasDefaultEntryOff() {
    let defaults = Dictionary(uniqueKeysWithValues:
        ShareEventTypeDefaults.all.map { ($0.key, $0.defaultEnabled) })
    for kind in ClaudeCodeEventKindKey.allCases {
        XCTAssertNotNil(defaults[kind.rawValue],
                        "ShareEventTypeDefaults missing entry for \(kind.rawValue)")
        XCTAssertEqual(defaults[kind.rawValue], false,
                       "\(kind.rawValue) must default OFF per Track-6 contract §2.5 fitness")
    }
}
```

`EventKindIconTests.testAllClaudeCodeVisibleKindsMapped()` — parity assertion mirroring Track-4 S4's `testAllTrack4VisibleKindsMapped`.

---

## 10. Privacy contract (ADR-010 walkback)

### 10.1 Permanently forbidden fields

| Field | Source | Reason |
|---|---|---|
| `prompt` | UserPromptSubmit hook | full user prompt body |
| `tool_input.command` | PreToolUse/PostToolUse for `Bash` | shell command source |
| `tool_input.content` | PostToolUse for `Write` | file contents |
| `tool_input.old_string` / `tool_input.new_string` | PostToolUse for `Edit` | source code diffs |
| `tool_response.stdout` / `tool_response.stderr` / `tool_response.result` | PostToolUse | tool output bodies |
| `message.content[]` | jsonl assistant-message | assistant text |
| `thinking[*].thinking` | jsonl assistant-message | thinking content |
| `thinking[*].signature` | jsonl assistant-message | cryptographic seal of content |
| `iterations[*]` | jsonl assistant-message.usage | intra-turn retries (content-derived) |
| URL beyond `domain` | WebFetch hook | full URL identifies content |
| Bash command string beyond `command_length_chars` | Bash hook | shell command body |
| File contents (beyond `byte_count`, `bytes_added`, `bytes_removed`) | file-op hooks | source code |
| `Notification.message` text | Notification hook | user-visible text |
| Slash command argument string beyond `command_name` | SlashCommand hook | freeform argument |
| MCP tool inputs / outputs full strings | mcp__* tool calls | content |
| `agent-<id>.meta.json.description` truncated at 200 chars | meta.json | guardrails the user-authored description |

### 10.2 RelayBodyLeakageTests extension

New test `testEventBodyDoesNotLeakIntoPresenceState_ClaudeCode()` — sentinel-walkback per new event_kind. For each of 14 visible kinds:

1. Build synthetic hook payload / jsonl line with `LEAKED_SENTINEL_<kind>` injected into every forbidden field position above.
2. Run parser → write events + presence in one TX via `writeEventsAndPresence`.
3. Assert `LEAKED_SENTINEL_*` absent from `presence_state.state_json`.

Recursive walkback: payload_json tree DFS, any string-value matching sentinel pattern → test fail. Catches accidental placement in unrelated future payload fields.

### 10.3 LeafCorePrivateTests

`ClaudeCodeCollectorCrossHookTests` (moat) extended with per-kind payload assertions on synthetic fixtures — confirms parser drops `tool_input.*` content fields before they enter RawEvent.payload tree.

---

## 11. Tests

### 11.1 Coverage map

| Test file | Target | New tests for P1 |
|---|---|---|
| `ClaudeCodeCollectorTests.swift` | LeafCoreTests | subdir glob discovery, per-kind smoke (stub parser), source provenance (`source=hook` vs `source=jsonl`), tool_use_id dedup LRU, cold-start race, hook bridge unavailable fallback |
| `ClaudeCodeCollectorCrossHookTests.swift` | LeafCorePrivateTests (moat) | per-kind real-parser fixture: hook + jsonl synthetic samples → expected RawEvent payload assertions; meta.json read + caching; token-shape on `message.usage.*` |
| `RelayBodyLeakageTests.swift` | LeafCoreTests | `testEventBodyDoesNotLeakIntoPresenceState_ClaudeCode()` per §10.2 |
| `DispatchCoverageTests.swift` | LeafCoreTests | 3 new blocks per §9 |
| `EventKindIconTests.swift` | LeafCoreTests | `testAllClaudeCodeVisibleKindsMapped()` parity |
| `MigrationTests.swift` | LeafCoreTests | M024 idempotency + EXPLAIN QUERY PLAN index-use assertion |
| **NEW** `AIToolsHookInstallerTests.swift` | LeafCoreTests | temp `~/.claude/settings.json` fixture: install/uninstall idempotency; user's foreign hooks preserved; path-drift detection (Leaf bundle moved); flock retry; malformed JSON recovery |
| **NEW** `HookBridgeTests.swift` | dedicated test target for `leaf-hook-bridge` | stdin parse + socket write + fail-soft (socket missing → exit 0); timing budget (<50ms wall on test fixture) |

### 11.2 Test discipline (per phase conventions)

- Pure-Swift XCTest, no simulator.
- Fixture pattern: temp directory + write synthetic jsonl strings / hook stdin JSON + instantiate collector with mock or real parser + `await collector.performTick()` + assert via `database.events(in:)`.
- Sequential TDD per step (test first → run → see fail → implement → run → see pass → commit).

---

## 12. Acceptance smoke (per Track-4 precedent)

**Pre-conditions:** clean install of Track-6 P1 build; no `_leaf_managed` block in `~/.claude/settings.json`; SQLCipher `events.sqlite` has no rows from this build's collector.

### A. Hook install (golden path)

1. Open Leaf → Settings → AI Tools → "Claude Code" master toggle ON.
2. Expander "Why this is safe" shows bridge path + ADR-010 disclaimer.
3. `cat ~/.claude/settings.json | jq '.hooks | keys'` returns `["PreToolUse","PostToolUse","UserPromptSubmit","SessionEnd","PreCompact"]`.
4. `cat ~/.claude/settings.json | jq '.hooks.PostToolUse[0].hooks[0].command'` starts with `"/Applications/Leaf.app/"` and contains `"leaf-hook-bridge"`.
5. Status badge "Installed" appears within 2s.
6. User's existing hooks (if any pre-installed e.g. from superpowers): `jq '.hooks.PostToolUse[] | select(.hooks[].command | contains("leaf-hook-bridge") | not)'` returns those entries unchanged.

### B. Live hook flow (cold-start race)

7. Start new `claude` session in any project: `claude` CLI from a repo dir.
8. Within 1s: `sqlite3 events.sqlite "SELECT json_extract(payload_json, '\$.event_kind') FROM events ORDER BY ts DESC LIMIT 5"` shows `claude_session_started, claude_prompt_submitted` (if first prompt fired).
9. Submit prompt that runs Bash + Edit + Read: within 50ms of each tool execution, corresponding `claude_bash_executed / claude_file_edited / claude_file_read` row appears with `source=hook`.
10. Activity feed (Leaf main UI) shows each new event row with explicit per-kind copy (e.g. "Bash executed: 23 chars · 142ms"), not generic fallback.
11. `claude_tokens_used` and `claude_turn_ended` rows exist in events table but DO NOT appear in Activity feed: confirm via `sqlite3 events.sqlite "SELECT json_extract(payload_json, '\$.event_kind'), COUNT(*) FROM events WHERE json_extract(payload_json, '\$.event_kind') IN ('claude_tokens_used','claude_turn_ended') GROUP BY 1"` → both present with non-zero count; scroll feed → not visible.

### C. Subagent depth (P1's key new capability)

12. Submit prompt that dispatches ≥2 subagents via `Task` tool (e.g. "explore X with 2 parallel agents").
13. `ls ~/.claude/projects/<slug>/<parent-uuid>/subagents/` shows ≥2 `agent-<id>.jsonl` + `.meta.json` pairs.
14. Within 5s: `sqlite3 events.sqlite "SELECT json_extract(payload_json, '\$.event_kind'), json_extract(payload_json, '\$.agent_id'), json_extract(payload_json, '\$.agent_type') FROM events WHERE json_extract(payload_json, '\$.agent_id') IS NOT NULL ORDER BY ts DESC LIMIT 10"` shows subagent rows with non-null `agent_id` + `agent_type` from meta.
15. `EXPLAIN QUERY PLAN SELECT * FROM events WHERE json_extract(payload_json, '$.agent_id') IS NOT NULL AND signal_type = 'aiCollaboration'` → uses `idx_events_ai_subagent` (not full scan).
16. Activity feed top-level filter — subagent rows NOT shown by default. Deep-dive query (SQL or future Phase 4.9 UI) does surface them.

### D. jsonl floor fallback

17. Settings → AI Tools → master toggle OFF.
18. `cat ~/.claude/settings.json | jq '.hooks.PostToolUse | map(select(.hooks[].command | contains("leaf-hook-bridge")))'` returns `[]`.
19. User's foreign hooks: same `jq` predicate as A.6 returns them intact.
20. `claude` session runs (e.g. simple Read + Edit): events STILL appear in `events.sqlite` with `source=jsonl`, latency 5–30s vs <50ms on hook path.

### E. Privacy walkback (zero-tolerance)

21. `swift test --filter RelayBodyLeakageTests/testEventBodyDoesNotLeakIntoPresenceState_ClaudeCode` → passes (all 14 sentinels filtered).
22. Manual content audit: `sqlite3 events.sqlite "SELECT payload_json FROM events WHERE signal_type='aiCollaboration' ORDER BY ts DESC LIMIT 100" | grep -E '(prompt|tool_input|tool_response|thinking|signature|stdout|stderr)'` → empty.
23. Full suite: `swift test` — all green. Xcode build: 5/5 schemes green.

### F. Privacy walkback dashboard (existing)

24. Settings → Privacy → Walkback shows 14 new `claude_*` event_kinds + 2 retroactive in active-capture list with default-OFF posture preserved.
25. Toggle OFF one specific `claude_*` (e.g. `claude_bash_executed`): subsequent `claude` Bash tool use no longer produces that event_kind row (ShareControlsFilter sieves before write).

**Definition of done:** A–F all green on author's Mac + tests green (XCTest + integration + sentinel walkback) + 5/5 xcodebuild schemes + `.claude/shared/current-state.md` updated with Track-6 P1 closing summary.

---

## 13. Decisions reference

Locked decisions (Stage 0 research §8):
- **D1** — Hybrid jsonl floor + opt-in hooks ceiling; dedup via tool_use_id LRU; hook wins on overlap.
- **D2** — `claude_tokens_used` lands in P1, jsonl-only path; `aiRatioByTokens` declared as Phase 4.9 stub.
- **D3** — Full subagent depth via path-derived linkage (refined in brainstorm: `agent_id` discriminator, no `parent_session_id` field needed).
- **D4** — `tool_use` / `user_prompt` retroactive share-keys default OFF; no migration toast (`share_event_types` DB table doesn't exist yet).
- **D5** — Implementation discipline: dispatcher fence + sentinel walkback per kind + cold/warm tick branches.

Brainstorm-resolved questions (Stage 0 research §8a):
- **Q1** — `ClaudeCodeEventKindKey` enum landed, existing 2 kinds migrated.
- **Q2** — Full `mapAI` fence via `claudeCodeAIKinds` whitelist + 3 new `DispatchCoverageTests` blocks.
- **Q3** — Skip-list += `claude_tokens_used`, `claude_turn_ended`.
- **Q4** — New `Settings → AI Tools` section + new onboarding step `aiTools`.
- **Q5a** — Unix domain socket bridge via `leaf-hook-bridge` thin binary in Leaf.app.
- **Q5b** — Sentinel via command-string path (recorded `bridgePath` in LocalKVStore).
- **Q6** — Full `claude_session_started` payload (5 fields); emitted from jsonl path only.
- **Q7** — `claude_mcp_tool_invoked` split into `mcp_server` + `mcp_tool` + `tool_full_name`.
- **Q8** — Path-derived parent linkage via `<parent>/subagents/agent-<id>.jsonl`; `agent_id` payload field.
- **Q9** — Partial expression index `idx_events_ai_subagent` in M024.

---

## 14. Out of scope (P1)

- Phase 4.9 consumer methods (`aiRatioByTokens`, `subagentRollup`, per-event-kind cadence health). Substrate landed; bodies = `fatalError("Phase 4.9")` stubs.
- Cursor / Continue.dev / Codex hooks — separate AI-collab v1.1 track (architecture line 67).
- Cross-provider links (Claude → Linear/GitHub via cwd / git_branch / commit_msg patterns) — Phase 4.9.
- `Stop` / `SubagentStop` / `Notification` hook installation — defer until a derived metric requires them.
- `share_event_types` DB table runtime UPSERT — Phase 5 prep / separate mini-migration (per `ShareEventTypeRegistry.swift` comment).
- Token-source via hooks (Anthropic #11008/#11535 pending) — when hook surface gains tokens, additive integration; no spec rev required.

---

## 15. Open carry-overs (low priority)

- Architecture-doc drift on `ai_events` table reference (`.claude/shared/architecture.md` line 103). Reconcile in P1 ship commit by renaming reference to "unified events table with `signalType=aiCollaboration`".
- Bridge binary code-signing / notarization in Sparkle release flow. Verify CDHash entitlements path in plan-stage TDD.
- `agent-<id>.meta.json.description` user-authored — cap at 200 chars in parser to bound payload size; documented in §10.1 forbidden-fields table as truncation rule.
- Re-evaluate `Stop` hook installation if "did I hit thinking timeout" becomes a desired metric in Phase 4.9.

---

## 16. References

- Contract: `2026-05-15-track-6-existing-surface-depth-contract.md`
- Stage 0 research: `2026-05-15-track-6-P1-claude-code-research.md`
- Architecture: `.claude/shared/architecture.md` (Layer A AI collab — lines 59-65; storage — lines 84-95)
- Current-state: `.claude/shared/current-state.md`
- Claude Code hooks docs: `https://code.claude.com/docs/en/hooks`
- Anthropic SDK hook types: `https://code.claude.com/docs/en/agent-sdk/python` / `.../typescript`
- Whitepaper Won't-list (ADR-010 successor): `leaf-docs/docs/privacy-security/wont-list.md`
- Track-3 D2 dispatcher fence pattern: `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift`
- Track-4 S4 sentinel-walkback pattern: `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift`
