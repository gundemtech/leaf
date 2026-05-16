# Track 6 P7 — GPT Cap Documented · Stage 0 Research

**Stage:** Stage 0 (Deep Research) — companion to upcoming phase spec
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Date:** 2026-05-16
**Author:** Dmitrii + Claude

P7 is the **doc-only** sub-phase of Track 6. The contract (§11) classifies GPT / ChatGPT Desktop as **permanent won't-list** — vendor surface offers no path to per-event capture comparable to Claude Code hooks / Cursor hooks. This research doc maps the realistic ceiling so the won't-list entry in the whitepaper is defensible, not vague.

This doc is the **input to brainstorm (Stage 2)**, not a plan.

---

## 1. Current substrate — what Leaf already captures about ChatGPT Desktop

Source: code inspection on `feature/track-6-P7-gpt-cap` off main.

| Layer | Signal | Captured today? | Mechanism |
|---|---|---|---|
| **L1 Attention** | App active (foreground) | **Yes** | `NSWorkspace.frontmostApplication` + `DidActivateApplicationNotification` — generic. Bundle `com.openai.chat` lands like any other app. |
| **L2 Intensity** | Idle / active within session | **Yes** | `CGEventSourceSecondsSinceLastEventType` — generic. Track-4 S3 intensity bucketing. |
| **L3 Activity verb** | Window title parsing | **No** | Architecture (`.claude/shared/architecture.md` line 56) plans `AXIsProcessTrustedWithOptions` → `AXFocusedWindow` → `AXTitle`. No generic AX collector shipped yet in `Packages/LeafCore/Sources/LeafCore/OS/` (Track-4 S2 ships only **per-app AppleScript adapters** for Xcode / Safari / Chrome / Arc / Zoom / Notes / Mail / Music / etc — no ChatGPT adapter exists). |
| **L4 Folder / module** | — | **N/A** | ChatGPT Desktop has no project / folder concept exposed to OS. |
| **L5 File** | — | **N/A** | Same. |
| **L6 Content** | Prompt / response / chat history | **Forbidden** | ADR-010 architectural ban. Already covered by `what-we-dont-capture.md` ("AI prompts / responses (даже свои)"). |

**Net:** today Leaf knows you opened ChatGPT Desktop and how long it was frontmost — same posture as any unknown app. No event_kinds discriminate ChatGPT activity from "generic app foreground".

`grep -rni "ChatGPT|com.openai|openai.chat"` across `Packages/LeafCore` and `Packages/LeafCorePrivate/Prod` returns **zero** hits — no ChatGPT-specific code path exists.

---

## 2. Vendor ceiling — what OpenAI exposes from ChatGPT Desktop in 2026 Q2

### 2.1 Official outbound surfaces — checked

