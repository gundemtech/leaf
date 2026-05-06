# Phase 5 Architecture Contract

**Status:** Draft (2026-05-04). Promoted to "Active" after first 5.1.A spec is reviewed against it.
**Owners:** Phase 5 implementation pair (current authors visible in `feature/phase-5-*` branch commit graph).
**Audience:** Authors of every Phase 5.x sub-project spec. Refer here for boundary decisions.

---

## 1. Purpose & status

This document is a **reference contract**, not an implementation plan. Each Phase 5.x sub-project (5.1.A, 5.1.B, 5.1.C, 5.1.D, 5.1.E, 5.2, 5.3, 5.4, 5.5) owns its own design + plan; this contract fixes the constants between them so a decision in one sub-project does not surprise another.

When a Phase 5.x spec faces an architectural choice that already has a fixed answer here, it must defer to this document. If a sub-project needs to deviate, the deviation must update this document first (PR to this file), then the sub-project spec.

Whitepaper (`leaf-docs`) remains source of truth for public-facing product decisions. This contract supplements with engineering specifics that don't belong in the public site (exact endpoint paths, repo split rules, keystore filenames). Implementation moat (precise timeouts, KDF info strings, nonce generation, byte ordering of internal serialisations) lives in `LeafCorePrivate` and the private `leaf-relay` repo, not here.

This is a **living document.** Amendments over Phase 5 lifetime are expected and welcome.

---

## 2. End-to-end topology

```
                  ┌────────────────────────────────────┐
                  │   gundemtech/leaf-relay            │
                  │   (private TS / Cloudflare         │
                  │    Workers + Durable Objects)      │
                  ├────────────────────────────────────┤
                  │  Phase 4.4 (live):                 │
                  │    POST /<provider>/oauth/callback │   ← Slack OAuth bouncer
                  │  Phase 5.2 (new):                  │
                  │    POST   /v1/invite               │   ← admin posts wrapped blob
                  │    GET    /v1/invite/:token        │   ← invitee one-time consume
                  │    DELETE /v1/invite/:token        │   ← admin revoke
                  │  Phase 5.4 (new):                  │
                  │    WS     /v1/presence/team/:id    │   ← per-team DO + hibernation
                  └────────────────────────────────────┘
                                  ▲       ▲
                                  │       │   все blobs зашифрованы AES-GCM-256
                                  │       │   relay видит только bytes
                                  │       │
                  ┌───────────────┴───┐ ┌─┴─────────────────────┐
                  │ Mac устройство A  │ │ Mac устройство B      │
                  │ (admin / first)   │ │ (member / invitee)    │
                  ├───────────────────┤ ├───────────────────────┤
                  │ events.sqlite     │ │ events.sqlite         │
                  │ (SQLCipher)       │ │ (SQLCipher)           │
                  │  ├ 5 existing tbl │ │  ├ 5 existing tbl     │
                  │  ├ org (5.1.A)    │ │  ├ org (5.1.A)        │  ← полная копия
                  │  ├ team_members   │ │  ├ team_members       │     org-метаданных
                  │  ├ team_keys      │ │  ├ team_keys          │     на каждом устройстве
                  │  ├ presence_out   │ │  ├ presence_out       │
                  │  └ presence_hist  │ │  └ presence_hist      │
                  ├───────────────────┤ ├───────────────────────┤
                  │ keystore files    │ │ keystore files        │
                  │  ├ db key         │ │  ├ db key             │   ← raw 32B SQLCipher key
                  │  ├ teamKey        │ │  ├ teamKey            │   ← raw 32B AES current
                  │  ├ teamKey hist   │ │  ├ teamKey hist       │   ← past rotations (decrypt history)
                  │  └ x25519 priv    │ │  └ x25519 priv        │   ← long-term identity
                  └───────────────────┘ └───────────────────────┘
```

Three locations of state:

1. **Local on each device** (forever retention by default): SQLCipher DB + keystore files. Every device holds full org metadata, full member list, full key history. Local-first by design — lost device leaves remaining peers unaffected.
2. **Online on relay** (ephemeral): wrapped invite blobs (24h TTL) and latest-only encrypted presence snapshots (per-user, in DO memory). Relay never persists plaintext, identity data, or org metadata.
3. **In transit** (peer-encrypted): AES-GCM-256 envelope format (Section 6), keyed by current teamKey from `team_keys`.

Exact keystore filenames are TBD by 5.1.D spec; this document only commits to "raw key material lives outside the SQLCipher file, in keystore files protected by POSIX permissions + FileVault".

