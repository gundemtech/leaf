# Phase 5.5 — Decomposition: onboarding & team UX polish

**Status:** Active (2026-05-06). Phase 5.5 of Phase 5 ("team presence relay"). Decomposes whitepaper roadmap row 5.5 into sub-phases 5.5.A → 5.5.C.
**Owner:** Dmitrii.
**Stack:** branches off `main` (Phase 5.3 stack landed alpha.10/alpha.11 — 5.3 NOT pending merge anymore).

---

## 1. Context

Phase 5.3 stack (member removal + key rotation, alpha.10) и alpha.11 patch (`fix: replace hardcoded "Dmitrii Demidov" placeholder with NSFullUserName`) shipped. Pre-5.5 ревизия выявила что invite/accept flow — реальный adoption-blocker для real teams.

**7 UX-провалов** (упорядочены по severity):

1. **Mental model unclear**. Handshake требует двух OOB обменов (invitee→admin pubkey, admin→invitee token+OTP). UI не объясняет кто стартует первым (`GenerateInviteSheet.swift:73-99` "INVITEE SHARES THEIR PUBKEY WITH YOU" — а как именно?).
2. **Crypto-naked terminology**. "Pubkey" / "OTP" / 64-char hex выставлены как primary user-facing. Research по 1Password / Bitwarden / Signal / Element / Wire / Keybase: **все** mainstream E2E-приложения скрывают такие primitives за человекочитаемыми обёртками ("Secret Key" / "fingerprint phrase" / "safety number" / "@username").
3. **Two separate share-things**. Admin копирует token и OTP отдельно. Mainstream SaaS (Slack/Discord/Notion) универсально дают single shareable invite link.
4. **No pending invites surface**. Admin закрыл sheet → invite "пропал" (нельзя re-share / revoke / status check). 4 из 6 mainstream apps имеют persistent pending list (Slack, Linear, GitHub, Discord).
5. **Display name на Step 3** invitee accept flow (`AcceptInviteSheet.swift:150-156`) — оторвано от первичного share-flow.
6. **No waiting states**. У admin'а после Done нет видимости status'а; у invitee между Step 1 и Step 2 тоже без явного "ждём от admin'а" экрана.
7. **Onboarding asymmetry**. `.team` step предлагает только "Accept invite / Skip"; create-org живёт в `OrganizationView` empty-state. Новый admin проходит onboarding без явного "Create new team" CTA — невидимый путь.

**Источники правды (priority при противоречии):**
1. `2026-05-04-phase-5-architecture-contract.md` — §4 (identity), §6 (envelope), §8 (relay API surface — 5.5 НЕ расширяет).
2. `~/Desktop/Leaf/leaf-docs/docs/03-architecture/presence-relay.md` — public-truth invariants.
3. `2026-05-04-phase-5-2-decomposition.md` — 5.2 baseline для invite flow (which is being humanized).
4. UX research findings (см. §7 Out of scope для каких patterns не применимы).

---

