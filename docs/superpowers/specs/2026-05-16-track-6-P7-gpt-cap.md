# Track 6 P7 — GPT Cap Documented · Spec

**Stage:** Stage 3 — Spec
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Research:** `2026-05-16-track-6-P7-gpt-cap-research.md`
**Date:** 2026-05-16
**Author:** Dmitrii + Claude
**Branch:** `feature/track-6-P7-gpt-cap` (off `main`)
**Scope:** **doc-only** — no code, no schema migrations, no ShareEventTypeKey entries, no tests.

---

## 1. What Leaf captures today about ChatGPT Desktop

`com.openai.chat` is captured **generically as an L1/L2 app**, identical to any other unknown macOS app:

- **L1 Attention** — foreground / active app via `NSWorkspace.frontmostApplication` + `DidActivateApplicationNotification`. Bundle id `com.openai.chat` lands in the standard `attention` signal stream alongside Xcode / Safari / Slack.
- **L2 Intensity** — idle / active-within-session via `CGEventSourceSecondsSinceLastEventType` (Track-4 S3 bucketing). Reflects keyboard / pointer activity while ChatGPT Desktop is frontmost.

No per-app capture path exists. `grep -rni "ChatGPT|com.openai|openai.chat"` across `Packages/LeafCore` and `Packages/LeafCorePrivate/Prod` returns zero hits. There is no `ProdChatGPTAdapter`, no AppleScript dictionary call site, no FSEvents watcher, no hook listener, no API client.

Architecture (`.claude/shared/architecture.md` line 56) describes a generic `Accessibility API` window-title collector as a planned mechanism. **It is not shipped today.** Track-4 S2 added only per-app AppleScript adapters (Xcode / Safari / Chrome / Arc / Zoom / Notes / Mail / Music / etc); no generic AX window-title walk exists.

**Net:** Leaf knows when ChatGPT Desktop is in the foreground and for how long. It does not know which thread is open, what prompts you submitted, or what tools / responses were generated.

---

## 2. What Leaf cannot capture — vendor surface audit

The Stage 0 research doc (§2) enumerates every outbound vendor surface checked. Summary verdict per surface:

| Surface | Status (2026-05-16) |
|---|---|
| Public REST for "my ChatGPT sessions / messages" outbound | **Not offered.** Account-level export is email-delivered ZIP from settings (24h link, server-side). No local file stream consumable by sibling processes. |
| AppleScript dictionary (`.sdef`) for `com.openai.chat` | **Not published.** No `osascript` automation path. |
| App Intents (third-party introspection) | **Not published.** Apple Intelligence integration runs INTO ChatGPT (Siri / writing tools route user prompts in); sibling apps cannot read ChatGPT state out. |
| MCP server served by ChatGPT Desktop | **Not offered.** ChatGPT's MCP story is *consumer-side* — ChatGPT integrates third-party MCP servers. ChatGPT Desktop does not itself serve an MCP endpoint. |
| "Work with Apps" reverse-channel | **Inbound only.** ChatGPT reads OTHER apps' AX trees (Xcode / VS Code / Terminal / iTerm) to feed prompts. Does not expose ChatGPT state outward. |
| Hook / extension SDK for ChatGPT Desktop | **Not offered.** Codex CLI hooks (stable in 2026) are a separate product — they live inside Codex, not exposed to sibling macOS processes. |
| Local conversation history file watch | **Forbidden by ADR-010.** Would yield L6 content (chat bodies). Also vendor-managed implementation detail, encrypted post-2024 patch, breaks across updates. |

**Conclusion:** there is no outbound surface from ChatGPT Desktop that yields per-event capture comparable to Claude Code hooks. Pursuing the per-event ceiling would require either (a) Apple Intelligence framework readback, which Apple does not expose; (b) reverse-engineering vendor-internal state, which ADR-010 and `/pre-push-leaf` won't-list forbid; or (c) waiting for OpenAI to ship an outbound surface, which they have not.

### 2.1 Unofficial surfaces that exist but are won't-list anti-patterns

