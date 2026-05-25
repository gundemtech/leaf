# Security Hardening — Master Spec

**Date:** 2026-05-25
**Type:** Master spec (cross-repo, multi-phase)
**Status:** Draft → user review
**Owners:** core team (lead + reviewer rotation per usual cadence)
**Branches:** `feature/security-hardening-2026-05-25` in `leaf`, `leaf-relay`, `leaf-internal`, `leaf-web`

---

## 0. Goal

Land a comprehensive set of security and pre-open-source hardening fixes derived from the 2026-05-25 4-repo security audit. Ship in 8 self-contained phases, each runnable as one Claude Code session per `conventions.md` § "Одна phase = одна сессия".

**Definition of done:**
- All HIGH findings from the audit closed (8 of 8).
- All MEDIUM findings from the audit either closed or tracked as accepted carry-overs.
- `gundemtech/leaf` ready for full open-source promotion (no founder PII in source, no precise thresholds, automated leak guard in CI).
- Moat crypto invariants verified end-to-end with explicit test coverage.
- Audit re-run after Phase 8 shows zero HIGH/CRITICAL regressions.

**Non-goals (out of scope — separate track):**
- Supabase RLS policy audit (requires Supabase console + DB inspection; new track).
- Cloudflare Worker `/api/contact` audit (lives outside this repo set).
- Cloudflare Worker `/changelog/latest.json` source/storage audit (Telegram approval flow lives outside).
- Multi-workspace race-conditions tracked elsewhere (ISSUE-1 / NIT-4 in current-state.md).
- Switch from Supabase to alternative backend (whitepaper-level decision).

---

## 1. Threat model (recap)

We protect against four broad adversary classes:

1. **Open-source readers (post-OSS)** of `gundemtech/leaf` who try to learn implementation-moat details (tuned thresholds, SQL bodies, byte layouts, founder identities) from the public repo.
2. **Untrusted relay** (`oauth.gundem.tech`, Cloudflare Worker) — must not be a confidentiality side-channel; relay sees only ciphertext.
3. **Public-internet attackers** hitting `leaf.gundem.tech`, `leaf-internal.gundem.tech`, the relay, or the marketing site — XSS, DoS, recon.
4. **Local attackers / stolen device** — protected by macOS FileVault + Keychain `AfterFirstUnlock` + SQLCipher.

The audit assumes adversary classes 1–3 are active. Class 4 is mitigated by existing architecture (ADR-013, ADR-017).

---

## 2. Architecture overview

Four repositories, each its own git origin:

| Repo | Visibility | Role |
|---|---|---|
| `gundemtech/leaf` | Public | macOS app (Swift), `LeafCore` package, `LeafAgent`, `LeafMCP`, on-device crypto, OAuth clients, MCP server. |
| `gundemtech/leaf-relay` | Private | Cloudflare Worker on `oauth.gundem.tech` — OAuth callback proxy + ephemeral invite/key-rotation KV mailboxes. |
| `gundemtech/leaf-internal` | Private | Python + MkDocs dashboard on `leaf-internal.gundem.tech` (basic-auth), AWS SSM vault helper, mac-hooks. |
| `gundemtech/leaf-web` | Public | Astro marketing site `leaf.gundem.tech`, signup / dashboard / changelog. |

**Moat:** `leaf/Packages/LeafCore/Sources/LeafCorePrivate/` is gitignored — Prod codecs, Prod configs (SQLCipher PRAGMA, salt management), Insights SQL bodies live here. Tests in `LeafCorePrivateTests/` are also gitignored.

Each repo is a separate git worktree. Phases may touch one or several repos; branch name is identical across repos for traceability.

---

## 3. Branching + workflow

- One branch per repo, identical name: `feature/security-hardening-2026-05-25`.
- Each phase is one session; on phase close, push branch, do NOT merge to `main` yet — collective merge after Phase 8 acceptance gate.
- Per `conventions.md`, every phase runs the 8-stage flow: Discovery → Brainstorm → Spec write → Plan → Implementation (TDD) → Independent review → Verification → Ship.
- Phase plans live in `leaf/docs/superpowers/plans/2026-05-25-security-hardening-phase-N.md` (gitignored — full implementation including moat-touching steps). Plans for non-`leaf` repos also live in `leaf/.../plans/` for single index of truth.
- Each phase plan is self-contained and references this master spec.
- `/pre-push-leaf` mandatory before every push to `gundemtech/leaf`.

---

## 4. Phase map (TL;DR)

