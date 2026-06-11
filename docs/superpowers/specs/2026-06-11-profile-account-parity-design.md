# Profile ↔ Web-dashboard parity — design

**Date:** 2026-06-11
**Branch:** `feature/profile-account-parity` (stacked on `feature/account-login-phase1`)
**Scope owner:** Anton (Track 5 — native UI)
**Status:** design, awaiting review

## 1. Goal

Bring the native app's **Profile** section (`ProfileView`) to parity with the
website dashboard's account view (`leaf-web/src/pages/dashboard.astro`). After the
account-login Phase 1 work, a logged-in user has a real Supabase account, but the
app's Profile still only surfaces a workspace-scoped display name + tier chip +
stats. It does not show the account identity (email, provider, member-since) that
the web dashboard shows, and there is no way to delete the account from inside the
app.

This phase makes Profile show the same account identity as the web dash, and adds a
native **Delete account** flow that also tears down local on-device state.

## 2. Scope

**In scope (chosen: "identity fields + native delete"):**
- Show `Name` (account `full_name`), `Email`, `Provider`, `Member since`
  (`created_at`), `Plan` (from the app's real `TierGateReader`, not a hardcoded
  badge).
- Fetch the account object from Supabase (`GET /auth/v1/user`) — the app does not
  currently fetch any of these fields.
- Native **Delete account**: call the same server RPC the web dash calls
  (`delete_self_account`), then run a security-complete local teardown (session,
  launch agent, device identity), then return to the login gate. (Full on-disk
  DB/keystore shred is a deferred follow-up — see §4.3.)
- Layout **Variant B** (single account identity, dash-faithful) — see §4.1.

**Out of scope (deliberate):**
- **Set / Change password** — stays on the website. The app surfaces a "Change
  password on the web ↗" link (decided in) that opens the web dashboard, nothing
  more. Rationale: most users authenticate via OAuth; native password management is
  low value and extra surface.
- **Download** card from the web dash — irrelevant inside the app.
- Avatar upload / profile editing beyond what the web dash offers (the web dash has
  none).
- Changing the **web** dashboard (e.g. fixing its hardcoded "Solo" plan badge) —
  separate, out of this phase.

## 3. Current state (verified)

- `ProfileView` (`Leaf/Views/Window/Profile/ProfileView.swift`) renders
  `AccountSettingsSection()` + three stat tiles (`LeafMetricCard`). `fullName` there
  is `NSFullUserName()` (the macOS local user), **not** the Supabase account.
- `AccountSettingsSection`
  (`Leaf/Views/Window/Settings/AccountSettingsSection.swift`) is used **only** by
  `ProfileView` (despite its filename). It shows: avatar icon, workspace display
  name (from `WorkspaceReader` self-member, fallback "Anonymous"), tier chip
  (`.team` capsule / `.free` Upgrade button), Sign Out (confirmation →
  `loginService.signOut()`).
- `SupabaseClient`
  (`Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient.swift`) exposes
  `currentSession() -> SupabaseAuthSession?`, `ensureFreshSession(force:)`, and
  `SupabaseEndpoint.authenticatedHeaders(anonKey:accessToken:)`. New authed calls
  follow the `signInWithPassword` / PostgREST patterns. PostgREST base path is
  `baseURL.appendingPathComponent("rest/v1/...")`.
- `SupabaseAuthSession` carries `accessToken / refreshToken / userID / expiresAt /
  pubkeyClaim` — **no** email / name / provider / created_at. Those must come from
  `GET /auth/v1/user`.
- Local teardown primitives already exist: `IdentityService.deleteLocalIdentity()`
  (used by device-conflict reset), `WorkspaceCascadeDeleter` + `TeamKeystore`
  (hard-wipe of local cache + keystore, the S8 "Wipe cache data" path),
  `launchAgent.unregister()` via `SupabaseOAuthService.onSignedOut` (wired in
  `LeafApp`).
- The web dash deletes via `sb.rpc('delete_self_account')` (security-definer,
  idempotent server function), then `signOut()` + redirect.

## 4. Design

### 4.1 Layout — Variant B (single account identity)

```
┌─ Account ──────────────────────────────┐
│  (AY)  Anton Yeresel          [ Team ✓ ]│   avatar(initials) + full_name + Plan chip
│        ──────────────────────────────── │
│        Email          ayeresell@gmail.com│   key/value rows (LeafType.body)
│        Provider       Google             │
│        Member since   10 Jun 2024        │
│        Change password on the web ↗      │   link → web dashboard (decided: in)
│                              [ Sign Out ]│
└──────────────────────────────────────────┘
┌─ Active streak · Deep work · Total focus ┐   existing stat tiles — unchanged
└──────────────────────────────────────────┘
┌─ Danger zone (danger border) ───────────┐
│  Delete your account permanently. Local  │
│  data on this Mac is wiped too.          │
│                        [ Delete account ]│
└──────────────────────────────────────────┘
```