On-Mac probe (research §2.4) surfaced two **unofficial** capture paths that technically work but fail the won't-list test on independent grounds — vendor-internal store with no stability contract:

| Surface | What it would yield | Why won't-list |
|---|---|---|
| `defaults read com.openai.chat` polling — basic keyspace | `activeUserWorkspaceID` (workspace switch detection), `SEGVersionKey` (app version), `firstLaunchDate`, window state. Readable without TCC. | (a) Vendor-internal keyspace, no stability contract — keys disappear/rename across updates (2024 plaintext-store → encrypted overnight precedent). (b) `activeUserWorkspaceID` is raw vendor PII identifier — ADR-010 prefers anonymized buckets. (c) Workspace-switch event_kind is thin signal that closely tracks app-foreground L1 already captured. **Anti-pattern: parsing vendor-internal config layout.** |
| `lastAccountSettingsResponse_<workspace>` JSON blob in defaults | Plan-tier inference (full `permissions` list — `model.GPT-5.1-pro.access` / `codex-admin.access` / `hive-knowledge-retrieval.access` ~40 entries), beta-enrollment state, per-user privacy toggles (`trainingAllowed` / `lockdownModeEnabled` / `preciseLocationAllowed`), onboarding-milestone timestamps with CFAbsoluteTime precision. **Richest unofficial surface found in extended probe (research §2.5).** | (a) Vendor-internal codenames (`l1239dk1` / `BurritoNux` / `Citron` / `Aardvark` / `Stardust` / `Mercury`) with zero stability contract. (b) Cached blob refreshed on vendor-controlled cadence — not a reliable event stream, more a polled cache snapshot. (c) Entire schema can disappear next release. (d) **«Richer the surface, deeper the anti-pattern» trap** — most informative unofficial surface is also the most fragile and the most prone to triggering a brittle dependency on vendor codenames. Skip with reasoning on record. |
| FSEvents on `~/Library/Application Support/com.openai.chat/conversations-v3-<workspace-uuid>/` | Structural metadata: conversation count, per-conversation mtime (activity pulse), new-conversation / delete-conversation events. Bodies remain encrypted by vendor (file(1) reports opaque data). | (a) Same vendor-managed-store anti-pattern — directory layout has zero stability contract; vendor can rotate `conversations-v3` → `conversations-v4` or move to Keychain-backed CoreData next release. (b) Pre-2024 plaintext-store precedent demonstrates this exact directory has been silently restructured before. (c) Activity rhythm signal closely tracks `NSWorkspace` foreground + `CGEventSource` intensity already at L1/L2. **Marginal additional value, anti-pattern entry-cost.** |
| Codex agent task artifacts (`codex-taskItems-v2-*` FSEvents) | Per-task lifecycle — parallel to Claude Code's `~/.claude/projects/<slug>/*.jsonl`. Codex is bundled inside `/Applications/ChatGPT.app` on macOS (single binary distribution per second-pass probe research §2.5). | **Out of P7 scope** — contract §11 reserves AI-agent tool hooks (Cursor / Windsurf / Continue / Codex) for separate AI-collab track. P7 covers ChatGPT Desktop = chat product surface, not Codex agent surface. Flag-not-pursue this turn. |

**Why this distinction matters.** A future maintainer reading the won't-list entry might ask:

- «Why don't you just FSEvents-watch the conversation dir for activity-pulse metadata?» — Answer: vendor-internal store, no stability contract, ADR-010 discipline > thin signal duplicating L1/L2.
- «But the `lastAccountSettingsResponse` blob has the user's plan tier — that's gold!» — Answer (extended probe addendum): yes, the richest unofficial surface is also the most fragile; relying on vendor codenames like `l1239dk1` / `BurritoNux` is a guaranteed breakage path. The same anti-pattern bar applies and applies *harder* when the surface is rich.

Answers on record so this audit doesn't have to be re-litigated next quarter.

---

## 3. Privacy walkback — AX window title leak (forward-looking)

If / when the architecture-documented **generic AX window-title collector** ships (currently planned, not in P7 scope), ChatGPT Desktop's window title is a content hot spot.