## 2. Decisions taken (2026-05-06 brainstorm)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Bilateral handshake mental model** | Любая сторона стартует. Admin "Add member" может (a) paste invitee Join code если в clipboard, либо (b) отправить invitee pre-filled "ask to join" template. Invitee из onboarding `.team` → "Join existing team" → шарит свой Join code admin'у. Обе стороны имеют waiting state. Альтернативы: invitee-first only (рестриктивно — admin не может "позвать Антона"); admin-first via relay extension (требует /v1/invite/init-by-slot — out of scope). |
| D2 | **Three-way onboarding `.team` step** | "Create new team" / "Join existing team" / "Skip for now". OrganizationView empty-state остаётся fallback для Skip-пути. Альтернативы отвергнуты: "I have an invite / Skip" (не показывает Create CTA — disorientation для new admin). |
| D3 | **Standard humanization, no admin-confirm gate** | "Pubkey" → "Join code" (formatted base32-Crockford XXXX-XXXX-... + CRC32 checksum 4B). "OTP" → "Verification code" (формат 6 digits сохраняется). Crypto под капотом не меняется. Bitwarden-style admin-confirm gate с 5-word EFF phrase отложен (security hardening против OOB-MITM) → Phase 5.7 candidate. Альтернативы: keep-as-is (плохой UX); full Bitwarden gate (overkill для 5.5 polish). |
| D4 | **Single deep-link invite** `leaf://invite/<token>#<otp>` | Admin шлёт ОДНУ ссылку. Invitee клик → app open AcceptInviteSheet с auto-fill. Plus clipboard auto-detect on sheet open / app foreground (НЕ interval polling). OTP в URL fragment — не попадает в server access logs если ссылка попадёт в web. Альтернативы: formatted string `LEAF-<token>.<otp>` (нет magic); split (текущее, плохой UX). |
| D5 | **Local M010 `pending_invites` table** | SQLCipher table для admin-side pending tracking. {token PK, otp, invitee_pubkey_hex, invitee_display_name_hint, created_at_ms, expires_at_ms, status, last_polled_at_ms}. OTP at rest = OK (рядом с teamKey в same DB, no incremental risk). Альтернативы: relay state only (требует new endpoints); in-memory (теряется на restart); status quo (admin не может re-share после закрытия sheet). |
| D6 | **Display name на Step 1 + NSFullUserName default** | Invitee вводит/подтверждает display name на Step 1 share-flow alongside Join code. Embedded в pre-filled share-template ("Hi! I'm Anton, here's my Leaf Join code..."). Admin display name задаётся в "Create new team" inline form в onboarding (или OrganizationView empty-state form для Skip-пути). |
| D7 | **Manual [Refresh] для pending status** | Нет auto-poll loop в 5.5. TeamView "Pending invites" имеет [Refresh] button (section + per-row). Per click → batch GET pending tokens → 404 (KV consumed) = mark consumed. **Race**: admin GET съедает one-shot blob. Mitigation — UI copy "Refresh after your colleague tells you they opened the link". Auto-poll candidate Phase 5.6 (требует HEAD `/v1/invite/<token>` endpoint в leaf-relay = cross-repo). Альтернативы: auto-poll + relay extension (cross-repo coord); skip pending entirely (UX gap для admin). |
| D8 | **Sub-phases 5.5.A→C** mirror 5.1/5.2/5.3 discipline | Single-phase 5.5 too wide (M010 migration + new value types + 4 new view files + 4 view rewrites + URL scheme + clipboard auto-detect + pending list + Refresh logic). 3 sub-phases дают landing checkpoints + sub-rollback granularity. 5.5.A foundation (substrate), 5.5.B flow rewrites (UX surface), 5.5.C pending integration (admin recall). |
| D9 | **No relay extension в 5.5** | Existing `POST /v1/invite`, `GET /v1/invite/:token`, `DELETE /v1/invite/:token` достаточно (per §8 contract). HEAD endpoint для auto-poll → Phase 5.6 (отдельный PR в `gundemtech/leaf-relay`). Pubkey-mediated exchange endpoints → Phase 5.6+. |
| D10 | **Backwards compat для legacy hex Join codes** | `JoinCode.decode(_:)` принимает оба формата: formatted (`XXXX-XXXX-...-XXXX` 8 групп по 8 base32) и raw 64-char hex (legacy alpha.9-11 invitees могут paste старый формат во время transition). Lenient parse избегает регрессии для users в полёте. |

---

## 3. Sub-phase decomposition