- **Name** resolution (first non-empty wins): account `full_name` → `name` →
  `user_name` → workspace self-member display name → email local-part → "Local
  user". (The web dash uses `full_name → name → user_name`; we extend the tail so a
  fresh account still reads sensibly.)
- **Plan** = `TierGateReader.tier`, rendered as the **chip in the header row**
  (top-right, next to the name — not a separate key/value row): `.team` → existing
  "Team — early access" capsule; `.free` → existing "Upgrade" button (keeps the
  upgrade path). We do **not** hardcode "Solo". (The web dash renders Plan as a dl
  row; the chip placement is the small intentional divergence.)
- **Provider** display: `email → "Email"`, `google → "Google"`, `github →
  "GitHub"`, else capitalized raw value.
- **Member since**: `created_at` ISO → `"d MMM yyyy"` with `en_US_POSIX` (matches
  the dash's `10 Jun 2024` format).
- The workspace display name is no longer the primary identity here; it remains the
  identity on Team screens (unchanged).

### 4.2 Data fetch

New value type `SupabaseUserProfile` (LeafCore, `Network/`):
`id: UUID?`, `email: String?`, `fullName: String?`, `provider: String?`,
`createdAt: Date?`. `Decodable` from the `GET /auth/v1/user` body
(`{ id, email, created_at, app_metadata:{provider}, user_metadata:{full_name,
name, user_name} }`).

- `SupabaseEndpoint.userInfo(baseURL:)` → `GET auth/v1/user`.
- `SupabaseClient.fetchUserProfile() async throws -> SupabaseUserProfile`:
  `ensureFreshSession()` → GET with `authenticatedHeaders` → decode. Maps non-2xx
  to existing `SupabaseClient` error space.
- `AccountProfileReader` (app, `Leaf/Models/`, `@Observable @MainActor`): state
  `idle / loading / loaded(SupabaseUserProfile) / error(String)`; `load()` calls
  `client.fetchUserProfile()`. Mirrors the existing reader pattern
  (`InsightsReader` / `TierGateReader` / `WorkspaceReader`). Injected into the
  environment from `LeafApp`. `ProfileView` triggers `load()` in `.task` and renders
  identity from it (graceful fallbacks per §4.1 while `loading`/`error`).

### 4.3 Delete account (native, with teardown)

`AccountDeletionService` (app — orchestrates app + LeafCore primitives):

1. `SupabaseEndpoint.rpcDeleteSelfAccount(baseURL:)` → `POST
   rest/v1/rpc/delete_self_account`.
2. `SupabaseClient.deleteSelfAccount() async throws`: `ensureFreshSession()` → POST
   (empty body `{}`) with `authenticatedHeaders` → expect 2xx/204.
3. **Server first, then local.** Order: call the RPC; only on success run local
   teardown (so a failed server delete never half-wipes the device):
   - `loginService.signOut()` (clears session + `onSignedOut` → launch-agent
     unregister; re-arms gate),
   - `IdentityService.deleteLocalIdentity()` (drops `x25519.priv` — the device's
     security-critical local secret).
   This is **security-complete**: after it the device cannot authenticate, cannot
   prove its identity, and capture is stopped; the local SQLCipher DB is encrypted
   at rest and, with the account deleted server-side and session+identity gone, is
   inert.
   **Deferred (follow-up): full on-disk DB/keystore shred.** The Agent is a separate
   LaunchAgent process holding `events.sqlite` (WAL) open; deleting those files out
   from under a running writer races the checkpoint. The recovery flow
   (`LeafCore.Database.backupAndReset(at:)`) deliberately backs up and **relaunches**.
   A true local shred must coordinate with the Agent lifecycle (reuse that relaunch
   machinery) and respect the R7 recovery invariants — out of scope for this phase,
   tracked as a follow-up. The security-critical teardown above is sufficient now.
4. UI returns to `LoginGateView` (gate re-arm from sign-out already drives this).
5. Confirmation UX (decided): native `confirmationDialog` with a destructive
   "Delete account" button — platform-idiomatic, no clone of the web's custom modal.
   Errors surface inline in the Danger-zone card (no silent failure). The confirm
   action shows in-flight state and is disabled while the request runs.

### 4.4 New / changed files

- **New** `Packages/LeafCore/Sources/LeafCore/Network/SupabaseUserProfile.swift`
- **Edit** `…/Network/SupabaseEndpoint.swift` (+`userInfo`, +`rpcDeleteSelfAccount`)
- **Edit** `…/Network/SupabaseClient.swift` (+`fetchUserProfile`, +`deleteSelfAccount`)
- **New** `Leaf/Models/AccountProfileReader.swift`
- **New** `Leaf/Services/AccountDeletionService.swift` (or co-located with the view)
- **Rewrite** `Leaf/Views/Window/Profile/ProfileView.swift` → Variant B; introduce
  `ProfileAccountCard` + `ProfileDangerZone` subviews.
- **Delete** `Leaf/Views/Window/Settings/AccountSettingsSection.swift` (only used by
  ProfileView; its tier-chip + sign-out logic moves into `ProfileAccountCard`,
  which also carries over the `UpgradeModal` sheet + `@Environment(\.submitToWaitlist)`
  wiring the `.free` Upgrade button depends on).
- **Edit** `Leaf/LeafApp.swift` (inject `AccountProfileReader`; wire
  `AccountDeletionService` dependencies).

## 5. Data dependency to verify

`delete_self_account` is **not** defined anywhere in the local repos (`leaf-web`,
`supabase/`, `leaf-relay`) — the web dash calls it as a Supabase RPC, so it is
defined directly in the prod Supabase project (`jwxnhwyqjzjmjnmwpwyq`). Before
wiring the native delete, **verify the function exists** (security-definer,
idempotent). If it is missing or only partial, it must be created server-side
(server-side task — see §10). The native delete reuses the exact same RPC; no new
server contract is invented here.

## 6. Errors / empty states

- Profile fetch `loading` → show name fallbacks + a subtle placeholder on the rows;
  `error` → keep fallbacks, optional small "couldn't refresh account" affordance (no
  blocking banner — identity is non-critical).
- Delete RPC failure → inline error in Danger zone, no local wipe performed, button
  re-enabled.
- Offline at Profile open → fetch fails transiently; identity falls back, no gate
  eviction (Profile fetch must never log the user out).

## 7. Testing

- LeafCore unit tests: `SupabaseUserProfile` decode (full / OAuth / minimal /
  missing-metadata bodies); `SupabaseEndpoint.userInfo` + `rpcDeleteSelfAccount`
  URL composition; `SupabaseClient.fetchUserProfile` + `deleteSelfAccount` happy +
  non-2xx paths via injected `URLSession` (existing test pattern).
- App: `AccountProfileReader` state transitions; name-resolution fallback chain;
  provider + date formatting helpers (pure, unit-testable).
- `AccountDeletionService`: ordering (server-before-local) and that a server failure
  performs **no** local teardown (mock client + teardown spies).
- Manual smoke (two-Mac signed build, per phase workflow): real login → Profile shows
  correct email/provider/member-since/plan → delete account → server row gone +
  local wiped + back at gate.

## 8. Privacy / leak considerations (public repo)

`gundemtech/leaf` is **public**. The identity fields (`full_name`, `email`) are the
*user's own* data fetched at runtime and rendered locally — no hardcoded secrets, no
moat (no SQL Derived-Insights bodies, no thresholds, no crypto byte layouts). The
`/auth/v1/user` and `/rest/v1/rpc/delete_self_account` endpoints are standard
Supabase/GoTrue/PostgREST surfaces already used by the public web dash. `/pre-push-leaf`
still runs before any push.

## 9. Open questions — resolved

- **OQ-1 — RESOLVED (verify at impl).** `delete_self_account` has no SQL definition
  in any local repo and the top-level `supabase/` dir is empty → the function is
  applied directly to the prod Supabase project (`jwxnhwyqjzjmjnmwpwyq`). The web
  dash calls it live in production and account deletion works there, and the owner
  confirms it was added. Treat as existing; the plan still includes an authed-probe
  verification step, and creates it server-side only if the probe fails.
- **OQ-2 — RESOLVED: include.** Add the "Change password on the web ↗" link (opens
  the web dashboard).
- **OQ-3 — RESOLVED: native.** Use a native `confirmationDialog`, not a custom
  modal.

## 10. Local vs VPS / Supabase responsibilities (§14)

- **Local (this Mac session):** all Swift app + LeafCore code, unit tests, this
  spec, the `ProfileView` rewrite, branch + PR.
- **Server-side (Supabase project, VPS/console session):** verify `delete_self_account`
  exists (OQ-1) and, if absent, define it (security-definer, idempotent) + ensure
  RLS/grants let an authenticated user invoke it on self. `GET /auth/v1/user` needs
  **no** server change (GoTrue built-in). No nginx/relay change.