**Pattern.** ChatGPT Desktop sets window title to `"<thread title> - ChatGPT"`. `<thread title>` is the user's chat topic — typically auto-generated from the first prompt and visibly encoding intent (e.g. `"Refactor authentication flow"`, `"Debug Linear OAuth callback"`). Structurally L3 metadata; semantically close to L6 content.

**Policy commitment landed by P7.** When the generic AX collector is scoped and shipped:

- `com.openai.chat` joins the **default-OFF per-app redaction list** for window-title capture, alongside Slack DM windows / 1Password / password managers / banking apps.
- ShareEventTypeKey registry entry (when it lands) defaults OFF; opt-in surfaces the privacy implication explicitly in the toggle copy.
- Pattern parallels Track-6 P3 per-domain browser allow-list — content-bearing title is opt-in only.

**No code in P7.** This is policy reservation, captured before the generic AX phase exists so the decision history is on record.

---

## 4. Permanent won't-list entry (whitepaper)

P7 lands a new sixth section in `leaf-docs/docs/privacy-security/what-we-dont-capture.md`:

### **AI co-pilot surfaces without per-event API**

Some AI co-pilot apps offer no outbound per-event surface for sibling-process capture. Leaf documents these as **vendor-blocked won't-list** — not a policy refusal, but a fact of the vendor surface. As of 2026-05-16:

| App | Bundle id | What Leaf captures | What Leaf cannot capture | Reason |
|---|---|---|---|---|
| **ChatGPT Desktop** | `com.openai.chat` | App foreground + duration (L1 attention) | Per-message / per-tool / per-session telemetry | OpenAI offers no outbound REST / AppleScript / App Intents / MCP-served / hook surface for sibling-process consumption. "Work with Apps" reverse-channel is one-directional (inbound to ChatGPT, not outbound). Account-level data export is email ZIP, not a local stream. |
| **GitHub Copilot** | (IDE-embedded — no standalone bundle) | — | Per-suggestion / per-acceptance telemetry | Copilot exposes only org-aggregate via REST `/copilot/usage`. No per-event surface. |
| **Apple Intelligence (system-level routing to ChatGPT)** | system | — | Prompt content / response content | Apple's privacy framework explicitly hides routing details from third parties. |

This is a **fact list, not a vow.** When a vendor ships an outbound surface, the entry moves out of this section and into the relevant capture phase. Trigger conditions per §5.

This entry is **separate** from the Surveillance-techniques section (which lists architectural bans Leaf imposes on itself) — vendor-blocked is structurally different from policy-blocked. Future "AI co-pilot without per-event API" entries (e.g. another desktop assistant) will append here.

---

## 5. Re-evaluation trigger conditions

The won't-list is per-vendor-surface-state, not forever. Reopen P7 follow-up phase when **any one** of these triggers fires for ChatGPT Desktop:

1. OpenAI ships an outbound REST API for "my ChatGPT Desktop session / message stream" consumable by sibling macOS processes (parallel to Claude Code's hook stream).
2. OpenAI publishes an AppleScript dictionary (`.sdef`) for `com.openai.chat`. Action: add `ProdChatGPTAdapter` mirroring Track-4 S2 per-app pattern. Allow-list only foreground state + chat title (with §3 privacy walkback); never message content.
3. Apple exposes App Intents introspection where ChatGPT Desktop registers actions readable by sibling processes.
4. OpenAI ships an MCP server **served by** ChatGPT Desktop (not consumed by it) exposing session metadata.

When any trigger fires → fresh Stage 0 research pass; new phase spec. The won't-list entry carries the trigger list verbatim so future maintainers do not re-audit from scratch.

---

## 6. Doc changes — surface

| File | Change |
|---|---|
| `.claude/shared/architecture.md` (line 62, Layer A "Surface навсегда" bullet) | Rewrite GPT line for current truth: ChatGPT capture is L1 attention only today; per-event surface vendor-blocked; trigger list per §5. |
| `.claude/shared/current-state.md` | Append P7 entry to "Последнее обновление" + "Где мы" sections — Track-6 P7 doc-only phase closed; pointer to whitepaper won't-list entry. |
| `leaf-docs/docs/privacy-security/what-we-dont-capture.md` | New section "AI co-pilot surfaces without per-event API" with ChatGPT Desktop entry + Copilot entry + Apple Intelligence entry. |
| `leaf-docs/docs/reference/changelog.md` | New entry `2026-05-16 HH:MM · Dmitrii — Track-6 P7 закрыт: won't-list AI co-pilot surfaces без per-event API`. |
| `docs/superpowers/specs/2026-05-16-track-6-P7-gpt-cap.md` | This file. |
| `docs/superpowers/specs/2026-05-16-track-6-P7-gpt-cap-research.md` | Already landed (Stage 0). |
| `docs/superpowers/plans/2026-05-16-track-6-P7-gpt-cap.md` | Atomic-per-commit plan. |

**Out of scope (won't land in P7):**

- Code changes (`Packages/LeafCore`, `Packages/LeafCorePrivate`) — none. No collector. No comment in non-existent AX collector code path (generic AX collector not shipped).
- Schema migrations — none. No new tables. No new event_kinds.
- ShareEventTypeKey registry — no additions. P7 ShipEventTypeKey delta from contract §6.2 estimated as **0 entries**, ratified.
- Tests — none. No code touched; nothing to regression-test.

---

## 7. Acceptance criteria

P7 is shipped when:

1. Research doc (`*-gpt-cap-research.md`) committed.
2. Spec (this doc) committed.
3. Plan committed under `docs/superpowers/plans/`.
4. Architecture line 62 rewritten on `feature/track-6-P7-gpt-cap`.
5. `current-state.md` P7 update on the same branch.
6. New whitepaper section landed on `leaf-docs/main`, pushed.
7. Whitepaper changelog entry pushed.
8. `mkdocs serve` in `leaf-docs/` builds green; new section renders; sources hyperlink correctly.
9. `grep -rin "ChatGPT|OpenAI|GPT\b" leaf-docs/docs/privacy-security/` shows consistent terminology — no contradictions with §4 framing.
10. Pre-push diff scan against `gundemtech/leaf` (this repo) per `/pre-push-leaf` checklist — confirm public-safe phrasing, no moat leakage.

**Manual smoke deferred to acceptance gate** (not part of P7 itself):

- A. Live-sqlite sample: `sqlite3 events.sqlite "SELECT bundle_id, COUNT(*) FROM events WHERE bundle_id='com.openai.chat' AND signal_type='attention' GROUP BY bundle_id LIMIT 20"` — confirm only L1 attention rows, no L3+ payload fields.
- B. Privacy walkback: `grep -rin "com.openai\|chatgpt\|openai.chat" Packages/` — confirm zero hits (no inadvertent per-app code path snuck in).
- C. Whitepaper render: visit `leaf-docs.gundem.tech/privacy-security/what-we-dont-capture/` — confirm new section renders, internal links resolve.

These three checks are documented for the Track-6 collective acceptance gate; P7 itself does not block on them because the live-sqlite sample requires interactive key access not authorised under autonomous Claude Code mode (memory standing rule).

---

## 8. Self-review checklist (pre-implementation gate)

- [x] All 5 §-sections from prompt covered (§1 current capture / §2 cannot capture / §3 privacy walkback / §4 won't-list / §5 trigger conditions).
- [x] Public-safe phrasing — no moat leakage. SQL bodies / KDF info strings / Cloudflare worker details / Share Controls preset bundle IDs / exact thresholds — none referenced.
- [x] Quotes / citations for "no API" claims — all 7 entries in §2 table cite either OpenAI help doc, OpenAI developers doc, Apple support, or research doc cross-reference.
- [x] Trigger conditions specific, not vague — 4 named outbound surfaces with action implication per trigger.
- [x] Doc-only phase scope honoured — no code / no migrations / no ShareEventTypeKey / no tests.
- [x] Stage 0 research doc referenced.
- [x] Source list in research doc covers all WebSearch hits used.