| Sub-phase | Scope (declarative) | Branch | Cumulative tests |
|---|---|---|---|
| **5.5.A** | `JoinCode` value type (LeafCore) — encode/decode 32-byte pubkey ↔ formatted base32-Crockford with CRC32 checksum + lenient legacy hex accept. `InviteURL` value type (LeafCore) — `leaf://invite/<token>#<otp>` compose/parse. M010 `pending_invites` migration + `PendingInvitesStore` GRDB CRUD. Types-only, **no UI changes**, no service-level integration yet. | `feature/phase-5-5-A-foundation` off `main` | 860 → ≈885 |
| **5.5.B** | OnboardingView `.team` three-way restructure + `CreateTeamStepView` + `JoinTeamStepView` (Step 1 — display name + Join code share) + `WaitingForInviteView` (Step 1.5). `AcceptInviteSheet` rewrite (consume deep-link / clipboard, paste fallback, verification code, success). `GenerateInviteSheet` rewrite (paste Join code OR send template, single deep-link output, write `pending_invites`). `ShareTemplateButton` (Mail / Messages / Copy). `Info.plist` URL scheme + `InviteURLHandler` (URL scheme + clipboard auto-detect on app foreground / sheet open). `InviteService` + `InviteAcceptService` accept JoinCode in addition to raw hex. | stack on 5.5.A | ≈885 → ≈905 |
| **5.5.C** | `PendingInvitesSection` in TeamView + `PendingInviteRow`. `PendingInvitesReader` Observable + manual [Refresh] action (no background poller per D7). Per-row Re-share / Revoke. Status transitions (consumed via 404 batch poll, expired via local clock sweep on TeamView appear). UI badge updates. Re-share button reuses existing token/OTP from `pending_invites` row. | stack on 5.5.B | ≈905 → ≈920 |

**Total ship surface end-of-5.5:** Two-Mac onboarding из cold install (Mac A "Create new team" + Mac B "Join existing team") to live shared org occurs through **single deep-link** transmitted via mainstream OOB channel (Mail/Messages/Slack copy). Admin's TeamView shows Pending invites section с manual Refresh + Revoke. Wire surface unchanged (no relay extension).

---

## 4. Cross-phase invariants (locked here)

### 4.1 File / module layout

| Артефакт | Путь | Модуль |
|---|---|---|
| `JoinCode.swift` (value type) | `Packages/LeafCore/Sources/LeafCore/Crypto/JoinCode.swift` | LeafCore (public) |
| `InviteURL.swift` (value type) | `Packages/LeafCore/Sources/LeafCore/URLScheme/InviteURL.swift` | LeafCore (public) |
| `M010_PendingInvites.swift` | `Packages/LeafCore/Sources/LeafCore/Migrations/M010_PendingInvites.swift` | LeafCore (public) |
| `PendingInvitesStore.swift` | `Packages/LeafCore/Sources/LeafCore/Storage/PendingInvitesStore.swift` | LeafCore (public) |
| `PendingInviteStatus.swift` (enum) | `Packages/LeafCore/Sources/LeafCore/Storage/PendingInviteStatus.swift` | LeafCore (public) |
| `PendingInvitesReader.swift` | `Leaf/Models/PendingInvitesReader.swift` | Leaf app |
| `InviteURLHandler.swift` | `Leaf/AppLifecycle/InviteURLHandler.swift` | Leaf app |
| `CreateTeamStepView.swift` | `Leaf/Views/Onboarding/CreateTeamStepView.swift` | Leaf app |
| `JoinTeamStepView.swift` | `Leaf/Views/Onboarding/JoinTeamStepView.swift` | Leaf app |
| `WaitingForInviteView.swift` | `Leaf/Views/Onboarding/WaitingForInviteView.swift` | Leaf app |
| `ShareTemplateButton.swift` | `Leaf/Views/Common/ShareTemplateButton.swift` | Leaf app |
| `PendingInviteRow.swift` | `Leaf/Views/Window/Team/PendingInviteRow.swift` | Leaf app |
| `PendingInvitesSection.swift` | `Leaf/Views/Window/Team/PendingInvitesSection.swift` | Leaf app |

**Rewrites** (file path сохраняется): `OnboardingView.swift` (`.team` step), `AcceptInviteSheet.swift`, `GenerateInviteSheet.swift`, `TeamView.swift`, `InviteOutboxReader.swift`, `InviteService.swift`, `Info.plist`.

### 4.2 Schema — M010_PendingInvites

```sql
CREATE TABLE IF NOT EXISTS pending_invites (
  token                       TEXT PRIMARY KEY NOT NULL,
  otp                         TEXT NOT NULL,
  invitee_pubkey_hex          TEXT NOT NULL,
  invitee_display_name_hint   TEXT,
  created_at_ms               INTEGER NOT NULL,
  expires_at_ms               INTEGER NOT NULL,
  status                      TEXT NOT NULL DEFAULT 'pending',
  last_polled_at_ms           INTEGER
);
CREATE INDEX IF NOT EXISTS idx_pending_invites_status ON pending_invites(status);
```