| Surface | Status (2026-05-16) | Citation |
|---|---|---|
| Public REST API for "my sessions / my messages" (sibling-process consumption) | **Not offered.** OpenAI's REST is for *sending* prompts to the API (`api.openai.com`), not introspecting the desktop client's own session/history. Account-level export via "Settings → Data Controls → Export" is **email-delivered ZIP**, 24h download link, server-side — no local file watch path. | [OpenAI: Export ChatGPT history](https://help.openai.com/en/articles/7260999-how-do-i-export-my-chatgpt-history-and-data) |
| AppleScript dictionary (`.sdef`) | **Not published.** No vendor docs / OSS reconnaissance / community forum thread surfacing a `com.openai.chat` scripting dictionary. Search Editor → Library → ChatGPT Desktop shows no scripting support. | search-negative; no positive citation exists. |
| App Intents (iOS/macOS) for third-party introspection | **Not published.** ChatGPT-Apple Intelligence integration runs *inbound* (Siri / writing tools route prompts INTO ChatGPT via Apple's privacy layer). Sibling apps cannot read ChatGPT state through App Intents. | [Apple: Use ChatGPT with Apple Intelligence on Mac](https://support.apple.com/guide/mac-help/use-chatgpt-with-apple-intelligence-mchlfc5cf131/mac) |
| MCP server exposed by ChatGPT Desktop | **Not offered.** ChatGPT's MCP story is *inbound consumer* — ChatGPT integrates third-party MCP servers via the Apps SDK / Connect-from-ChatGPT flow. There is no MCP server *served by* ChatGPT Desktop that exposes its own sessions / messages outbound. | [OpenAI: Building MCP servers for ChatGPT Apps](https://developers.openai.com/api/docs/mcp), [OpenAI: Apps SDK Connect from ChatGPT](https://developers.openai.com/apps-sdk/deploy/connect-chatgpt) |
| "Work with Apps" reverse-channel | **One-directional, inbound only.** Feature reads OTHER apps' AX trees (Xcode / VS Code / Terminal / iTerm) and feeds selection into ChatGPT prompt. It does **not** expose ChatGPT state outward to other observers. Implementation explicitly uses macOS Accessibility API to read selected text from supported editors. | [OpenAI: Work with Apps on macOS](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos), [TechCrunch coverage](https://techcrunch.com/2024/11/14/chatgpt-can-now-read-some-of-your-macs-desktop-apps/) |
| Hook / extension SDK for ChatGPT Desktop | **Not offered.** The "developer mode" referenced in Codex changelog applies to the **Codex CLI / IDE-style** product, not ChatGPT Desktop. Codex hooks live in `config.toml` / `requirements.toml` *inside Codex* — not a surface exposed to sibling macOS processes. | [OpenAI Developers: Codex changelog](https://developers.openai.com/codex/changelog) |
| Local chat history file accessible to sibling process | **Not a path.** Historic note: ChatGPT for Mac stored chat history in `~/Library/Application Support/com.openai.chat/conversations-v3/` in plaintext (2024 disclosure → patched mid-2024 — now encrypted by vendor and treated as vendor-internal store). Even if technically readable, parsing it is a vendor-managed implementation detail subject to change without notice; reading it would also leak L6 content (chat bodies) which ADR-010 forbids. | [Bitdefender disclosure](https://www.bitdefender.com/en-gb/blog/hotforsecurity/chatgpt-mac-app-flaw-left-users-history-exposed) |

### 2.2 What about Codex / Codex CLI / Codex IDE?

These are **separate products**, not ChatGPT Desktop. Codex CLI ships hooks (stable in 2026) — that would land in a separate AI-collab phase (sibling to Claude Code hooks / Cursor hooks / Windsurf hooks), not under "GPT cap". P7 scope is **ChatGPT Desktop only**; Codex hooks belong to a future AI-collab depth track when prioritised.

### 2.3 Anti-pattern check — vendor security posture

OpenAI revoked all macOS app certificates in May 2026 after a supply-chain compromise (Axios library) and forced all users to update. Reading takeaway: vendor is **tightening** desktop-app side-channels, not opening them. Speculative capture paths (e.g. observing accessibility events the app generates, reading vendor-managed local stores, intercepting URL handlers) are anti-patterns — both ADR-010-forbidden and likely to break across forced updates.

---

## 3. Privacy walkback — AX window title leak (if/when generic AX collector lands)

`ChatGPT Desktop` window title pattern: `"<thread title> - ChatGPT"` (where `<thread title>` is the user's chat topic, often auto-generated from the first user prompt — e.g. `"Refactor authentication flow"`, `"Why is my SwiftUI list lagging"`, `"Help debugging Linear OAuth"`).

**Implication.** If Leaf ever ships the architecture-documented generic AX window-title collector (line 56 of `architecture.md`, currently planned but not shipped), ChatGPT Desktop's window title is a **content leak** — it encodes user intent / chat topic, which is functionally close to L6 content even though structurally it's L3 metadata. Same hazard exists for browser tab titles already (handled via Track-6 P3 per-domain allow-list; Safari/Chrome adapters lift title only for allow-listed domains).

**Recommendation (decision for P7, not for shipping in P7).** When the generic AX window-title collector lands (future phase, not P7), `com.openai.chat` is on the **default-OFF redaction list** alongside Slack DM windows / 1Password / banking apps. Same posture as Track-6 P3 browser per-domain allow-list pattern — content-bearing window title is opt-in only.

This is a *policy commitment*, not code. The actual code change happens when generic AX shipping is scoped. P7 commits the policy.

---

## 4. Ceiling-vs-effort summary

| Signal | Mechanism | Effort | Value | Verdict |
|---|---|---|---|---|
| App foreground / duration | NSWorkspace (existing) | S (no-op) | Critical | **Already captured** generically. |
| Idle / intensity during session | CGEventSource (existing) | S (no-op) | Critical | **Already captured** generically. |
| Per-message / per-tool / per-session telemetry | None — vendor offers zero outbound API | — | Strong (would be) | **Vendor-blocked. Permanent won't-list.** |
| Chat thread title (via AX) | Hypothetical generic AX collector | M (when collector lands) | Strong but **privacy hot spot** | Default-OFF when collector ships; not in P7 scope. |
| Apple Intelligence / Siri inbound prompts that route to ChatGPT | None — Apple Intelligence framework is private to system, third-party readback not exposed | — | Strong | **Apple-blocked. Permanent won't-list.** |
| Local conversation file watch | `~/Library/Application Support/com.openai.chat/conversations-v3/` | L | Critical (would be) | **Forbidden** — would yield L6 content; also vendor-managed implementation detail, breaks across updates. |

Net for P7: **no signals to land.** P7 documents that the ceiling has been audited and ratifies the permanent won't-list entry.

---

## 5. Trigger conditions for re-evaluation

The won't-list entry is not a forever vow — vendor surfaces evolve. Re-open this phase when **any one** of:

1. OpenAI ships an outbound REST API for "my ChatGPT Desktop session / message stream" consumable by sibling processes (parallel to Claude Code's hook stream).
2. OpenAI publishes an AppleScript dictionary (`.sdef`) for `com.openai.chat`. Mirror Track-4 S2 per-app adapter pattern: add `ProdChatGPTAdapter` exposing only allow-listed fields (current chat title, foreground state) — never message content.
3. Apple exposes App Intents introspection where ChatGPT Desktop registers actions readable by sibling processes (would parallel future Apple Intelligence aggregator track — separate from P7).
4. OpenAI ships an MCP server **served by** ChatGPT Desktop (not consumed by it) that exposes session metadata. (Architecture mirror: Claude Code's hook stream sits in the same conceptual slot.)

When any trigger fires → reopen Track-6 follow-up phase with a fresh Stage 0 research pass. The won't-list entry in the whitepaper carries the trigger list verbatim so future maintainers don't re-litigate the audit from scratch.

---

## 6. Questions for the user (pre-brainstorm)

P7 is doc-only, so questions are scoped tight:

1. **Won't-list placement.** Whitepaper `privacy-security/what-we-dont-capture.md` currently has Surveillance-techniques / Bossware / Activity-connectors / Default-deny-list / Under-PMF sections. New entry naturally lands as a sixth section "**AI co-pilot surfaces without per-event API**" or folds into Surveillance-techniques. **Recommendation:** new sixth section — it's a different *kind* of won't-list (vendor-blocked, not policy-blocked), and future ChatGPT-style surfaces will append here rather than confuse Surveillance-techniques.

2. **AX window-title policy commitment scope.** §3 of this doc proposes a policy commitment ("when generic AX collector lands, `com.openai.chat` is default-OFF"). **Recommendation:** include in P7 spec as a forward-looking policy reservation, not a code change. Keeps decision history captured before the generic AX collector phase exists.

3. **Architecture line 62 update.** Currently reads: `ChatGPT Desktop ("Work with Apps" односторонний). Degrade: AX window title + file inference.` This was written when AX was expected to ship soon. **Recommendation:** rewrite to reflect current truth — AX collector not yet shipped; ChatGPT capture is **L1 attention only**; per-event surface vendor-blocked; trigger list per §5.

4. **Stage 0 live-sqlite verification skip.** Contract §3 Stage 0 instructs sampling existing DB to confirm what AX has actually captured for `com.openai.chat`. Live sample skipped on this branch because key retrieval from Keychain isn't authorised in autonomous mode (memory-encoded standing rule). Verification deferred to acceptance gate, where author can dump rows interactively. **Confirm acceptable.**

---

## Sources

- [OpenAI Help: Work with Apps on macOS](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos)
- [OpenAI Help: Export ChatGPT history](https://help.openai.com/en/articles/7260999-how-do-i-export-my-chatgpt-history-and-data)
- [OpenAI Developers: Building MCP servers for ChatGPT Apps](https://developers.openai.com/api/docs/mcp)
- [OpenAI Developers: Apps SDK — Connect from ChatGPT](https://developers.openai.com/apps-sdk/deploy/connect-chatgpt)
- [OpenAI Developers: Codex changelog](https://developers.openai.com/codex/changelog)
- [Apple Support: Use ChatGPT with Apple Intelligence on Mac](https://support.apple.com/guide/mac-help/use-chatgpt-with-apple-intelligence-mchlfc5cf131/mac)
- [TechCrunch: ChatGPT can now read some of your Mac's desktop apps](https://techcrunch.com/2024/11/14/chatgpt-can-now-read-some-of-your-macs-desktop-apps/)
- [Bitdefender: ChatGPT for Mac app flaw left users' chat history exposed](https://www.bitdefender.com/en-gb/blog/hotforsecurity/chatgpt-mac-app-flaw-left-users-history-exposed)
- [9to5Mac: Security breach means you must update the ChatGPT Mac app](https://9to5mac.com/2026/05/14/psa-a-security-breach-means-you-must-update-the-chatgpt-mac-app/)