| # | Title | Repos | Why this slot |
|---|---|---|---|
| 1 | OSS readiness sweep | `leaf` only | Blocks public open-source promotion; cheapest unblock. |
| 2 | Live exploitable critical fixes | `leaf`, `leaf-internal`, `leaf-web` | Three confirmed HIGH findings with realistic attack paths. |
| 3 | leaf-relay hardening | `leaf-relay` | Public-internet attack surface; small repo. Drain starvation, placeholder ID, ACK asymmetry, rate-limit, strict Content-Type, byte-cap correctness, Referrer-Policy. |
| 4 | Secrets hygiene & admin tasks | `leaf-internal` + AWS console | One-shot ops work (key rotation, doc scrubs, VPS env-file perms). |
| 5 | leaf Swift defence-in-depth | `leaf` only | Crypto + network improvements: browser URL fragment strip, X25519 low-order rejection, refresh-token in Keychain, ephemeral OAuth `URLSession`, anon-key header (if feasible), backup auto-purge, revoke-invite wire, OAuth port research + decision. |
| 6 | Moat crypto audit | `leaf` + moat | Verifies 5 invariants in gitignored `LeafCorePrivate/Prod/Crypto/`. Plan body is gitignored. |
| 7 | leaf-web hardening | `leaf-web` only | Security headers, SRI, dependency bump (`devalue`), `frozen-lockfile`, account-delete typed confirm. |
| 8 | leaf-internal + VPS hardening | `leaf-internal` + VPS shell | Vault race + no-eval, FastAPI docs, nginx vhost headers, access-log scrubs, leak-guard port from Phase 1, subprocess hygiene sweep. |

Final step (Phase 8 close): re-run audit; collective merge if clean.

---

## 5. Cross-cutting principles

- **TDD.** Every fix lands with a failing test first.
- **No fix without verification.** Each phase ends with `superpowers:verification-before-completion` — manual smoke on a real OS plus all relevant test suites green.
- **DRY guards.** Where a leak guard is added (Phase 1 CI), it becomes the canonical enforcement; subsequent phases reuse it rather than duplicate string-match logic.
- **Public-safe edits.** Anything touching public `leaf` repo runs `/pre-push-leaf` mentally; CI guard (Phase 1) automates the mechanical part.
- **Carry-overs are explicit.** If a phase intentionally defers a finding, the deferred item lands in `current-state.md` "Open tensions" with rationale.

---

## 6. Phase 1 — OSS readiness sweep

**Repo:** `leaf` only.
**Branch:** `feature/security-hardening-2026-05-25`.
**Estimated session:** 2–3 hours.

### Scope

1. Replace team-member first names that leaked into tracked Swift preview/test files with neutral placeholders, consistent with the existing precedent at commit `122e5f3a`. The exact strings and their locations are enumerated in the private audit artefact (see §18); the plan resolves them via `git grep` against the audit's pattern list. Touched files include (verify against the audit):
   - `Leaf/Views/Tokens/Components/LeafMessageCardPreview.swift`.
   - `Leaf/Views/Window/Settings/NotificationsSettingsSection.swift`.
2. Replace full real-name fixture strings in test files with synthetic test names. Touched files:
   - `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift`.
   - `Packages/LeafCore/Tests/LeafCoreTests/TeamNRowComposerTests.swift`.
   - `Packages/LeafCore/Tests/LeafCoreTests/ZoomMeetingTopicRedactorProtocolTests.swift`.
3. Redact tuned-threshold numerics that leaked into public source/comments. Touched files:
   - `.claude/shared/architecture.md` — replace exact SQLCipher PRAGMA values with reference to the moat config file under `LeafCorePrivate/Prod/Configs/`.
   - `Leaf/Models/UpdaterController.swift` — strip exact numeric from doc comment, refer to moat.
4. Redact the real-looking APNs Team ID that appears verbatim in a public spec:
   - `docs/superpowers/specs/2026-05-14-track-5-S4-direct-messages.md` — replace the 10-char identifier with `<APNS_TEAM_ID>`.
5. Add a CI workflow + git `pre-push` hook that fails any push containing forbidden patterns. The workflow runs the same string-match list `/pre-push-leaf` enforces today; failure prints the offending line + remediation note. The hook is a thin wrapper around the same script so local pre-push catches the same patterns. Pattern categories include team-member first names, tuned numerics, the moat directory's source code, identifier formats matching cloud account IDs and IAM access keys, and any string explicitly listed in the audit's "forbidden patterns" table.
6. Decide commit-email rewrite policy for git history. Two co-author identities appear in past commits; the audit flags this for a deliberate decision. Phase plan documents the chosen option (rewrite via `git-filter-repo` before public OSS promotion, or leave). If rewrite is chosen, Phase 1 produces a one-shot script that runs against a fresh mirror clone; rewrite is not executed in this branch.

### Files created

