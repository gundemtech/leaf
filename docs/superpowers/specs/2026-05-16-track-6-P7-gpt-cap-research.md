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
| **L6 Content** | Prompt / response / chat history | **Forbidden** | whitepaper won't-list (`privacy-security/what-we-dont-capture.md`) architectural ban. Already covered by `what-we-dont-capture.md` ("AI prompts / responses (даже свои)"). |

**Net:** today Leaf knows you opened ChatGPT Desktop and how long it was frontmost — same posture as any unknown app. No event_kinds discriminate ChatGPT activity from "generic app foreground".

`grep -rni "ChatGPT|com.openai|openai.chat"` across `Packages/LeafCore/Sources` and `Packages/LeafCore/Sources/LeafCorePrivate/Prod` returns **zero** hits — no ChatGPT-specific code path exists.

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
| Local chat history file accessible to sibling process | **Not a path.** Historic note: ChatGPT for Mac stored chat history in `~/Library/Application Support/com.openai.chat/conversations-v3/` in plaintext (2024 disclosure → patched mid-2024 — now encrypted by vendor and treated as vendor-internal store). Even if technically readable, parsing it is a vendor-managed implementation detail subject to change without notice; reading it would also leak L6 content (chat bodies) which whitepaper won't-list (`privacy-security/what-we-dont-capture.md`) forbids. | [Bitdefender disclosure](https://www.bitdefender.com/en-gb/blog/hotforsecurity/chatgpt-mac-app-flaw-left-users-history-exposed) |

### 2.2 What about Codex / Codex CLI / Codex IDE?

These are **separate products**, not ChatGPT Desktop. Codex CLI ships hooks (stable in 2026) — that would land in a separate AI-collab phase (sibling to Claude Code hooks / Cursor hooks / Windsurf hooks), not under "GPT cap". P7 scope is **ChatGPT Desktop only**; Codex hooks belong to a future AI-collab depth track when prioritised.

### 2.3 Anti-pattern check — vendor security posture

OpenAI revoked all macOS app certificates in May 2026 after a supply-chain compromise (Axios library) and forced all users to update. Reading takeaway: vendor is **tightening** desktop-app side-channels, not opening them. Speculative capture paths (e.g. observing accessibility events the app generates, reading vendor-managed local stores, intercepting URL handlers) are anti-patterns — both whitepaper won't-list (`privacy-security/what-we-dont-capture.md`)-forbidden and likely to break across forced updates.

### 2.4 On-Mac probe results (2026-05-16) — unofficial surfaces that exist but should not be pursued

Stage 0 contract §3.1 also requires probing actual bundle / runtime artifacts, not just vendor docs. Probe results on `/Applications/ChatGPT.app` (version `1.2026.118`):

