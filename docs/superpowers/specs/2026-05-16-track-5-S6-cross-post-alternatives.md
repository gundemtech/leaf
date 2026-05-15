# Track 5 / S6 — Alternatives Analysis

> Companion to `2026-05-16-track-5-S6-cross-post.md`. Audit trail for design calls. 17 areas brainstormed; recommendations folded back into main spec.

Format per area: **Question** → **Options A/B/C/...** → **Trade-offs** → **Recommendation + reasoning** → **Effect on spec**.

---

## A1 — OAuth token forwarding architecture

**Q:** How does Edge Function get Slack/Linear OAuth credentials to call APIs on user's behalf?

- **A** Forwarded token in request body. Mac POSTs `{... slack_user_token: "xoxp-..."}` over HTTPS; Edge Function uses once, discards. Zero server-side persistence.
- **B** Server-stored encrypted (new `cross_post_oauth` table). Mac syncs tokens to Supabase, encrypted under workspace teamKey. Edge Function pulls + decrypts (impossible — service_role doesn't have teamKey; would need Mac to send key anyway → equivalent to A).
- **C** Direct Mac → Slack/Linear (skip Edge Function). Mac itself calls third-party APIs; only `cross_post_log` write hits Supabase.
- **D** JWT custom claim carrying token (needs Auth Hook redesign; architecturally awkward).

**Recommendation: A.** Matches contract §9.1 verbatim ("forwarded; never proxied beyond Edge Function memory"). No new schema. Token in Edge Function process memory for ~100ms during the single HTTPS request, then discarded. C is simpler but contract-violating + loses future hook for server-side rate-limit / abuse mitigation. B violates rest-at-storage privacy posture.

**Spec effect:** No change (current already A). **Add** explicit token-logging discipline: comment in Edge Function source + regression test asserting `slack_user_token` / `linear_user_token` substrings never appear in `console.log` captures.

---

## A2 — Slack message format

**Q:** Plain text, Block Kit, or attachment for the cross-post Slack message?

- **A** Plain text `text` parameter only (current spec).
- **B** Block Kit `blocks` only (section + context footer).
- **C** Attachment with `author_name`, `color`, `footer` decoration.
- **D** Hybrid: `text` parameter (fallback for notifications/screen readers) + `blocks` for visual rendering.

**Trade-offs** (informed by Slack research):
- User token (`xoxp-`) posts AS user with their avatar/name natively — `<sender_name>:` prefix in body is redundant.
- Attachments are explicitly legacy since 2017 → reject C.
- Block Kit `context` block renders compact, italicized footer perfect for "Sent via Leaf · &lt;link&gt;".
- Slack docs explicitly say "always provide `text` parameter for fallback (push notifications, screen readers, older clients)" — therefore D > B.

**Recommendation: D (hybrid).** Body shape:
```json
{
  "channel": "C1234567",
  "text": "<message text>",        // notification fallback
  "blocks": [
    {"type": "section", "text": {"type": "mrkdwn", "text": "<message text>"}},
    {"type": "context", "elements": [
      {"type": "mrkdwn", "text": "Sent via Leaf · `<event_kind> <external_ref>`"}
    ]}
  ],
  "unfurl_links": false,
  "unfurl_media": false
}
```
- Drop `<sender_name>:` prefix (Slack shows sender natively from user token).
- Wrap event reference in backticks (suppresses URL auto-unfurl per Slack behavior).
- Context block uses `mrkdwn` for italic footer.
- `unfurl_*: false` prevents giant link cards.

**Spec effect:** **Replace §8.3 `slackBody(...)` String builder with `slackPayload(...)` returning `[String: Any]` JSON object.** Walkback test inspects JSON tree, not flat string. Drop sender prefix.

---

## A3 — Linear OAuth scope granularity

**Q:** Bump to `read,write` (full write) or narrower `read,issues:create`?

- **A** `read,write` — broad. Future cross-post features (comments, labels, projects) work без re-auth.
- **B** `read,issues:create` — narrowest sufficient. Issue creation only; future scope bumps when needed.
- **C** Hybrid: today `issues:create`; v1.1 if comment-on-issue feature lands, additive prompt for `comments:create`.

**Trade-offs:**
- Privacy posture: B > A. Sender grants minimum permission for actual feature.
- UX: B = one bump now, one later if feature lands. A = one bump forever. B costs +1 re-auth in future.
- Blast radius: if Slack/Linear OAuth token leaks, A → attacker can edit/delete issues globally; B → attacker can only create new ones (still bad but bounded).

**Recommendation: B (`read,issues:create`).** S6 closes UC-T5-4 with issue-creation only; per §3 explicitly out of scope: comment-on-existing → Track 6. When Track 6 adds comment cross-post, separate scope-bump UX (precedent: Track 3 D2 GitHub + D3 Slack). Privacy posture stronger.

**Spec effect:** **Change §6.2** from `scope = "read,write"` to `scope = "read,issues:create"`. **Update `LinearScopesService.requiredOptional`** to `["issues:create"]`. **Add carry-over M13:** future `comments:create` scope-bump when comment cross-post lands.

---

## A4 — Linear assignee resolution

**Q:** Sender wants to create Linear issue assigned to recipient (e.g., "Dmitrii"). How does Mac resolve Leaf member → Linear user ID?

- **A** Linear `users(filter: { displayName: { eqIgnoreCase: "Dmitrii" } })` exact match.
- **B** Linear `users(filter: { email: ... })` — but we don't have email on `workspace_members`.
- **C** Fetch viewer's accessible Linear users once + local fuzzy match (Jaro-Winkler ≥ 0.85 or simpler eq → contains fallback).
- **D** Skip resolution — always create unassigned, let sender assign manually in Linear after creation.
- **E** Manual picker fallback — Send sheet shows Linear users dropdown if resolution ambiguous.

**Trade-offs:**
- A fragile: display names not unique in Linear (multiple "Dmitry"s common).
- B impossible without schema change to `workspace_members` (add `email` column — out of S6 scope).
- C robust: handles "Dmitrii" vs "Dima" vs "Dmitry Y." via similarity threshold; cache eliminates per-send network cost.
- D simplest but worst UX (user has to assign in Linear separately after cross-post).
- E best UX but most code (extra dropdown population).

**Recommendation: C with D fallback.** Mac-side `LinearTeamsReader.resolveAssignee(displayName:)` does:
1. Fetch user's accessible Linear users on first call (cached per session, ~50 users typically).
2. Exact match (`displayNameEqIgnoreCase` local pass).
3. If 1 exact match → return that user ID.
4. If 0 exact → fuzzy fallback (Levenshtein distance ≤ 2 OR contains match).
5. If still 0 OR multiple → return nil → Edge Function receives `assigneeID = nil` → issue created unassigned + UI status note "Couldn't resolve Linear assignee".

**E (picker fallback)** deferred to polish post-MVP — simple inline notice in Send sheet "Will create unassigned (couldn't find Dmitrii in Linear)" suffices for MVP.

**Spec effect:** **Replace §8.2 assignee resolution** with this fuzzy-match algorithm. **Add §8.4** sub-section on `LinearUsersResolver` helper. **Update §11 carry-over** with picker fallback (M14).

---

## A5 — Linear idempotency key

**Q:** Use Linear's `IssueCreateInput.id` (UUIDv4 idempotency key) or not?

- **A** Skip — let Linear generate ID. If retry happens after network blip with success-pending state, duplicate issue created.
- **B** Pre-generate UUIDv4 on Mac, pass via `IssueCreateInput.id`. Retry-safe — second attempt is idempotent.

**Recommendation: B.** Even though we're "single attempt no retry" per contract §9.3, transient network failures may cause Mac side to perceive failure when Linear actually succeeded. Future polish that adds retry button (post-MVP) gets free idempotency. Cost: 1 extra `UUID().uuidString` call per cross-post.

**Spec effect:** **Add §7.2 mention** that `IssueCreateInput.id = <UUIDv4>` generated Mac-side and forwarded в Edge Function request body. **Update `LinearCrossPostRequest`** struct to include `requestID: UUID`.

---

## A6 — Edge Function topology

**Q:** Two separate functions (`slack_post` + `linear_create_issue`) or unified (`cross_post_dispatch`)?

- **A** Two separate (current spec; matches existing stubs).
- **B** One unified accepting `{channels: [...]}` array.
- **C** Three — `slack_post`, `linear_create_issue`, + orchestrator `cross_post_batch`.

**Trade-offs:**
- B couples provider logic; one bug affects both paths.
- B fan-out is server-side (slower vs Mac-side `async let`).
- A duplicates ~30 lines auth/CORS boilerplate per function — extractable to `_shared/` Deno module.
- C max flexibility, max code.

**Recommendation: A.** Stubs exist; Mac-side parallelism via `async let` matches existing S4 `triggerAPNsPush` pattern; deploy/test simpler. Boilerplate handled via `leaf-relay/supabase/functions/_shared/cors.ts` + `_auth.ts` (already established in S4).

**Spec effect:** No change.

---

## A7 — `direct_messages.cross_post` JSONB usage

**Q:** Populate JSONB field after success or leave default `'{}'`?

- **A** Unused (current spec); `cross_post_log` table authoritative.
- **B** Edge Function PATCHes JSONB after success — fast-read for "cross-posted?" badge.
- **C** Both — trigger denormalizes log → JSONB at DB level.
- **D** JSONB only — drop `cross_post_log` table.

**Trade-offs:**
- B/C add 2 writes per cross-post; small overhead.
- A requires JOIN to query "was this DM cross-posted?" — but S6 UI surface doesn't need this query (synchronous Edge Function response covers in-flight status; S7 Team feed UI is when this matters).
- D loses ability to record FAILED attempts — `cross_post` JSONB shouldn't bloat with errors.

**Recommendation: A.** YAGNI — denormalization is S7 problem when Team feed needs fast badge rendering. For S6 substrate, log is sufficient.

**Spec effect:** No change. **Update §11 carry-over (M15):** S7 decides whether to add denormalization trigger or app-side PATCH.

---

## A8 — Channel/team picker fetch timing

**Q:** When does Mac fetch user's Slack channels + Linear teams для picker?

- **A** Lazy on Send sheet open + 5min in-memory cache (current).
- **B** Prefetch on OAuth connect + persist to SQLCipher.
- **C** Hybrid: fetch-on-connect to in-memory cache + lazy stale-while-revalidate.
- **D** Lazy + explicit "Refresh" button.

**Trade-offs:**
- A: 1-3 sec spinner on first Send sheet open per session (Slack `conversations.list` for 100+ channels is slow).
- B: requires new SQLCipher tables (8 columns × 2 providers) — out of proportion for v1.
- C: best UX, modest complexity (in-memory only, refresh via collector ticks).
- D: explicit but adds button clutter.

**Recommendation: C.** Fetch on OAuth connect (user already waiting for "fetching workspace" step) → in-memory cache survives Send sheet open/close → 5min stale-while-revalidate via collector tick piggy-back. Cold launch refetches first Send sheet open (acceptable; collector starts fetching in background within ~30s anyway). Channel cache in `SlackChannelsReader` actor private state.

**Spec effect:** **Update §9.3** — `SlackChannelsReader.refreshOnConnect()` called once after OAuth success; `refreshIfStale(maxAge: 5min)` on Send sheet open + periodic via collector tick (`SlackCollector.tick` extended to refresh cache). Same for `LinearTeamsReader`.

---

## A9 — Cross-post failure UX

**Q:** Sheet behavior when one/both cross-posts fail?

- **A** Sheet stays open + per-channel status rows (current).
- **B** Toast + auto-dismiss.
- **C** Feed inline failure card with [Retry].
- **D** Sheet stays open + per-channel + auto-dismiss after 4s regardless.

**Trade-offs:**
- A explicit; user focused on Send action; clear feedback.
- B ephemeral risk; user might miss.
- C requires S7 feed UI; out of scope.
- D compromises — failure visible briefly but auto-dismisses.

**Recommendation: A with explicit timing.** Auto-dismiss only when ALL channels succeed (existing behavior preserved); stay open with [Done] button if any fail. Timing: 1.5s auto-dismiss on full success.

**Spec effect:** **Update §9.2** — explicit timing detail "1.5s auto-dismiss on full-success; manual [Done] on any failure".

---

## A10 — Scope-bump UX surface

**Q:** Where does user learn about missing optional scope?

- **A** Inline в Send sheet only (current).
- **B** Settings → Connections persistent banner.
- **C** Onboarding step.
- **D** Hybrid: Settings dot indicator + Send sheet banner.

**Recommendation: A.** Cross-post is opt-in feature; non-users shouldn't see banners. Send sheet IS the discovery surface (user looking at Channels section is interested). Polish: subtle "Cross-post ready" badge on Connections card after re-auth as confirmation — future, not S6.

**Spec effect:** No change. **Carry-over (M16):** subtle Settings indicator post-re-auth.

---

## A11 — Reader composition

**Q:** 4 separate readers or 1 composite `CrossPostReader`?

- **A** 4 separate (`SlackChannelsReader`, `LinearTeamsReader`, `LinearScopesReader`, existing `SlackScopesReader` with new `.crossPostReady`).
- **B** 1 composite aggregating all.
- **C** 2 per-provider (`SlackCrossPostReader` + `LinearCrossPostReader`).

**Recommendation: A.** Single-responsibility per reader = easier testing + reusability in future surfaces (e.g., S7 Team-wide channels view reuses `SlackChannelsReader`). Composition root already has many readers; +4 isn't blast radius.

**Spec effect:** No change.

---

## A12 — Bi-directional state sync inclusion

**Q:** Wire inbound state (Slack reactions / Linear issue close → DM done_at) in S6 or defer?

- **A** Fully defer to S7/Track 6 (current).
- **B** Outbound metadata in S6 (`[Sent via Leaf — message <id>]` in Linear description, plain footer in Slack), inbound wiring later. **No code change vs A**, but elevate the suffix as documented bi-directional handle.
- **C** Include inbound wiring in S6 — Linear collector parses message UUID; Slack collector matches reactions on cross-posted `ts`.

**Trade-offs:**
- C doubles S6 scope; collectors are touchy (Track 3 D3 had 10 schema-drift bugs); needs UI surface for done_at update.
- B preserves "outbound only" minimal cut while making future inbound trivial.

**Recommendation: B.** Already implicit in current spec; elevate to explicit invariant + add Linear research finding: existing `LinearCollector` polls `viewerActivityIssues` filtered by `viewer.id`, so cross-post-created issue automatically surfaces in sender's own activity feed within ≤5 min next tick. This is "outbound observability for free".

**Spec effect:** **Add §4.5 bi-directional note** highlighting (a) Linear cross-post creates issue, immediately picked up by sender's own LinearCollector next tick; (b) `[Sent via Leaf — message <id>]` suffix is the inbound handle Track 6 collectors use to update done_at.

---

## A13 — Cross-post visibility to recipient

**Q:** Does DM recipient (Dmitrii) see indicator that the message was also cross-posted?

- **A** Recipient blind — no indicator (surprises recipient if they discover Slack post separately).
- **B** Recipient sees subtle "Also posted to Slack" badge — RLS on `cross_post_log` already allows recipient read (current spec §5.1).
- **C** Recipient sees badge + channel/team names (leaks Slack workspace topology).

**Trade-offs:**
- Trust principle: A betrays expectation; if I cross-post your DM publicly, you should know.
- B middle ground — flag without specifics.
- C transparency vs metadata leak.

**Recommendation: B.** RLS already permits recipient read of `cross_post_log`. UI surface for badge = S7 Team feed (out of S6). S6 ships RLS + log; S7 renders badge.

**Spec effect:** No change to S6 schema. **Add §11 carry-over (M17):** S7 surfaces recipient-side "Also posted" indicator in Team feed (channel/team specifics deferred to v1.1 trust-debate).

---

## A14 — Slack rate-limit handling

**Q:** What does Mac do when Slack returns 429?

- **A** Single attempt; log "rate_limited" + ⚠️ in UI (current).
- **B** Honor `Retry-After` header — Edge Function reads header, sleeps, retries once.
- **C** Mac-side throttle queue (1 msg/sec/channel) — prevent 429.
- **D** Capture `Retry-After` value, surface to user UI ("Retry in 4s") + manual [Retry] later.

**Trade-offs (from Slack research):**
- Slack returns 429 with `Retry-After: <seconds>` header on Tier-Special exceed.
- B server-side retry costs latency (user waits Edge Function for retry duration).
- C requires persistent queue on Mac — heavyweight.
- D best UX: explicit, user-decides retry timing.

**Recommendation: D for UI; B carry-over.** Edge Function captures `Retry-After` from 429 response, includes in `SlackCrossPostResult.error_text = "rate_limited: retry_after_<N>s"`. UI surfaces "Slack: rate-limited, retry in N seconds" status row. NO automatic retry в S6 (matches contract §9.3); manual retry button = future polish (M4 from §11).

**Spec effect:** **Update §10.2** — error_text format for rate_limited includes retry-after seconds. **Update Edge Function §7.1** to read header from Slack response.

---

## A15 — Slack `@user` mention conversion

**Q:** If DM body contains `@Dmitrii`, does it become a Slack mention?

- **A** Raw text (current) — `@Dmitrii` stays as literal text in Slack (no notification).
- **B** Resolve via `users.lookupByEmail` or `users.list` matching display_name — convert to `<@U012AB3CD>` form.
- **C** Document limitation: tell user that @-mentions don't work; they should type explicitly.

**Trade-offs:**
- B requires user lookup per send (extra Slack API call) + we don't have email; display_name fuzzy match is fragile.
- A surprises users ("why didn't Dmitrii get the notification?").
- C honest but feels deficient.

**Recommendation: A + C (raw text + document).** Defer mention resolution to v1.1 if user feedback demands. MVP: explicit doc note in Send sheet placeholder text ("Mentions like @Dmitrii won't ping in Slack"). Linear `description` uses GFM markdown — `@mention` natively resolves to Linear users by display name (per research) — so Linear path benefits without code.

**Spec effect:** **Add §9.1 hint text** in body textarea placeholder. **Add carry-over (M18):** Slack @-mention resolution v1.1.

---

## A16 — Sender impersonation defence

**Q:** Edge Function: trust JWT only or verify sender_pubkey matches `direct_messages.sender_pubkey`?

- **A** Trust JWT alone — simpler, faster.
- **B** Verify `direct_messages.sender_pubkey == jwt_pubkey` (current spec) — defence-in-depth.
- **C** + RLS on `direct_messages.SELECT` does this implicitly.

**Recommendation: B.** Single SELECT query covers both (message exists + sender matches). +5ms latency; worth it for explicit gate. Edge Function uses service_role for `cross_post_log` INSERT (bypasses RLS), so app-layer check is the gate.

**Spec effect:** No change.

---

## A17 — Multi-workspace OAuth implication

**Q:** S2 added multi-workspace Leaf. Are Slack/Linear tokens per-Leaf-workspace or per-device?

- Current: `IntegrationRecord` keyed by `provider` only (no workspace_id) → tokens shared across Leaf workspaces.
- **A** Keep shared (current code) — user's Slack token works in any Leaf workspace.
- **B** Per-Leaf-workspace integrations — new column on `integrations` table.

**Trade-offs:**
- A: matches mental model (Slack/Linear is per-user, not per-Leaf-workspace).
- B: enables different Slack workspaces per Leaf workspace, but rare use case + invasive schema change.

**Recommendation: A (no change).** Defer until use case emerges. **Spec note:** S6 cross-post uses the single per-device IntegrationRecord — works identically across all Leaf workspaces user has joined.

**Spec effect:** **Add §4.6 note** clarifying multi-Leaf-workspace semantics.

---

## Summary — design calls affecting spec

| Area | Status | Spec section to update |
|---|---|---|
| A1 | No change | — |
| A2 | **CHANGE** Hybrid `text` + `blocks`; drop sender prefix | §8.3 → `slackPayload()` JSON; §13 walkback tree probe |
| A3 | **CHANGE** `read,issues:create` not `read,write` | §6.2; G5; LinearScopesService.requiredOptional |
| A4 | **CHANGE** Fuzzy resolver (C+D fallback) | §8.2 + new §8.4; carry-over M14 |
| A5 | **ADD** Idempotency key UUIDv4 | §7.2 + §8.2 LinearCrossPostRequest struct |
| A6 | No change | — |
| A7 | No change; carry-over | M15 carry-over |
| A8 | **CHANGE** fetch-on-connect + lazy refresh | §9.3 |
| A9 | **CLARIFY** Timing | §9.2 |
| A10 | No change; carry-over | M16 carry-over |
| A11 | No change | — |
| A12 | **ELEVATE** Bi-directional handle note | §4.5 |
| A13 | No change; carry-over | M17 carry-over |
| A14 | **CHANGE** Capture `Retry-After`; surface in UI | §10.2 + §7.1 |
| A15 | **DOCUMENT** Limitation | §9.1 placeholder + M18 |
| A16 | No change | — |
| A17 | **CLARIFY** Multi-workspace OAuth shared | §4.6 new note |

**Net spec deltas:** 9 sections updated, 5 new carry-overs (M13-M18) added, 1 new helper class (`LinearUsersResolver`), 1 enum extension (`SlackCrossPostResult.retryAfterSeconds`).