- `.github/workflows/leak-guard.yml` — runs the leak-pattern matcher on PRs and pushes to `main`.
- `scripts/leak-guard.sh` — single source of truth for the pattern list; called both by CI and by a new git `pre-push` hook installed via `justfile` recipe.
- `docs/superpowers/decisions/2026-05-25-oss-promotion-decisions.md` — recorded decision on the email-rewrite question, with the rewrite script if applicable.

### Acceptance criteria

- `scripts/leak-guard.sh --report` returns zero matches across the tracked tree (the script encapsulates the forbidden-pattern set so this spec does not list them inline).
- `scripts/leak-guard.sh` exits non-zero when run against a synthetic test fixture containing each forbidden pattern (one failing case per pattern category).
- `.github/workflows/leak-guard.yml` runs on PRs and pushes to `main`; one merged dry-run PR confirms the workflow triggers and gates.
- Decision doc committed with explicit "rewrite" or "do not rewrite" choice and rationale for the email-rewrite question.
- `xcodebuild -scheme Leaf -destination 'platform=macOS' build test` green, all SPM tests green (no test-name regressions from fixture renames).

### References

- Audit findings: OSS-readiness items 1–5 in the private audit artefact (§18).
- Existing checklist: `.claude/commands/pre-push-leaf.md` (already enumerates the pattern set).
- Prior precedent: the existing UI placeholder fix landed during the alpha series (referenced via commit hash in the audit artefact; not repeated here for the same public-safe reason).

---

## 7. Phase 2 — Live exploitable critical fixes

**Repos:** `leaf`, `leaf-internal`, `leaf-web` (three branches, identical name).
**Estimated session:** 4–5 hours (largest phase; could optionally split per-repo if energy budget tight).

### Scope

1. **`leaf` — `uuidStringToRawBytes` silent zero-key fallback.** Files:
   - `Packages/LeafCore/Sources/LeafCore/Team/TeamEventBroadcastService.swift`.
   - `Packages/LeafCore/Sources/LeafCore/Team/DirectMessageService.swift`.
   Behaviour change: on `UUID(uuidString:) == nil`, throw `LeafError.invalidPayload` instead of returning 16 zero bytes. Add tests that feed a malformed UUID and assert throw.
2. **`leaf-internal` — HTML injection via `drifts_html | safe`.** File:
   - `scripts/render_internal.py:104-119`.
   Move drift HTML construction into a Jinja sub-template (autoescape on) instead of f-string concat. Add a test that renders a drift with `branch = '<img src=x onerror=alert(1)>'` and asserts the output is HTML-escaped.
3. **`leaf-web` — stored XSS via `innerHTML` on changelog feed.** Files:
   - `src/pages/changelog/index.astro:138-148`.
   - `src/pages/feed.xml.ts:46` (RSS parity).
   Sanitize `content_html` before render: pass through DOMPurify in client JS (browser-side) and an equivalent server-side sanitizer for the RSS generator. Add tests that render a malicious `<script>alert(1)</script>` and assert it's stripped.
4. **Verification.** All three fixes covered by tests; each repo's test suite green; manual smoke: open the dashboard with a deliberately-named test branch `feature/<img src=x>`, open `/changelog` with a mocked feed containing `<script>`, send a team event with a malformed active-key UUID via test seam.

### Files created/modified

- `leaf`: tests in `Packages/LeafCore/Tests/LeafCoreTests/Team/{TeamEventBroadcastServiceTests.swift, DirectMessageServiceTests.swift}` extended (or created if absent).
- `leaf-internal`: `scripts/templates/_drift.md.j2` (new); `scripts/render_internal.py` (modified, drop f-string); `scripts/tests/test_render_drift.py` (new).
- `leaf-web`: `src/scripts/sanitize-html.ts` (new, wraps DOMPurify); `src/pages/changelog/index.astro` (modified, replace `innerHTML` with sanitized variant); `src/pages/feed.xml.ts` (modified); `tests/changelog-sanitize.test.ts` (new).

### Acceptance criteria

- `leaf`: new tests exist for malformed-UUID path in both services; both assert `throws`; full SPM suite green; no behavioural regression in correct-UUID happy path.
- `leaf-internal`: synthetic injection test passes; `pytest scripts/tests/` green; render diff inspected for visual regression.
- `leaf-web`: sanitization unit test passes for at least the OWASP XSS filter evasion cheat sheet top-10 vectors; build produces working `/changelog` page; manual visual diff on the deployed preview.

### References

- Audit findings: HIGH H1 (uuidStringToRawBytes silent zero), HIGH H-1 (drift HTML injection), HIGH H-W1 (changelog XSS).

---

## 8. Phase 3 — leaf-relay hardening