`PendingInviteStatus` enum (5 кейсов): `pending` / `consumed` / `expired` / `revoked` / `failed`.

OTP at rest acceptable: same SQLCipher DB рядом с teamKey, no incremental risk.

### 4.3 JoinCode format (locked)

**Wire format** для clipboard / template / paste field:

```
XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-YYYY
```

- 8 групп по 8 chars base32-Crockford (excludes I/L/O/U for human readability) = 64 chars carrying 32-byte X25519 pubkey + 0 padding.
- Trailing 4-char `YYYY` = base32-Crockford-encoded CRC32 checksum (catches typos).
- Total visible: 64 + 1 separator + 4 = 69 chars + 8 hyphens = 77 chars.

**Decoder strict mode** (default for 5.5.A onwards): reject if checksum mismatches. **Lenient mode** (legacy compat per D10): accept raw 64-char hex string без separator/checksum, decode as raw X25519 pubkey, log warning, no checksum verify.

`JoinCode.encode(pubkey: Data) -> String` deterministic given same input. `JoinCode.decode(_: String) -> Result<Data, JoinCodeError>` returns 32-byte pubkey or error.

### 4.4 InviteURL format (locked)

```
leaf://invite/<token>#<otp>
```

- Scheme: `leaf` (registered in Info.plist `CFBundleURLTypes`).
- Host: `invite` (per-action discriminator — future `leaf://join`, `leaf://present` reserved).
- Path: `/<token>` где token = 32-char base64url (existing format from 5.2.D).
- Fragment: `<otp>` где otp = 6 digits string. Fragment не передаётся в HTTP referer / server logs если URL попадёт в web (browser strips fragment).

`InviteURL.compose(token:otp:) -> URL` constant string formatter.
`InviteURL.parse(_: URL) -> Result<(token: String, otp: String), InviteURLError>` strict matcher (non-matching → error).

### 4.5 Pre-filled message templates (RU + EN parity, polish при review)

Templates live в `ShareTemplateButton.swift` as static resource literals. `displayName` / `orgName` / `joinCode` / `inviteURL` interpolated at compose time.

**Admin → invitee "ask to join":**
```
Привет! Я добавляю тебя в Leaf team "<orgName>".

Чтобы присоединиться:
1. Скачай Leaf — https://leaf-docs.gundem.tech/install
2. Запусти, выбери "Join existing team"
3. Скопируй мне Join code который покажет приложение

Я пришлю invite link сразу как получу.
```

**Invitee → admin "here's my Join code":**
```
Привет! Я <displayName>, готов(а) присоединиться к Leaf team. Мой Join code:

<joinCode>

Жду от тебя invite link 🌿
```

**Admin → invitee "here's your invite link":**
```
Привет <displayName>! Вот твой Leaf invite link (действует 24 часа):

<inviteURL>

Кликни — Leaf откроется и подхватит автоматически.
```

`ShareTemplateButton` channels: **Copy** (full template to clipboard via NSPasteboard), **Mail** (`mailto:?subject=…&body=…`), **Messages** (`sms:?&body=…`). Slack/Telegram/Discord URL schemes недокументированы / not bundled-app-detectable — generic Copy.

### 4.6 LeafError additions (per sub-phase)

5.5.A: `joinCodeMalformed`, `joinCodeChecksumMismatch`, `inviteURLMalformed`.
5.5.B: `inviteAlreadyConsumed` (если 404 на accept), `pasteboardEmpty`, `clipboardNoMatch`.
5.5.C: `pendingInviteNotFound`, `pendingInviteAlreadyRevoked`.

### 4.7 Test target conventions

| Target | Existing baseline (post-5.3) | After 5.5 end |
|---|---|---|
| `LeafCoreTests` | 860 | ≈920 |
| `LeafCorePrivateTests` | ≥45 | ≈45 (no new moat in 5.5) |
| `LeafTests` (UI) | TBD | +SwiftUI snapshot для new views где applicable |