| Surface | Probe | Result | Why we don't pursue |
|---|---|---|---|
| `.sdef` (AppleScript dict) | `find /Applications/ChatGPT.app -name '*.sdef'` | **None published.** Confirms §2.1 vendor-doc verdict. | Vendor-declared absence. |
| App Intents metadata | `find /Applications/ChatGPT.app -name 'Metadata.appintents'` | **None.** No App Intents bundle shipped. | Vendor-declared absence. |
| XPC services / plugins / login items | `find Contents/{XPCServices,PlugIns,Library/LoginItems}` | **None.** No public service surface. | Vendor-declared absence. |
| URL schemes | Info.plist | **3 inbound schemes** (`com.openai.chat`, `openai`, `chatgpt`) — auth0 + general. **Inbound only** (other apps deep-link INTO ChatGPT), not outbound state readback. | Wrong direction. |
| AppleEvents response without sdef | `osascript -e 'tell application "ChatGPT" to get name'` → `"ChatGPT"`; `to count windows` → `error -1708 "doesn't understand"` | App responds to bare `get name` but rejects Standard Suite window/document queries. **No structured observability surface.** | Vendor only responds to no-op. |
| OSLog subsystem stream | `log show --predicate 'subsystem CONTAINS "openai"' --last 30m` | **Zero entries** in 30m window despite heavy real-time use of the app (multiple conversations modified in last 60min). Vendor uses `OS_LOG_DISABLED` or routes only through Apple Crash Reporter. | Not productive — no telemetry stream to subscribe to. |
| `defaults read com.openai.chat` | `defaults read com.openai.chat` | **Readable without TCC.** Exposes `activeUserWorkspaceID` (workspace + user UUID), `SEGVersionKey` (app version), `firstLaunchDate`, `NSWindow Frame *` (window state), `desktopMenuBarBehavior`, login state hints. **A real polling surface.** | **Anti-pattern.** Reading another app's `defaults` plist is technically allowed but: (a) vendor-internal keyspace, no stability contract — keys disappear/rename across updates (2024 plaintext store → encrypted overnight precedent); (b) `activeUserWorkspaceID` is raw vendor PII identifier (whitepaper won't-list (`privacy-security/what-we-dont-capture.md`) prefers anonymized buckets); (c) workspace-switch event_kind would be a thin signal — duplicates app-foreground already captured at L1. Effort/value = L/Marginal. Skip. |
| FSEvents on `~/Library/Application Support/com.openai.chat/conversations-v3-<workspace-uuid>/` | `ls -la` shows 11 encrypted `.data` files (one per active conversation), mtime-stamped to user activity timeline (May 15 11:26, 14:29, 14:34 etc) | **A real FSEvents surface.** Structural metadata observable: conversation count, per-conversation mtime (= "you sent/received message at HH:MM"), new-conversation events, delete-conversation events. Bodies remain encrypted (vendor-managed; file(1) reports opaque `data`). Workspace-keyed dirs make multi-workspace usage observable. | **Anti-pattern, same reasoning.** Reading vendor-internal store layout — even just stat / FSEvents mtime tick, no body parsing — violates whitepaper won't-list (`privacy-security/what-we-dont-capture.md`) "breaks across forced updates" posture. Pre-2024 plaintext precedent makes the directory itself a moving target: vendor can rotate `conversations-v3` → `conversations-v4` or move to Keychain-backed CoreData store next release. Activity rhythm signal also closely tracks app-foreground L1 + L2 intensity we already capture — marginal additional value over what NSWorkspace + CGEventSource already deliver. Effort/value = M/Marginal. Skip. |
| FSEvents on `~/Library/Application Support/com.openai.chat/codex-taskItems-v2-default-<workspace-uuid>/` | Empty dir on this user (no active Codex agent runs locally) | **Per-app surface for Codex agent task lifecycle** — parallel to Claude Code's `~/.claude/projects/<slug>/*.jsonl`. Bundled inside ChatGPT.app on macOS (single binary distribution). | **Out of P7 scope** per contract §11 ("Cursor / Windsurf / Continue dev hooks — separate AI-collab track"). Codex agent is a separate product layer surface; if/when prioritised, lands in a Codex-specific Phase under future AI-collab track. P7 (ChatGPT Desktop = chat product) does not annex it. |
| `~/Library/Containers/com.openai.chat/Data/...` (sandboxed contents) | `ls ~/Library/Containers/com.openai.chat/Data/Library/Application Support/` | **Empty.** App not running sandboxed on this OS / version combination. | N/A. |

**Reconciliation with §2 vendor-doc verdict.** §2.1–2.3 surveyed *official* outbound surfaces and found none. §2.4 probed *unofficial* surfaces and found two real ones: `defaults` polling and conversation-dir FSEvents. The won't-list ratification still holds, but the *reason* is two-fold, not one-fold: (1) vendor offers no official outbound API; (2) the unofficial surfaces that exist are vendor-managed implementation detail — whitepaper won't-list (`privacy-security/what-we-dont-capture.md`) §"anti-patterns" forbids parsing vendor-internal store layouts that have no stability contract. This nuance must surface in the spec / whitepaper won't-list entry — saying only "vendor doesn't offer" leaves a future maintainer wondering why we don't go up one level of hack.

### 2.5 Extended probe pass — deeper bundle / runtime audit (2026-05-16, second pass)

§2.4 checked 9 surfaces; deeper second pass adds 7 more, including the richest unofficial find — `lastAccountSettingsResponse_<workspace>` blob in defaults.