**Repo:** `leaf-relay` only.
**Estimated session:** 2–3 hours.

### Scope

1. **Drain-starvation defence.** Change KV key composition for `KEY_ROTATIONS` so that lex-order matches insertion-order (prefix with a monotonic timestamp encoded as fixed-width big-endian hex). Update writer + reader + tests. Add a per-peer pending-count cap on POST (server-side `KV.list` count before PUT; return 429 once at cap).
2. **Replace `PLACEHOLDER_KEY_ROTATIONS_*` IDs in `wrangler.toml`.** If real production IDs already exist, restore them. If the namespace was never provisioned, provision it (one-shot `wrangler kv:namespace create KEY_ROTATIONS` + preview variant) and commit real IDs. Add `predeploy` npm script that greps `PLACEHOLDER` and exits non-zero.
3. **Symmetric DELETE/ACK responses.** Bring `handleKeyRotationAck` (`src/key-rotation.ts:293-308`) in line with `handleInviteDelete` (`src/invite.ts:71-76`) — log and fall through to 204 instead of returning 500 on KV.delete failure.
4. **Per-IP abuse rate limit on POST endpoints.** Both `POST /v1/invite` and `POST /v1/key-rotation` are anonymous; today the only ceiling is the Worker CPU + KV PUT quota. Add a Cloudflare Rate Limiting binding (or equivalent WAF rule) keyed on client IP + path, with thresholds aligned to legitimate usage (a couple of writes per minute per IP suffices for the real client). Return `429 Too Many Requests` with `Retry-After` once at cap.
5. **Strict Content-Type match.** Replace the `startsWith("application/json")` checks (`src/invite.ts:111-114`, `src/key-rotation.ts:105-108`) with an exact match against `application/json` and the parameterised form `application/json;...`. Drops the accidental acceptance of `application/json-patch+json` and the like; tests pin both the acceptance and rejection paths.
6. **UTF-8 byte counting for size caps.** Replace `text.length` (UTF-16 code units) in size-cap branches (`src/invite.ts:117`, `src/key-rotation.ts:111`) with `new TextEncoder().encode(text).byteLength` so `MAX_RAW_BODY_BYTES` actually measures bytes. Rename the constant if the chosen unit is characters; tests pin the behaviour.
7. **`Referrer-Policy: no-referrer`** added to `NO_STORE_HEADERS` (defense-in-depth against referer leakage on the 302).
8. **Test gaps from audit** (any subset realistic in one session): drain-starvation regression, concurrent ACK TOCTOU, CRLF in OAuth `code` / `state`, `Content-Type` strict-match acceptance and rejection, oversize body rejection at byte boundary, `OPTIONS` / `HEAD` / `TRACE` fall-through, `wrangler.toml` placeholder CI guard.

### Carry-overs (explicit accept)

- **Peer-mailbox drain authorization** (audit MEDIUM "Anyone can drain anyone's rotation mailbox"). Adding pull-side auth requires a protocol change (signed URL or handshake) that affects every relay client. Confidentiality is preserved end-to-end by AES-GCM; the leak vector is metadata (timing / frequency / blob size). **Decision:** accept the metadata exposure for MVP, schedule architectural design in the dedicated "backend security audit" track. Phase 3 plan records this carry-over in `current-state.md` "Open tensions".

### Acceptance criteria

- Drain-starvation regression test exists and passes; lex-low-key flood no longer hides the legitimate rotation from `KV.list(limit=N)`.
- `wrangler deploy --dry-run` succeeds; predeploy guard fails when re-introducing `PLACEHOLDER`.
- ACK endpoint returns 204 on both happy path and KV-delete-failure path; no 500.
- Rate-limit binding in place; integration test from a single client IP confirms 429 above threshold and 204/302 below.
- Strict Content-Type tests cover at minimum: `application/json` (accept), `application/json; charset=utf-8` (accept), `application/json-patch+json` (reject), `text/plain` (reject).
- Byte-cap test: request body of exactly `MAX_RAW_BODY_BYTES` UTF-8 bytes accepted; `+1` rejected.
- `npm test` green; `npm audit --omit=dev` clean.

### References

- Audit findings: HIGH (drain starvation), HIGH (placeholder ID), HIGH (asymmetric 500), MEDIUM (rate-limit absence), MEDIUM (Content-Type laxness), MEDIUM (UTF-16 vs UTF-8 length), MEDIUM (Referrer-Policy missing), MEDIUM (peer-mailbox drain auth — deferred carry-over).

---

## 9. Phase 4 — Secrets hygiene & admin tasks

**Repos:** `leaf-internal` only (docs scrubs); plus AWS console.
**Estimated session:** 1–2 hours.

### Scope