Patterns:
- 5.5.A unit: JoinCode roundtrip / typo detection / lenient hex / InviteURL parse strict + edge cases (extra fragment chars, missing OTP, wrong scheme); migration up + idempotent re-run + rollback handling.
- 5.5.B integration: `InviteURLHandler` route → AcceptInviteSheet pre-fill assertion; clipboard auto-detect with mock pasteboard; share-template compose with displayName / orgName edge cases (empty, emoji, very long).
- 5.5.C integration: PendingInvitesReader [Refresh] action with mock RelayClient (200 / 404 / 410 paths); revoke roundtrip; expired auto-transition local sweep.

### 4.8 Manual smoke gate before 5.5 ship

Two-Mac smoke (золотой path post-5.5.C):

1. **Mac A new install** → onboarding → `.team` → "Create new team" → name+display → `.done` → TeamView empty.
2. **Mac A** → TeamView "Invite member" → no clipboard match → "Send template" tab → Mail / Copy → admin шлёт template Mac B.
3. **Mac B new install** → onboarding → `.team` → "Join existing team" → display name (default NSFullUserName) → Join code visible (formatted XXXX-…) → "Copy & Share" → Mac A.
4. **Mac A** → clipboard auto-detect Join code at app foreground → "Invite member" → paste pre-filled → "Generate invite" → видит deep-link → Copy or Mail → шлёт Mac B.
5. **Mac B** → WaitingForInviteView → clicks deep-link OR app foreground clipboard auto-detect → AcceptInviteSheet auto-fills → Verification code (6 digits) entered → success → join.
6. **Mac A** → TeamView pending row → [Refresh] → marks consumed (relay 404).
7. **Mac A** revokes another pending invite → relay DELETE 204 → row marked revoked → Mac B accepting тот token → 404 → friendly error "Invite was revoked or expired".

---

## 5. Critical files to read before each sub-phase

| File | Why |
|---|---|
| `2026-05-04-phase-5-architecture-contract.md` (§4, §6, §8) | Contract invariants 5.5 obeys (no relay extension) |
| `2026-05-04-phase-5-2-decomposition.md` | 5.2 baseline для invite flow being humanized |
| `2026-05-04-phase-5-2-D-invite-service-ui.md` | Existing GenerateInviteSheet design (rewrite target) |
| `Packages/LeafCore/Sources/LeafCore/Migrations/M009_RotationOutbox.swift` | M010 mirrors this pattern |
| `Packages/LeafCore/Sources/LeafCore/Team/InviteService.swift` | 5.5.B: accept JoinCode in addition to raw hex |
| `Packages/LeafCore/Sources/LeafCore/Team/InviteAcceptService.swift` | 5.5.B: hookup new flow steps |
| `Packages/LeafCore/Sources/LeafCore/Network/RelayClient.swift` | 5.5.C: existing endpoints surface, no extension |
| `Leaf/Views/Window/Team/GenerateInviteSheet.swift` | 5.5.B rewrite target |
| `Leaf/Views/Window/Organization/AcceptInviteSheet.swift` | 5.5.B rewrite target |
| `Leaf/Views/OnboardingView.swift` (`.team` step `:156-172`) | 5.5.B rewrite target |
| `Leaf/Models/InviteOutboxReader.swift`, `InviteAcceptReader.swift` | 5.5.B state machines |
| `Leaf/Views/Window/Team/TeamView.swift` | 5.5.C: + PendingInvitesSection |

---

## 6. Verification gate before ship

End-of-Phase-5.5 (after 5.5.C ship), before alpha bump:

```bash
cd ~/Desktop/Leaf/leaf/Packages/LeafCore && swift test  # ≈920+ pass
cd ~/Desktop/Leaf/leaf
xcodebuild -scheme Leaf            -configuration Debug build  # SUCCESS (×5 schemes)
xcodebuild -scheme LeafAgent       -configuration Debug build
xcodebuild -scheme LeafMCP         -configuration Debug build
xcodebuild -scheme LeafCore        -configuration Debug build
xcodebuild -scheme LeafCorePrivate -configuration Debug build

# Pre-push moat scan
/pre-push-leaf

# Two-Mac smoke (см. §4.8) — manual, canonical "did 5.5 actually ship" gate

# leaf-docs sync
git -C ~/Desktop/Leaf/leaf-docs pull --ff-only
# Append changelog entry "5.5 — onboarding & team UX polish (deep-link invite, JoinCode, pending list)" + push
```