| Surface | Probe | Result | Verdict |
|---|---|---|---|
| `codesign -d --entitlements` | `codesign -d --entitlements - /Applications/ChatGPT.app` | **Rich entitlement set:** App Group `2DC432GLL2.group.com.openai.chat` (dev-team-restricted — only OpenAI's own apps could join), `keychain-access-groups: 2DC432GLL2.com.openai.shared` (shared Keychain with Codex CLI / Atlas / etc.), `automation.apple-events: true` (permits ChatGPT to **send** Apple events outbound — would TCC-prompt against target apps; this is a *separate* macOS subsystem from "Work with Apps" which uses Accessibility API per OpenAI docs §2.1), audio-input + camera + addressbook + calendars + photos-library TCC capabilities, `associated-domains: chat.com / chatgpt.com / platform.openai.com / api.openai.org`, `in-app-payments: merchant.com.openai.chat`. | App Group / Keychain are **dev-team-locked** — only `2DC432GLL2` team apps can join. Not surface for us. Both Apple Events automation entitlement AND "Work with Apps" Accessibility-API mechanism are outbound FROM ChatGPT to other apps (different macOS subsystems, same one-way direction); neither exposes ChatGPT state TO sibling processes. Other entitlements are TCC capabilities — not observation surfaces. Skip. |
| `lsof -p <chatgpt-pid>` | Open files + active sockets | TCP `192.168.1.20:54852 → 104.18.39.85:https` (Cloudflare edge for chat.com / chatgpt.com), UDP to `172.64.155.209` (Cloudflare). One **additional vendor-internal store** disclosed: `~/Library/HTTPStorages/com.openai.chat/httpstorages.sqlite` (NSURLSession-managed HTTP cookies + cache). | Network endpoint observability = generic per-process `Network.framework` watch — not ChatGPT-specific signal, also goes through TLS so no readback. `httpstorages.sqlite` contains auth tokens (forbidden by whitepaper won't-list (`privacy-security/what-we-dont-capture.md`) L6-adjacent) and is vendor-managed. Skip. |
| `~/Library/Saved Application State/com.openai.chat.savedState/` | `ls -la` | **Dir doesn't exist** on this OS/app combo. App not declaring `NSQuitAlwaysKeepsWindows` saved-state participation. | No surface. |
| `~/Library/Preferences/ByHost/com.openai.chat.*.plist` | `ls ~/Library/Preferences/ByHost/` | **None.** App doesn't use ByHost preferences. | No surface. |
| CoreSpotlight donations | `mdfind "kMDItemKind == 'ChatGPT*'"` + `kMDItemAuthors == 'ChatGPT'` + content-change last 7 days | **No CoreSpotlight `CSSearchableItem` donations.** Chat titles **NOT** indexed in system Spotlight. **Positive privacy finding by vendor** — they explicitly do not donate. | No leak; nothing to observe (good). |
| `~/Library/Application Support/com.openai.chat/system-hints-<workspace>/response.data` | mdfind surfaced an additional dir not in §2.4 | Another vendor-internal cache dir per workspace. Encrypted (file(1) = `data`). Likely workspace-level system-prompt / steering cache. | Same vendor-managed anti-pattern. Skip. |
| `lastAccountSettingsResponse_<workspace>` JSON in `defaults read com.openai.chat` | `defaults read com.openai.chat \| grep lastAccount` | **Richest unofficial surface found.** ~3KB JSON blob exposing: (a) `permissions` array — full capability list per workspace (`chatgpt.workspace.model.GPT-5.1-pro.access` / `codex-admin.access` / `hive-knowledge-retrieval.access` / `aura-browser-memories.access` / `canvas-code-execution.access` etc — ~40 entries describing exact plan tier + feature ramps); (b) `betaSettings`: `{projectConnectorScopes, projectSharing, whamAccess, codexRemoteControl, hive}` — beta-enrollment state; (c) `settings`: `{trainingAllowed, lockdownModeEnabled, citronModeEnabled, preciseLocationAllowed, h17180rGmail, h17180rGoogleCalendar}` — user-set privacy / training toggles; (d) `announcements` — onboarding-milestone CFAbsoluteTime timestamps (`hasSeenMemoryOnboarding: 800402358.059` = exact moment user saw onboarding); (e) `eligibleAnnouncements` — long list of feature gates incl. `hasSeenCodexSecurityAnnouncement` / `hasSeenJoinWorkspaceBanner` etc. | **Real surface. Real anti-pattern.** Polling this would yield: workspace switch, plan-tier change, beta enrollment, training-toggle flip, onboarding milestone hit — useful for inferring "user is on Pro / Enterprise" or "user just enabled feature X". But: (a) JSON keys are vendor-internal codenames (`l1239dk1` / `n7jupdNux` / `BurritoNux` / `Citron` / `Aardvark` / `Stardust` / `Mercury`) with zero stability contract; (b) cached blob refreshes on vendor-controlled cadence — not a reliable event stream; (c) entire schema can disappear next release. **The «richer the surface, the deeper the anti-pattern» trap.** Skip with explicit reasoning in spec. |
| Bonjour / mDNS announcements | `dns-sd -B _services._dns-sd._udp local` (3s window via shell-backgrounded kill) | **Probed.** Network services discovered: `_asquic` / `_companion-link` / `_rfb` / `_net-assistant` / `_airplay` / `_raop` / `_yandexio`. **No `_openai` / `_chatgpt` / `_chat` service types announced.** Vendor does not broadcast Bonjour. | No surface. Closes the audit-completeness gap; 16/16 surfaces probed. |

**Extended probe verdict.** 16/16 surfaces audited (9 in §2.4 + 7 in §2.5, including Bonjour now). No change to §2.4 conclusion — won't-list ratification correct, two-fold reasoning still applies. Material new finding: **the richness of unofficial surfaces is greater than initially documented.** `lastAccountSettingsResponse` exposes plan-tier and beta-enrollment, not just workspace switch. This makes the anti-pattern bar **more important** to surface in the whitepaper, not less — a future «richness optimist» reading the won't-list might be tempted by the plan-tier signal specifically.

**Additional finding: CoreSpotlight non-donation is a positive privacy property of the vendor.** OpenAI explicitly does not feed chat titles into system Spotlight index. Contrasts with vendors who do donate (Notes / Mail / Messages). Not actionable for us, but flags that vendor takes title-leak posture seriously on their own — useful framing for the whitepaper.

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