1. **Rotate the legacy IAM developer access key** referenced in `leaf-internal/DIMA_VAULT_SETUP.md` (three occurrences). Sequence:
   - Create new access key via `aws iam create-access-key --user-name <dev>` from a clean shell.
   - Distribute new key id + secret out-of-band (Signal / 1Password) — never commit.
   - Confirm partner stored and rotated locally.
   - Delete old access key via `aws iam delete-access-key`.
   - Replace the three doc occurrences with placeholders (`<your-access-key-id>`).
2. **Scrub AWS account number** from committed docs (`leaf-internal/CLAUDE.md`, `DIMA_VAULT_SETUP.md`, `VPS_AWS_VAULT_SETUP.md`). Replace with `<aws-account-id>` and add a one-liner explaining where to find the canonical value (the team's password manager).
3. **Scrub VPS IP** from `VPS_HANDOFF.md` + `VPS_V2_HANDOFF.md`. Replace with the DNS name; explain that operators look up the IP via `dig` when needed.
4. **Document `leaf-presence.env` permissions invariant** in `VPS_AWS_VAULT_SETUP.md` (chmod 600, owner = service user, group = service group). Add a small `deploy/check-env-perms.sh` that the systemd unit's `ExecStartPre` calls to fail-fast.

### Acceptance criteria

- `aws iam list-access-keys --user-name <dev>` shows only the new key.
- `grep -r 'AKIA' .` in `leaf-internal` returns zero hits.
- `grep -rE '\\b53657325[0-9]{4}\\b' .` (or equivalent for the account-number pattern) returns zero hits.
- `grep -rE '\\b82\\.38\\.4\\.144\\b' .` returns zero hits.
- VPS-side: `stat -c '%a' /home/<svc>/secrets/leaf-presence.env` returns `600`; `ExecStartPre` runs new perms check; systemd unit cycles green.

### References

- Audit findings: CRITICAL C-1 (AKID), CRITICAL C-2 (account-id), HIGH (VPS IP), MEDIUM (env-file perms).

---

## 10. Phase 5 — leaf Swift defence-in-depth

**Repo:** `leaf` only.
**Estimated session:** 4–5 hours.

### Scope

1. **Browser URL fragment + sensitive-query strip.** File: `Packages/LeafCore/Sources/LeafCore/Insights/AttentionEmissionPlanner.swift`. Replace string-prefix-truncate `sanitizeURL` with a `URLComponents`-based sanitizer that always drops `fragment` and applies a host-keyed allowlist for query keys. Add tests covering: OAuth implicit-flow fragment `#access_token=…`, magic-link reset paths, JWT-in-fragment, normal Google-search query (kept), unknown-host query (stripped).
2. **X25519 low-order rejection.** File: `Packages/LeafCore/Sources/LeafCore/Crypto/KeyAgreement.swift`. After `sharedSecretFromKeyAgreement`, assert raw shared-secret bytes are not all zero (and ideally not in the published Curve25519 small-subgroup blacklist). Constant-time check. Failure → throw a dedicated error.
3. **`SupabaseSessionStore` refresh-token relocation.** File: `Packages/LeafCore/Sources/LeafCore/Network/SupabaseSessionStore.swift`. Move refresh-token persistence into the Keychain (same access attributes as the team-key entry) instead of plaintext JSON. Keep the JSON file for non-secret session metadata. Migration step on first launch reads old file, writes Keychain item, deletes file.
4. **OAuth `URLSession` ephemerality.** Files: `Linear*OAuthService.swift`, `Linear*TokenRefresher.swift`, `GitHubOAuthService.swift`, `GitHubTokenRefresher.swift`, `SlackOAuthService.swift`, `RealtimeWebSocketDriver.swift`. Replace `URLSession.shared` with a per-service `URLSession(configuration: .ephemeral)` instance (no on-disk cache or cookies).
5. **Anon-key in WebSocket URL → header.** Files: `Leaf/LeafApp.swift`, `Packages/LeafCore/Sources/LeafCore/Network/SupabaseEndpoint.swift`. If Phoenix WS spec allows, move the anon JWT into an `apikey` header on the upgrade request instead of the query string. If not feasible (Supabase Realtime requires the query param), document the constraint and defer.
6. **Plaintext-to-encrypted backup auto-purge.** File: `Packages/LeafCore/Sources/LeafCore/DB/Database.swift`. Add a one-shot purge of `*.pre-sqlcipher.bak` if its mtime exceeds 30 days. Logged at info level.
7. **`InviteService.revokeInvite` wired** to PATCH the existing Supabase table per the TODO at line 156–158. Behavioural change: admin Revoke button has effect; test it.
8. **OAuth loopback port — research + decide.** Linear and Slack OAuth flows bind to fixed loopback ports today. RFC 8252 §7.3 recommends ephemeral allocation. The phase plan does the following: (a) inspects each provider's OAuth-app redirect-URI registration to determine whether variable-port redirect URIs are accepted; (b) if yes — implement ephemeral port allocation in `LoopbackCallbackListener` and the provider endpoint builders, with state-equality validation unchanged; (c) if no — document the residual risk (a local attacker pre-binding the registered port can intercept `?code=&state=` but cannot complete the code exchange because PKCE verifier is in-memory only) in `current-state.md` "Open tensions" and add a comment to the endpoint files referencing this decision. Either path is acceptable.

### Acceptance criteria

- Sanitize tests: 8+ URL fixtures covering above categories; all pass.
- Low-order rejection: test feeds an all-zero peer pubkey and asserts throw; happy path unchanged.
- Refresh-token migration: first-launch reads file → writes Keychain → file deleted; second launch reads Keychain directly; tests cover both branches.
- Ephemeral sessions: verified by mocked URL cache that token-exchange responses are not cached.
- Backup purge: integration test seeds an old backup file, runs purge, asserts file is gone.
- Revoke invite: integration test invokes revoke, asserts subsequent `acceptInvite` against the same token returns `inviteExpired` / `inviteRevoked`.
- OAuth port decision: either an ephemeral-port test exercises the new allocator AND state-equality round-trip; or the phase plan contains the documented residual-risk note + a `current-state.md` "Open tensions" entry. Phase ships in either case.
- All SPM tests green; 5/5 xcodebuild schemes green; no regression in network integration tests.

### References

- Audit findings: HIGH H1 (browser URL fragment leak), HIGH H2 (OAuth hardcoded port), MEDIUM (KeyAgreement low-order, SupabaseSessionStore plaintext, URLSession.shared, anon-key in URL, plaintext backup, revoke TODO).

---

## 11. Phase 6 — Moat crypto audit

**Repo:** `leaf` + moat (`LeafCorePrivate/Prod/Crypto/`).
**Estimated session:** 3–4 hours.
**Spec scope here:** public-safe summary only. Detailed plan lives in `docs/superpowers/plans/2026-05-25-security-hardening-phase-6.md` (gitignored — full moat impl details).

### Scope (public-safe formulation)

Verify five public-stated crypto contracts against their moat implementations:

1. **AEAD nonce-gen source.** Confirm each codec emits a freshly random nonce per seal, sourced from `SecRandomCopyBytes` / CryptoKit's default randomness.
2. **AAD binding completeness.** Confirm each codec authenticates the envelope header (version + keyID and any additional identity fields documented in the corresponding public type) as AEAD additional-authenticated-data, not as plaintext-only metadata.
3. **Tag-failure propagation.** Confirm decrypt paths surface AEAD authentication failures as a thrown error, not as a silent `try?` fallthrough or empty-data return.
4. **KDF domain separation.** Confirm the invite KDF and the rotation KDF use distinct, non-empty `info` strings so leakage of one wrap-key cannot decrypt the other's blobs.
5. **SQLCipher pre-key PRAGMA + external salt invariant.** Confirm pre-key PRAGMAs (header-size + salt) are set in the correct order and the external salt is persisted with the same `0o600` discipline as the DB key.

For each invariant, add a unit/integration test under `LeafCorePrivateTests/` (gitignored) that fails when the invariant is broken (mutation-style test) and passes when it holds. Tests must be runnable as part of the moat test target.

Public-side artefacts:
- A new `LeafCore` protocol-test that demonstrates the Unimplemented stubs throw the right errors (covers behaviour from the public contract side).
- A documentation entry in `Packages/LeafCore/Sources/LeafCore/Crypto/README.md` describing each invariant in public-safe terms and pointing to the moat test target for enforcement.

### Acceptance criteria

- Five new moat-side tests, one per invariant; each red without the fix, green with it.
- One new public-side test exercising the Unimplemented-stub contract.
- `Crypto/README.md` updated with invariant list (no byte layouts, no exact info strings).
- `xcodebuild -scheme Leaf` green; moat test target (`LeafCorePrivateTests`) green when built with the prod config.

### References

- Audit findings: 5 invariants flagged as "needs human review" in the crypto-audit agent output.

---

## 12. Phase 7 — leaf-web hardening

**Repo:** `leaf-web` only.
**Estimated session:** 2–3 hours.

### Scope

1. **Security headers** added at the nginx vhost (or hosting platform's headers config — to be decided in plan) for `leaf.gundem.tech`:
   - `Content-Security-Policy` — `default-src 'self'; script-src 'self' challenges.cloudflare.com; style-src 'self' fonts.googleapis.com 'unsafe-inline'; font-src fonts.gstatic.com; img-src 'self' data:; connect-src 'self' <supabase-project-host>; frame-ancestors 'none'; base-uri 'self'; form-action 'self';`. Tighten over time.
   - `Strict-Transport-Security: max-age=31536000; includeSubDomains` (only after confirming all subdomains are HTTPS).
   - `Referrer-Policy: strict-origin-when-cross-origin`.
   - `X-Content-Type-Options: nosniff`.
   - `Permissions-Policy: camera=(), microphone=(), geolocation=()`.
2. **Subresource Integrity (SRI)** on third-party scripts/styles:
   - Cloudflare Turnstile (`challenges.cloudflare.com/turnstile/v0/api.js`) — pin SHA-384 from current shipped version.
   - Google Fonts — option A: self-host font files via local build pipeline; option B: keep CDN with documented residual risk (chose during phase).
3. **`pnpm install --frozen-lockfile`** in `scripts/deploy.sh`.
4. **`pnpm up devalue` / Astro bump** to clear GHSA-77vg-94rm-hx3p (dev/build-time DoS).
5. **Dashboard account-delete confirmation** — `src/scripts/dashboard.ts:49-65`. Require user to type "DELETE" (or password re-entry) in addition to the `confirm(...)` dialog before invoking `delete_self_account` RPC.

### Acceptance criteria

- `curl -I https://leaf.gundem.tech/` shows all five headers; CSP report-only first 48h, then enforce.
- Page loads, no console errors after enforce, Turnstile still works, fonts still render.
- `pnpm audit --prod` shows zero HIGH/CRITICAL.
- `deploy.sh` fails on lockfile drift.
- Account delete flow now requires typed confirmation; one e2e test covers it.

### References

- Audit findings: HIGH H-W3 (headers), HIGH H-W2 (SRI), HIGH (devalue), MEDIUM (delete confirm), LOW (frozen-lockfile).

---

## 13. Phase 8 — leaf-internal + VPS hardening

**Repo:** `leaf-internal` only (plus VPS shell for nginx vhost edits + systemd reload).
**Estimated session:** 2–3 hours.

### Scope

1. **`vault.sh` chmod race fix.** File: `scripts/vault.sh:85-93`. Replace `> "$OUT_FILE" ... chmod 600` with `umask 077` block, write to tmp, atomic rename, no post-chmod. Tests use shell-trap to assert mode never observed at 644.
2. **`vault.sh` no-eval.** File: `scripts/vault.sh:109-115`. Build the `KEY=VALUE` exports via Python helper (or `printenv`-safe assignment), source via process substitution `set -a; source <(...); set +a`. Add a regression test that creates an SSM parameter named with non-`[a-zA-Z0-9_./-]` characters (if AWS still allows in future) and asserts no shell exec.
3. **`/api/health` behind basic-auth** OR strip counters to a single `ok` boolean. File: `presence/health.py:38-86`. Pick the option that preserves the existing operator dashboard (uptime monitor) — likely strip counters and add a separate authenticated `/api/health/detailed` for in-team observability.
4. **`/api/mcp` access-log off.** File: `deploy/nginx-presence-locations.conf`. Add `access_log off;` to the `/api/mcp` location to stop logging the `Authorization: Bearer ...` header.
5. **FastAPI docs disabled.** File: `presence/app.py:145`. Set `docs_url=None, redoc_url=None, openapi_url=None` in `FastAPI(...)`. Or, alternatively, gate them behind basic-auth via nginx — choose during phase.
6. **`markdown-it` HTML disabled.** File: `scripts/plan_parser.py:25`. Change `MarkdownIt("commonmark", {"html": True})` → `{"html": False}`. Defense-in-depth; Jinja autoescape already covers the live render path.
7. **nginx vhost headers** (mirror Phase 7 set, scoped to the internal dashboard): CSP (more restrictive — no third-party origins on the dashboard), HSTS, Referrer-Policy, X-Content-Type-Options, X-Frame-Options.
8. **Port the Phase 1 leak-guard into `leaf-internal` CI.** Phase 4 cleaned the existing cloud-credential leak; Phase 8 prevents recurrence. Vendor `scripts/leak-guard.sh` from `leaf` (or factor it as a reusable workflow). Pattern set is identical for credentials (IAM access key IDs, account IDs, JWTs, PEM blocks) and adapted for repo-specific contents (no Swift moat patterns; instead AWS / vault / Python `eval` patterns from this repo's history).
9. **Subprocess argument hygiene sweep.** Re-grep the Python tree for `shell=True`, `os.system`, and `eval`; ensure none remain (current state: clean per audit, but the new vault.sh rewrite touches the boundary, so re-verify).

### Acceptance criteria

- New unit/integration tests for `vault.sh` (using `bats` or a similar bash testing framework).
- `curl https://leaf-internal.gundem.tech/api/health` returns only `{"ok": true}` (or 401 if auth-gated).
- `curl -H 'Authorization: Bearer fake' https://leaf-internal.gundem.tech/api/mcp` does not appear in `/var/log/nginx/access.log`.
- `curl https://leaf-internal.gundem.tech/docs` returns 404.
- `pytest scripts/tests/` green; `pytest presence/tests/` green.
- `curl -I https://leaf-internal.gundem.tech/` shows the same five headers as Phase 7.
- `leaf-internal` CI runs the ported leak-guard on PRs; one merged dry-run PR confirms it triggers and gates.
- `grep -rE 'shell=True|os\.system\(|\beval\(' presence/ scripts/ mac-hooks/` returns zero hits (excluding tests that deliberately exercise rejected inputs).

### References

- Audit findings: HIGH (vault.sh chmod race + eval), MEDIUM (health leakage, /api/mcp access-log, FastAPI docs, markdown html flag, vhost headers).

---

## 14. Cross-cutting acceptance: post-Phase-8 audit re-run

After Phase 8 lands and all branches are pushed, re-run the same 4-agent audit pattern from 2026-05-25 against the current branches (not `main`). Expected:

- Zero CRITICAL.
- Zero HIGH that was not deliberately deferred with documented carry-over in `current-state.md` "Open tensions".
- The MEDIUM/LOW list is allowed to grow modestly (new lint-level findings); each new MEDIUM gets an open question logged in `docs/reference/open-questions.md`.

If the re-run is clean, do the collective merge: each repo's `feature/security-hardening-2026-05-25` → `main` via PR with `--no-ff`, in this order (so any inter-repo references stay coherent): `leaf-relay` → `leaf` → `leaf-internal` → `leaf-web`.

---

## 15. Open questions for the human

These need a human decision but do not block phase entry; each phase plan resolves them inline.

1. **Email-rewrite go/no-go for `leaf` open-source promotion.** Phase 1 produces the decision doc + (if go) a rewrite script. The user-side step (running the script + force-push to a fresh remote) happens outside the branch.
2. **CSP host whitelist for `leaf.gundem.tech`** — production backend host needs to be confirmed before CSP enforce can be flipped on. Phase 7 starts in report-only mode for 48 h, then enforces.
3. **`/api/health` auth strategy** — strip counters (preserves uptime monitoring) vs auth-gate (loses external monitor) vs split into public `/api/health` (boolean only) and authenticated `/api/health/detailed`. Choose during Phase 8 planning.
4. **Google Fonts hosting** — self-host vs documented residual CDN risk. Choose during Phase 7 planning.
5. **Phase 2 batch strategy.** Phase 2 touches three repos in one logical session. If the energy budget is tight, optionally split into Phase 2a (`leaf` uuidStringToRawBytes) / Phase 2b (`leaf-internal` HTML injection) / Phase 2c (`leaf-web` XSS) — each tiny on its own but ship-coherent only as a batch. Decide at phase entry.

---

## 16. Out-of-spec follow-ups (separate tracks)

- **Supabase RLS audit** (own spec + track) — every table, every Edge Function, every Realtime subscribe path.
- **Cloudflare Worker `/api/contact`** audit (lives outside this repo set).
- **Cloudflare Worker `/changelog/latest.json`** source/storage audit.
- **Multi-workspace single-workspace assumption** carry-overs (ISSUE-1 / NIT-4 / NIT-5) — tracked separately in Track 5 / S7.

---

## 17. Plan files (gitignored, will be created at phase start)

| Phase | Plan file |
|---|---|
| 1 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-1-oss-readiness.md` |
| 2 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-2-live-criticals.md` |
| 3 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-3-relay.md` |
| 4 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-4-secrets-admin.md` |
| 5 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-5-leaf-dind.md` |
| 6 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-6-moat-crypto.md` |
| 7 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-7-web.md` |
| 8 | `docs/superpowers/plans/2026-05-25-security-hardening-phase-8-internal-vps.md` |

Plans are produced one at a time at the start of each phase session via `superpowers:writing-plans`. Each plan references this master spec and locks down concrete file paths, test names, and commit decomposition.

---

## 18. Audit artefact

The source audit findings are preserved verbatim in the conversation transcript of session 2026-05-25 (4-agent dispatch: `audit-secrets`, `audit-relay`, `audit-crypto`, `audit-network`, `audit-internal-web`). Any phase plan re-references the relevant agent output for context-grounded fix design.