---

## 7. Out of scope for 5.5 (deferred)

| Excluded | Why | Reserved for |
|---|---|---|
| Relay extension для pubkey-mediated exchange (`/v1/invite/init-by-slot` + `/v1/invite/<token>/register-pubkey`) | Removes 1 OOB shot but требует cross-repo coord (gundemtech/leaf-relay) | Phase 5.6 |
| HEAD `/v1/invite/<token>` endpoint для auto-poll pending status | Cross-repo coord; manual Refresh sufficient для 5.5 | Phase 5.6 |
| Bitwarden-style admin-confirm gate с 5-word EFF phrase | Security hardening против OOB-MITM на Slack DM (security != UX polish) | Phase 5.7 candidate |
| Recovery Kit PDF (1Password Emergency Kit pattern) | Wow-moment, not adoption-blocker | v1.1+ |
| QR code invite (camera scan) | Нет camera flow на macOS desktop | v1.5+ (iOS) |
| Invite via Slack bot / Telegram bot | Out-of-band sufficient | v1.5+ |
| Custom invite roles (admin/member/guest) | Single-org-per-device contract = symmetric members | post-MVP |
| Multi-org membership на одном Mac | Phase 5 contract §4 single-org-per-device invariant | future major (v2) |
| In-app activity log "who invited whom + when accepted" | Acceptable not surface; presence_outgoing audit log в 5.4 covers presence only | v1.1+ |

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| **Deep-link first-time wiring** — Info.plist + AppDelegate + NSAppleEventManager fall-back. Fresh Leaf впервые регистрирует URL scheme. | 5.5.B includes fresh-install testing in two-Mac smoke; LSRegisterURL fallback (`lsregister -f`) documented в feedback memory. |
| **Clipboard auto-detect timing** — macOS не имеет push для NSPasteboard; auto-detect happens только on sheet open + on `applicationDidBecomeActive`. | Document in UI: "Open Leaf after admin sends invite link — your invite will appear automatically." Не interval polling. |
| **SQLCipher migration M010 на existing alpha-ring users** | Forward-only `CREATE TABLE IF NOT EXISTS` (mirrors M009). Idempotent re-run test in 5.5.A. |
| **Manual Refresh race** — admin Refresh'нул раньше invitee fetch → admin GET съел one-shot blob → invitee получает 404. | UI copy "Refresh after your colleague tells you they opened the link"; Re-share button reuses cached token/OTP from `pending_invites` для re-issuance путь. Phase 5.6 решает via HEAD endpoint. |
| **Backwards compat для legacy hex Join codes** (alpha.9-11 invitees могут paste raw 64-char hex) | `JoinCode.decode` lenient mode принимает raw hex (no checksum), logs warning. Admin sees no difference в downstream (still passes 32-byte pubkey to `InviteService`). |
| **Display name embedded в pre-filled template** — emoji / unicode / multi-line names corrupt mailto:/sms: URL encoding. | Templates compose через `URLComponents` percent-encoding; reject newlines в displayName при input validation; emoji safe (UTF-8 percent-encode). |
| **Phase 5.3 awaiting smoke стало stale** — current-state.md memory говорит "NOT MERGED" но git log показывает alpha.10 ship'нул всё | Memory updated в 5.5.A landing commit (`docs(shared): Phase 5.5.A landed — current-state update`). |
| **Leak via deep-link URL во время copy/paste** — token+OTP visible in clipboard managers / screen recording | Acceptable — same risk surface as text-based token+OTP сегодня; OOB transmission остаётся юзерской ответственностью. UX copy предупреждает о 24h expiry. |
| **Token reuse если admin Re-share** — re-share одного и того же token+OTP не нарушает crypto (token one-shot consume-by-relay; OTP-protected blob unwrap on accept). | Confirmed safe: re-share = re-display same row from `pending_invites`. Admin generates new invite (= new row, new token) если предыдущий expired/consumed. |

---

*End of decomposition. Sub-phase specs (5.5.A immediately, B-C in their own sessions per "Одна phase = одна сессия") live alongside contract в `docs/superpowers/specs/`.*