---

## 3. Repo split: `leaf` ↔ `leaf-relay`

| Concern | `leaf` (this repo, public) | `leaf-relay` (private repo) |
|---|---|---|
| Language | Swift 6 | TypeScript |
| Runtime | macOS user processes (Agent / MenuBarApp / MCPServer) | Cloudflare Workers + Durable Objects |
| Distribution | Sparkle 2 + Cloudflare R2 (EdDSA-signed appcast) | Wrangler `wrangler deploy` |
| State ownership | All persistent shared state — org, members, key history, presence history | Ephemeral only — TTL'd invite KV + latest-presence DO memory |
| Auth model | None on relay calls (capability tokens are bearers) | None inbound (capability tokens validate themselves) |
| Sensitive secrets | Keystore files (raw teamKey + X25519 private) | Cloudflare API token (deploy-time) — never in `leaf` |

**Boundary rule:** any feature requiring **persistent shared state** lives in `leaf` and is replicated to peers via encrypted relay messages. The relay never owns canonical state — only short-lived transit/presentation buffers. If a future feature requires persistent server-side state, it goes through whitepaper review (potential won't-list violation).

---

## 4. Identity model

- Each device has a **long-term X25519 keypair** generated at first run, before any org operations. Public key registered into local `team_members.pubkey_hex` on org creation / invite accept; private key stored in keystore file (POSIX 0600, FileVault-protected). Never rotated in MVP — key compromise = remove + re-add as new member.
- Each member is identified by a random **UUID v4** generated locally on the device. Never email, never username, never derived from system identifiers. UUID is stored in `team_members.id` and embedded in presence envelopes.
- **Single-org-per-device**: one device → one row in `org` → one self-row in `team_members`. Joining a new org requires leaving (or wiping) the current one.
- **Admin role** is identified at row-level (`team_members.role = 'admin'`). It carries org/billing/invite permissions but **no privileged read access** (whitepaper § Won't-list, Share Controls invariant). Admin sees exactly what every other member sees.

---

## 5. Trust model

Relay = **honest-but-curious**. We assume Cloudflare runs the code we deployed, but don't trust raw Cloudflare bytes-access to be opaque. Therefore: relay sees only opaque encrypted blobs.

**Defended threats:**
- Relay-side passive observation — encrypted blobs only, content unreadable
- Network MITM — TLS via Cloudflare-managed certs
- Single-message replay — fresh per-message nonce in envelope
- Unauthorised invite consumption — OTP gates the ECDH handshake; relay alone cannot complete invite (see Section 8)
- Removed-member future presence — admin rotates teamKey on removal (Section 7); old keyID rejected by future peers

**NOT defended ("I lost my laptop"):**
- Physical compromise of an unlocked device → attacker reads keystore + DB → full read access to past presence_history. Future presence prevented only by remove + rotation (Phase 5.3), but past data already in plaintext on attacker's box.
- No post-compromise security (PCS) in MVP. MLS migration reserved for v1.5+ if N>50 or relay history retention is requested.
- No protection against malicious peer (a member of the org acting in bad faith). Threat model assumes peers are mutually trusted; expulsion is the remediation, not cryptographic exclusion mid-broadcast.

---

## 6. Crypto primitives & envelope format

| Primitive | Use | Algorithm |
|---|---|---|
| Symmetric encryption | Presence snapshots, wrapped teamKey for invite | AES-GCM-256 |
| Key agreement | Invite handshake, key rotation wraps | X25519 ECDH |
| Key derivation | Combine ECDH shared secret + OTP salt → AES wrapping key | HKDF-SHA256 |
| Random | Nonces, member UUIDs, OTP, invite tokens | `SecRandomCopyBytes` (CryptoKit) |

**Envelope format** (already in whitepaper `presence-relay.md`, repeated here for ergonomic reference):

```
┌──────┬──────────┬────────┬──────────────────────┬──────┐
│ ver  │  keyID   │  nonce │     ciphertext       │ tag  │
│ 1B   │   16B    │   12B  │      variable        │ 16B  │
└──────┴──────────┴────────┴──────────────────────┴──────┘
```

- `ver = 1` — current. Reserved bumps: `ver = 2` for MLS migration (v1.5+). Implementations MUST reject unknown versions.
- `keyID` — the 16-byte `team_keys.id` UUID. Allows peers to know which teamKey rotation to use for decryption.
- `nonce` — random per-message, generated via CryptoKit. Nonce reuse with the same key would break AES-GCM; do not reduce randomness for any reason.
- `tag` — AES-GCM auth tag.

Total fixed overhead: **45 bytes** + ciphertext. Typical presence snapshot 200-500 bytes plaintext → 250-550 bytes envelope.

**No PQ-resistance in MVP.** **No forward secrecy in MVP** (presence is ephemeral + N≤50 doesn't justify MLS overhead).

Implementation specifics — exact HKDF info strings, nonce ordering, AAD content, byte layouts of internal helpers — live in `LeafCorePrivate`, not in this document.

---

## 7. Key lifecycle

Two concurrent key types per device.

### TeamKey (AES-256, current + history)

- Generated by admin on org creation. 32 raw bytes from `SecRandomCopyBytes`.
- **Current** version stored in keystore (POSIX 0600). Used for outgoing presence encryption.
- **Past versions** retained in keystore (composite layout TBD by 5.1.D spec) for decrypting `presence_history` encrypted before rotations. Never deleted without explicit user action (purges historical fabric of the team).
- **On rotation (Phase 5.3 removal flow):**
  1. Admin generates new teamKey (32 random bytes).
  2. New row inserted into `team_keys` (id, generated_at_ms, generated_by_member_id).
  3. Previous row's `deprecated_at_ms` set to now.
  4. Admin computes pairwise X25519 ECDH(admin, member) for each remaining member, HKDF-derives a wrap key, AES-GCM-wraps the new teamKey, POSTs each wrapped blob to relay `/v1/invite/:tok` with 24h TTL.
  5. Each remaining member fetches & unwraps on next online tick. After all peers consume, admin can DELETE leftover invites.

### Device X25519 long-term key

- Generated at first app run, before any org operations (so a user can always export a public key for invite preparation).
- Private 32 bytes in keystore. Public 32 bytes registered into `team_members.pubkey_hex` on org creation / invite accept.
- Never rotated in MVP. Key loss = device wipe + re-invite as new member.

### What the local SQLCipher DB stores (Phase 5.1.A)

Stored:
- `team_members.pubkey_hex` — each member's X25519 public key, hex-encoded 32 bytes (64 chars).
- `team_keys.id` — rotation UUID (no key material).
- `team_keys.generated_at_ms` / `deprecated_at_ms` — lifecycle timestamps.

**Never stored in DB:**
- Raw teamKey bytes (current or past).
- X25519 private bytes.
- Wrapped versions of teamKey for peers (those live ephemerally on relay during invite TTL).

---

## 8. Relay API surface

All Phase 5 endpoints under `/v1/` prefix on the relay. Final hostname (`relay.gundem.tech` or similar) fixed by 5.2 spec. All HTTPS via Cloudflare-managed certs. No user-bound auth — capability tokens are bearers.

### Existing (Phase 4.4, live, untouched by Phase 5)

- `POST /<provider>/oauth/callback` — Slack distributed-app OAuth bouncer to loopback.

### Phase 5.2 — invite endpoints

- `POST /v1/invite` — admin posts:
  - `member_pubkey_hex` — invitee's X25519 public, derived in invitee's app and transmitted out-of-band before invite.
  - `wrapped_blob` — admin-side AES-GCM wrap of current teamKey under HKDF(ECDH(admin, invitee), OTP-salt).
  - `expires_at_ms` — server enforces ≤ 24h.
  - Returns: `{ token: <random URL-safe ~24-byte> }`. Token is the capability for the invitee.
- `GET /v1/invite/:token` — invitee fetches `wrapped_blob`. **One-time consume**: server marks token consumed on first 200, subsequent calls return 404.
- `DELETE /v1/invite/:token` — admin revokes before consume (Phase 5.3 removal flow may reuse for cleanup).

Storage layer: Cloudflare Workers KV with per-token TTL. No long-term storage.

### Phase 5.4 — presence WebSocket

- `WS /v1/presence/team/:teamID` — connect; first frame is current teamKey envelope as auth (server only verifies `keyID` matches DO's known active rotation; does not decrypt).
- **Per-team Durable Object** with WebSocket Hibernation (idle-cheap, ~$5-20/mo per 100 teams × 20 users).
- DO holds `Map<member_id, last_envelope_bytes>` in DO memory. No durable storage of presence (snapshot lost on DO reset is acceptable — peers re-broadcast on next change).
- On client send: relay broadcasts to all currently-connected peers (excluding sender).
- On peer connect: relay replays last-known envelope per member.
- Heartbeat: client-side ping at the cadence specified in whitepaper presence-relay (currently 60s). Server-side disconnect threshold and reconnect policy — configurable, fixed by 5.4 spec; defaults derived from whitepaper-public values.

### Phase 5.3 — key rotation endpoints

- `POST /v1/key-rotation` — admin POSTs wrapped teamKey (or tombstone) blob:
  - `peer_pubkey_hex` — recipient's X25519 public.
  - `blob` — admin-side AES-GCM wrap (rotation: under HKDF(ECDH(admin, peer), salt=newKeyID); tombstone: under prior teamKey).
  - `expires_at_ms` — server enforces ≤ 24h.
  - Idempotent on `(peer_pubkey_hex, new_key_id_hex)` composite (server peeks blob bytes 17..33 for new_key_id) — repeat POST returns same `rotation_id`, first-writer-wins on blob bytes.
  - Returns: `{ rotation_id: <random URL-safe 32-byte>, expires_at_ms }`.
- `GET /v1/key-rotation/by-peer/:peer_pubkey_hex` — peer drains mailbox.
  - Returns: `{ rotations: [{ rotation_id, blob, expires_at_ms }, ...] }` (200, possibly empty array).
  - **Server does NOT delete on GET** (list-then-ACK semantic, survives mid-install crash).
  - Cap N=20 on response array (defensive).
- `DELETE /v1/key-rotation/:rotation_id` — peer ACKs after successful unwrap+install. Idempotent 204 regardless of token shape / existence (existence-hiding mirror invite DELETE).

Storage layer: Cloudflare Workers KV (separate `KEY_ROTATIONS` namespace) with per-token TTL ≤ 24h. Idempotency via composite-key primary index `rot:<peer>:<newkid>` + reverse `rot-id:<rotation_id>` for DELETE lookup.

### Versioning policy

- All Phase 5 endpoints under `/v1/` from day one.
- Breaking changes → new prefix `/v2/`, with grace period during which both work.
- Implementations log rejected unknown-version envelopes to local Privacy Dashboard for diagnostics.

---

## 9. Phase boundary matrix

What each sub-project ships, declaratively. If your spec adds something not on this row — it's out-of-scope creep, push to the right phase.

| Sub-project | Deliverable in `leaf` | Deliverable in `leaf-relay` | Persistent state added |
|---|---|---|---|
| **5.1.A** | M006 `org`, M007 `team_members`, M008 `team_keys` migrations + Schema namespace + 1 enum (`TeamMemberRole`) | — | 3 new SQLCipher tables |
| **5.1.B** | GRDB-style helpers in `Database.swift` + value types (`Org` / `TeamMember` / `TeamKey`) | — | — |
| **5.1.C** | `EnvelopeCodec` real impl (AES-GCM-256 only) replacing `UnimplementedEnvelopeCodec`; `EnvelopeHeader.peek` static helper; `ProdEnvelopeCodec` in LeafCorePrivate for moat-side specifics (AAD layout, JSON encoder config) | — | — |
| **5.1.D** | `OrgService.createPersonalOrg`, keystore writers (teamKey current + history file, X25519 private file) | — | First row in `org`, first row in `team_members`, first row in `team_keys` |
| **5.1.E** | `OrganizationView` / `TeamView` real content, "Create personal org" CTA, integration test, `docs(shared)` landing commit | — | — |
| **5.2** | `RelayClient` HTTP, generate-invite UI, accept-invite UI, OTP entry, X25519 ECDH + HKDF-SHA256 helpers (moved here from 5.1.C — first real call-site is invite handshake), Onboarding screen 6 partial | `POST /v1/invite`, `GET /v1/invite/:token`, `DELETE /v1/invite/:token` + KV with TTL | — (relay state ephemeral only) |
| **5.3** | Remove-member UI, key rotation logic, pairwise ECDH wraps for remaining members | `POST /v1/key-rotation`, `GET /v1/key-rotation/by-peer/:peer`, `DELETE /v1/key-rotation/:id` + KV `KEY_ROTATIONS` namespace | New rows in `team_keys`, `team_members.removed_at_ms` set |
| **5.4** | M009 `presence_outgoing`, M010 `presence_history`, broadcast loop in Agent, Swift WS client (reconnect/heartbeat), Team presence grid live UI | `WS /v1/presence/team/:teamID` + per-team Durable Object | 2 new SQLCipher tables |
| **5.5** | Onboarding screen 6 final integration ("Team — join via invite OR create personal org") | — | — |

---

## 10. Failure modes

| Failure | Detection | Behaviour |
|---|---|---|
| Relay outage (CF incident) | WS connection refused / HTTP 5xx | Local UI shows "Team sync paused". Local data fully usable. Presence broadcast retries with exponential backoff. |
| Stale invite (>24h, no consume) | Server-side TTL on KV | KV auto-purge. Admin sees "Invite expired" on Privacy Dashboard. |
| Removed member sends presence on old keyID | Relay rejects WS auth (keyID not in active set) | Relay logs rejection; member's local app surfaces "Connection rejected — your access was removed." |
| Invitee enters wrong OTP | HKDF derives wrong key → AES-GCM tag check fails on unwrap | Error in invitee UI: "OTP doesn't match. Ask admin to share again." Token remains consumable for retry; lockout policy (consecutive-attempts threshold + cooldown) — configurable, fixed by 5.2 spec. |
| Network partition mid-broadcast | Heartbeat times out | Reconnect with exponential backoff (capped). Resume from peer's `last_seen` cache. |
| Cloudflare account compromise | (out of scope; relay = honest-but-curious) | Mitigated by envelope encryption — attacker sees opaque bytes only. |
| SQLCipher migration failure on update | GRDB exception on `migrator.migrate(pool)` | App refuses to start, logs error. Recovery: rename DB to `.bak` and start fresh (existing precedent in `migrateFromPlaintextIfNeeded`). |
| Local keystore file deleted/corrupted | CryptoKit error on read | App refuses to use team features. UI shows "Local keys missing — please reconnect/recreate org." |

---

## 11. Out of scope for Phase 5

| Excluded | Why | Reserved for |
|---|---|---|
| Multi-org per device | Every device → one org. Need is rare; topology overhead high. | Post-MVP |
| Cross-team federation | Not in trust model | v2.0+ |
| Public discovery / browse | Privacy-first → invite-only | Never (won't-list) |
| Avatars / profile pictures | Not core to ambient memory | v1.1+ |
| Real billing (Stripe / Paddle) | Pre-PMF | After PMF |
| Mobile push notifications | macOS-first MVP | iOS port (v1.5+) |
| Web client | Native-only MVP | Post-MVP if signal warrants |
| MLS / TreeKEM | N≤50 doesn't justify complexity | v1.5+ if scale demands |
| Forward secrecy on presence | Ephemeral data, no PCS in MVP threat model | v1.5+ with MLS |
| Post-quantum resistance | Not threatened in MVP timeframe | Long-term |
| Safety handle (admin freeze/wipe coleague's device) | Owner-asked-only feature, deferred | v1.1 |

---

## 12. Versioning & future migrations

- **Envelope `version=1`** is the only valid value in MVP. Reserved bumps:
  - `version=2` for MLS migration (v1.5+).
  - Bump rule: implementations MUST reject unknown versions.
- **Relay endpoints** all under `/v1/` prefix. Breaking changes → `/v2/`, with overlap period.
- **SQLite migration policy:** new migrations append-only (M011, M012, ...). Never modify or drop existing migrations. Schema additions allowed; column or table removal requires explicit phase + spec.
- **`team_keys` rotation history** is forever-retained — never garbage collected without explicit user action. Required for decrypting `presence_history` encrypted under past keys.

---

## 13. References

**Whitepaper (`leaf-docs.gundem.tech`):**
- `03-architecture/presence-relay.md` — envelope format, invite flow, rotation
- `03-architecture/share-controls.md` — admin symmetry, won't-list reinforcements
- `03-architecture/storage.md` — SQLCipher / WAL / 16-table schema
- `01-vision/wont-list.md` — admin override prohibitions, no shared backend
- `02-product/mvp-scope.md` — Phase 5 (W7-10) scope statement

**Code references (this repo):**
- `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M001..M005` — migration pattern (one file per migration, public DDL, `Schema.X` namespace)
- `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` — thin SQL helpers + `openForWrite` migration registration
- `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` — public namespace for table/column names
- `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` — `EnvelopeCodec` protocol + `UnimplementedEnvelopeCodec` placeholder

**Repo policy:**
- Root `CLAUDE.md` — pre-push moat checklist
- `.claude/shared/architecture.md` — current system snapshot
- `.claude/shared/conventions.md` — git workflow, "Работа вдвоём" coordination

---

*End of contract. Sub-project specs (5.1.A, 5.1.B, ...) live alongside this file in `docs/superpowers/specs/`.*
