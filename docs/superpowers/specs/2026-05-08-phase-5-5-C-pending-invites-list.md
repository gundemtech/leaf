# Phase 5.5.C — Pending invites list (admin recall surface)

**Status:** Active (2026-05-07).
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-5-B-flow-rewrites` (off `feature/phase-5-5-A-foundation` off `main`, alpha.11 baseline). Branch name: `feature/phase-5-5-C-pending-invites-list`. NOT merged immediately — стэк 5.5.{A,B,C} мерджим коллективным решением в конце, после two-Mac smoke gate (§4.8 в decomposition).
**Cumulative tests baseline:** 989 SPM (post-5.5.B). End-of-5.5.C target: ≈1000-1010.

---

## 1. Context

Phase 5.5.A заложила substrate (M010 `pending_invites` table + `JoinCode` + `InviteURL` value types + `PendingInvitesStore` CRUD). Phase 5.5.B построила UX layer первого generate/accept flow и подключила `InviteOutboxReader.persistPendingInvite` (пишет row на `.pending` после relay 201) + `markPendingInviteRevoked` (mark `.revoked` при `revokeAndDismiss` из active GenerateInviteSheet).

После 5.5.B в DB накапливаются rows но **нигде в UI они не surface'ятся**. Admin закрыл sheet → invite "потерян" — нет re-share, нет revoke вне active sheet, нет status check. Это adoption-blocker (decomposition §1 UX-fail #4).

Phase 5.5.C закрывает этот gap: admin TeamView получает `PendingInvitesSection` с per-row actions + manual `[Refresh]` для batch-poll status'ов через `RelayClient.getInvite(token:)` (404 = consumed). Relay surface не расширяется (per decomposition D9). Auto-poll loop отложен (D7) — manual только.

**Источники правды (priority при противоречии):**
1. `2026-05-04-phase-5-architecture-contract.md` §4 (identity), §6 (envelope), §8 (relay API surface — 5.5.C НЕ расширяет).
2. `2026-05-06-phase-5-5-decomposition.md` §3 row 5.5.C, §4 invariants, §7 out-of-scope, §8 risks.
3. `~/Desktop/Leaf/leaf-docs/docs/03-architecture/presence-relay.md` — public-truth invariants.

---

## 2. Decisions taken (2026-05-07 brainstorm)

| # | Decision | Rationale |
|---|---|---|
| **D1** | **`.consumed` rows авто-hidden из UI list через DB-level filter (`WHERE status != 'consumed'`).** Row остаётся в `pending_invites` table как audit trail (никогда не deleted на consume — invitee уже member, дубль виден в `team_members`). | Mainstream pattern (Slack / Linear). Match'ит admin's mental model — "row исчез значит colleague joined". List остаётся compact для активных команд. |
| **D2** | **Терминальные `.revoked` / `.expired` / `.failed` rows показываются с per-row [Dismiss] action → hard DELETE row из DB.** | Дают явный sign-off "я увидел этот результат". DELETE безопасен — terminal status уже non-revertable, audit trail в DB не нужен (relay уже выпустил token, recovery невозможен). |
| **D3** | **[Re-share] = inline ShareTemplateButton popover (Mail / Messages / Copy URL).** Reuses 5.5.B компонент. НЕ открывает GenerateInviteSheet. Token+OTP читаются из cached row, deep-link composes via `InviteURL.compose(token:otp:)`. Третий template "here's your invite link, <displayName>" использует placeholder `"your colleague"` если `inviteeDisplayNameHint` nil. | Re-share use-case = "тому же колеге пошлю ссылку ещё раз тем же каналом". Inline popover держит row компактным в idle, переиспользует существующий компонент, не лезет в GenerateInviteSheet (он остаётся чисто first-generate surface'ом с paste/template Picker tabs). DisplayName capture отложен (см. D7). |
| **D4** | **[Revoke] = one-click без confirm modal.** Row immediately transition'ит `.pending → .revoked` (UI feedback), Task launches `RelayClient.deleteInvite(token:)` best-effort + `db.updatePendingInviteStatus(.revoked)` в фоне. Mirror `InviteOutboxReader.revokeAndDismiss` precedent. | Действие cheaply-recoverable (admin re-генерирует через "Add member" → fresh token+OTP+row). Confirm modal добавляет friction без protective value. Match'ит Slack/Discord UX. Best-effort relay = local truth wins (если DELETE failed network'ом — token и так one-shot, но relay отдаст stale blob теперь только original invitee). |
| **D5** | **[Refresh] = section-level batch only (НЕ per-row).** Single button в section header → loop по `.pending` rows → `RelayClient.getInvite(token:)` per row → 200 update `lastPolledAtMs`, 404 (`inviteNotFound`) → mark `.consumed`, other → log + leave row alone. | YAGNI per-row. Section batch — atomic UX "проверить всё одним кликом". Per-row кандидат на 5.5.D если adoption покажет need. |
| **D6** | **Section ordering в TeamView**: members list → `PendingInvitesSection` (rendered только если есть visible rows) → `[Add member]` CTA. **Empty state** = section полностью hidden (не рендерим placeholder). | Pending invites — extension of "team membership" view, естественный flow read-down "active → pending → invite new". Hidden-when-empty = mainstream pattern (Slack / GitHub). |
| **D7** | **`inviteeDisplayNameHint` capture отложен в 5.5.D.** В 5.5.C `InviteOutboxReader.persistPendingInvite` продолжает писать `nil` (5.5.B legacy behavior). Row label + 3rd "here's your invite link" template fallback'ит на `"your colleague"`. | Capture требует input field в `GenerateInviteSheet` (admin вводит "Who is this?" optional после paste/generate) — нетривиально, отдельная UX-итерация. Скоупно вне 5.5.C. Если post-ship UX почувствует gap — кандидат на 5.5.D refinement. |
| **D8** | **Expired sweep trigger**: `TeamView.onAppear` AND post-`[Refresh]`. Single `UPDATE pending_invites SET status='expired' WHERE status='pending' AND expires_at_ms < ?nowMs`. | Sync DB write (~ms). Two natural moments когда admin смотрит список → cheap sweep до render. Без background scheduler (per D7 decomposition — auto-poll отложен). |

---

## 3. Scope

| Item | Detail |
|---|---|
| **`PendingInvitesService.swift`** (new, LeafCore) | Pure orchestrator over Database + RelayClient. Methods: `loadVisible() throws -> [PendingInvite]`, `pollPending() async throws -> PollOutcome`, `revoke(token:) async throws`, `dismiss(token:) throws`. Inject'абельный (Database + RelayClient + `now: @Sendable () -> Date`). |
| **`PendingInvitesReader.swift`** (new, Leaf target) | `@MainActor @Observable` обёртка. State machine: `.loading` / `.loaded(rows:)` / `.error(message:)`. Lazy-init Database + RelayClient + service mirror `InviteOutboxReader` pattern. Methods: `refresh()`, `poll()`, `revoke(token:)`, `dismiss(token:)`. |
| **`PendingInvitesSection.swift`** (new, Leaf/Views/Window/Team) | Section header (`"PENDING INVITES · N"` + `[Refresh]` button) + `ForEach(rows)` of `PendingInviteRow` + section-level error banner if `state == .error`. |
| **`PendingInviteRow.swift`** (new, Leaf/Views/Window/Team) | Row layout: invitee label (`displayNameHint` or `"your colleague"`) + short-pubkey hex + status badge with colour + per-status action cluster. |
| **Database extension wrappers** (edit `LeafCore/DB/Database.swift`) | + `readAllPendingInvites() throws -> [PendingInvite]` (filter consumed). + `readAllPendingInvitesByStatus(_ status:) throws -> [PendingInvite]` (used by poll). + `deletePendingInvite(token:) throws`. + `updatePendingInviteLastPolledAt(token: atMs:) throws`. + `sweepExpiredPendingInvites(nowMs:) throws -> Int`. |
| **`PendingInvitesStore.swift`** (edit) | + Static `sweepExpired(nowMs: in db:) throws -> Int` SQL helper. Existing CRUD untouched. |
| **`LeafError.swift`** (edit) | + `pendingInviteNotFound`, + `pendingInviteAlreadyRevoked` per §4.6 decomposition. |
| **`TeamView.swift`** (edit) | Wire `@Environment(PendingInvitesReader.self) var pendingReader`. `.onAppear` → `pendingReader.refresh()`. `.loaded(_, members)` content arm: insert `PendingInvitesSection()` between `membersList(members)` and `[Add member]` button когда `pendingReader.state` имеет non-empty rows. |
| **`LeafApp.swift`** (edit) | Env-inject `PendingInvitesReader` instance в Window scene (mirror `OrgReader`). |

---

## 4. Cross-phase invariants reaffirmed

### 4.1 File layout (matches §4.1 в decomposition + new files)

| Артефакт | Путь | Модуль |
|---|---|---|
| `PendingInvitesService.swift` | `Packages/LeafCore/Sources/LeafCore/Team/PendingInvitesService.swift` | LeafCore (public) |
| `PendingInvitesReader.swift` | `Leaf/Models/PendingInvitesReader.swift` | Leaf app |
| `PendingInvitesSection.swift` | `Leaf/Views/Window/Team/PendingInvitesSection.swift` | Leaf app |
| `PendingInviteRow.swift` | `Leaf/Views/Window/Team/PendingInviteRow.swift` | Leaf app |
| `PendingInvitesServiceTests.swift` | `Packages/LeafCore/Tests/LeafCoreTests/PendingInvitesServiceTests.swift` | LeafCoreTests |
| `Database+PendingInvites5_5_C_Tests.swift` | `Packages/LeafCore/Tests/LeafCoreTests/Database+PendingInvites5_5_C_Tests.swift` | LeafCoreTests |

### 4.2 Schema (no migration in 5.5.C)

M010 (5.5.A) уже создал `pending_invites` table + index `idx_pending_invites_status`. 5.5.C не добавляет колонок и не делает migration.

### 4.3 SQL additions (in `PendingInvitesStore` + Database wrappers)

```sql
-- readAllPendingInvites (filter consumed for UI list)
SELECT token, otp, invitee_pubkey_hex, invitee_display_name_hint,
       created_at_ms, expires_at_ms, status, last_polled_at_ms
FROM pending_invites
WHERE status != 'consumed'
ORDER BY created_at_ms DESC;

-- readAllPendingInvitesByStatus (for poll loop)
SELECT ...same columns...
FROM pending_invites
WHERE status = ?
ORDER BY created_at_ms DESC;

-- sweepExpiredPendingInvites
UPDATE pending_invites
SET status = 'expired'
WHERE status = 'pending' AND expires_at_ms < ?;

-- deletePendingInvite already exists in PendingInvitesStore.delete (5.5.A) —
-- only need Database wrapper.

-- updatePendingInviteLastPolledAt already exists in
-- PendingInvitesStore.updateLastPolledAt (5.5.A) — only need Database wrapper.
```

### 4.4 LeafError additions (per §4.6 в decomposition)

```swift
case pendingInviteNotFound        // poll/dismiss/revoke на token которого нет в DB (race с concurrent dismiss)
case pendingInviteAlreadyRevoked  // revoke на row уже в .revoked (idempotent guard)
```

Both cases — informational, не surface'ятся юзеру (no `userFacingMessage` mapping). Reserved per decomposition §4.6 contract: текущий 5.5.C `PendingInvitesService` favours silent idempotent no-op (через `PendingInvitesStore.updateStatus` / `delete` natively-idempotent semantics) — cases остаются available для future stricter callers (например debug-уровень assertions, или внутренний contract violation surface). Если leak'ают в UI (баг) — общий fallback "Couldn't update invite. See Console for details." покрывает.

### 4.5 PendingInvitesService API (locked)

```swift
public struct PendingInvitesService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let now: @Sendable () -> Date

    public init(
        database: Database,
        relayClient: RelayClient,
        now: @escaping @Sendable () -> Date = { Date() }
    )

    /// Sweep expired then return rows visible to UI (excludes .consumed).
    public func loadVisible() throws -> [PendingInvite]

    /// Sweep expired, then GET each .pending row from relay,
    /// transitioning .consumed via 404. Returns counts for surface-level toast.
    public func pollPending() async throws -> PollOutcome

    /// Best-effort relay DELETE + local status update.
    public func revoke(token: String) async throws

    /// Hard DELETE row (used for [Dismiss] terminal-state cleanup).
    public func dismiss(token: String) throws
}

public struct PollOutcome: Sendable, Equatable {
    public let consumed: Int          // newly transitioned .pending → .consumed (404)
    public let stillPending: Int      // still .pending after poll
    public let networkErrors: Int     // tokens skipped due to transport / 5xx
}
```

### 4.6 PendingInvitesReader state machine (locked)

```swift
@MainActor @Observable
final class PendingInvitesReader {
    enum State: Equatable {
        case loading
        case loaded(rows: [PendingInvite])
        case error(message: String)
    }
    private(set) var state: State = .loading

    /// Sync sweep + readVisible. Идempotent — safe to call from .onAppear.
    func refresh()

    /// Async poll loop (Refresh button). Mid-flight rows still rendered;
    /// completion triggers new state.
    func poll()

    func revoke(token: String)
    func dismiss(token: String)
}
```

`InviteOutboxReader` lazy-init pattern + `#if LEAF_PROD` config injection точно повторён.

### 4.7 UX details (locked)

**Section header:**
```
PENDING INVITES · N        [↻ Refresh]
```
- N = visible rows count.
- `[↻ Refresh]` button disabled во время `poll()` flight, показывает inline ProgressView.

**Per-row layout (PendingInviteRow):**
```
[avatar?] <displayNameHint or "your colleague">      [status badge]
         <pub-prefix>…<pub-suffix>                   [actions]
```

**Status badges + actions per status:**
| Status | Badge text | Badge colour | Actions |
|---|---|---|---|
| `.pending` | "Awaiting" | accent (yellow/amber) | `[↗ Re-share]` popover (Mail/Messages/Copy) + `[× Revoke]` |
| `.revoked` | "Revoked" | leafInk.opacity(0.5) | `[Dismiss]` |
| `.expired` | "Expired" | leafInk.opacity(0.5) | `[Dismiss]` |
| `.failed` | "Failed" | red.opacity(0.7) | `[Dismiss]` |
| `.consumed` | _(never rendered, filtered at DB level)_ | — | — |

**Re-share popover content** (reuses `ShareTemplateButton` from 5.5.B):
- Body interpolates 3rd template (admin → invitee "here's your invite link") with `displayName = inviteeDisplayNameHint ?? "your colleague"` + `inviteURL = InviteURL.compose(token: row.token, otp: row.otp)`.

**Empty state:** section полностью hidden (no header, no placeholder) когда `rows.isEmpty`.

**Refresh outcome surface:** post-poll'а — toast или inline section banner с copy "Checked N invites — M consumed, K still awaiting" (выбор toast vs banner — implementation detail, не лочим). Стандартный pattern спрашиваем у `WindowState` toast queue если он существует, иначе inline banner.

### 4.8 Re-share token re-use safety

Token one-shot consume на relay-стороне — повторный `[Re-share]` не нарушает crypto (per decomposition §8 "Token reuse" risk row). DELETE issued by [Revoke] на relay → последующий GET вернёт 404 (correctly maps to `.revoked` уже local). Если admin Re-share после своего собственного [Revoke] — token уже revoked локально, row уже не в `.pending` → action cluster показывает только [Dismiss], Re-share button даже не виден.

---

## 5. Test plan

### 5.1 LeafCoreTests additions (≈10-12 tests)

**`PendingInvitesServiceTests.swift`:**
- `testLoadVisibleFiltersConsumed` — insert 5 rows w/ mixed status, expect readAll returns NON-consumed only, sorted DESC by created_at.
- `testLoadVisibleSweepsExpired` — insert pending rows w/ expires_at < now, loadVisible() → those flip to .expired в DB и в результате.
- `testPollPending200KeepsPending` — mock RelayClient returns InviteFetched, status stays .pending, lastPolledAtMs updated.
- `testPollPending404MarksConsumed` — mock returns `LeafError.inviteNotFound`, status flips .consumed.
- `testPollPendingMixedOutcomes` — 3 rows: 200 / 404 / transport-error → `PollOutcome(consumed: 1, stillPending: 1, networkErrors: 1)`.
- `testRevokeBestEffort` — mock relay returns 204 → DB status .revoked.
- `testRevokeRelayFailureLocalTruth` — mock throws relayUnreachable → DB still .revoked (best-effort).
- `testDismissDeletesRow` — insert + dismiss + read returns nil.
- `testRevokeNonexistentTokenIdempotent` — revoke('nonexistent') → no throw (idempotent silent no-op за счёт updateStatus silent semantics).

**`Database+PendingInvites5_5_C_Tests.swift`:**
- `testReadAllPendingInvitesFiltersConsumed`
- `testReadAllPendingInvitesByStatus`
- `testSweepExpiredPendingInvitesAffectedCount` — returns affected row count, idempotent re-run returns 0.
- `testDeletePendingInviteIdempotent` — delete missing token = no throw.
- `testUpdatePendingInviteLastPolledAt`

### 5.2 LeafTests (UI snapshot tests)

Опускаем для 5.5.C MVP — manual smoke в two-Mac gate (decomposition §4.8) covers UI golden + edge. UI snapshot patterns не established в Leaf target.

### 5.3 Manual smoke (5.5.C-specific, additive к decomposition §4.8)

После 5.5.B golden path:
1. **Mac A** generates invite → row appears in PendingInvitesSection с status "Awaiting".
2. **Mac A** click [↗ Re-share] на row → popover Mail/Messages/Copy → Copy → clipboard содержит deep-link `leaf://invite/...#...` идентичный тому что Mac B получил первый раз.
3. **Mac A** click [× Revoke] на row → row immediately transitions to "Revoked" state с [Dismiss] action; relay DELETE fires в фоне (network logs).
4. **Mac A** click [↻ Refresh] section button → batch poll runs → если Mac B уже accepted (relay вернёт 404) → row's status flips `.pending → .consumed` в DB → row пропадает из UI на следующем `loadVisible` (исключается DB-level filter `WHERE status != 'consumed'`); если invitee ещё не accepted → row остаётся в "Awaiting", `lastPolledAtMs` обновляется.
5. **Mac A** ждёт 24h+1m → `[Refresh]` или re-open Team tab → expired sweep на appear → row "Awaiting" → "Expired".
6. **Mac A** click [Dismiss] на terminal row → row уходит из UI и DB (`PendingInvitesStore.delete`).

---

## 6. Verification gate before ship

```bash
# LeafCore tests
cd ~/Desktop/Leaf/leaf/Packages/LeafCore && swift test  # ≈1000-1010 pass

# 5/5 schemes build
cd ~/Desktop/Leaf/leaf
xcodebuild -scheme Leaf            -configuration Debug build
xcodebuild -scheme LeafAgent       -configuration Debug build
xcodebuild -scheme LeafMCP         -configuration Debug build
xcodebuild -scheme LeafCore        -configuration Debug build
xcodebuild -scheme LeafCorePrivate -configuration Debug build

# Manual UI smoke (golden path §5.3 + edge cases)
# Pre-push moat scan
/pre-push-leaf
```

**Stack-level smoke** (after 5.5.C merge readiness — выполняется когда коллективно решаем мержить весь стэк): two-Mac smoke per decomposition §4.8 (full 7-step golden path end-to-end).

Branch не мерджим в `main` сразу — push'аем в origin как stage. Решение про merge всего стэка 5.5.{A,B,C} принимаем после two-Mac smoke gate.

---

## 7. Out of scope (deferred to 5.5.D / 5.6)

| Excluded | Why | Reserved for |
|---|---|---|
| Auto-poll loop (HEAD `/v1/invite/<token>`) | Requires cross-repo `gundemtech/leaf-relay` extension | Phase 5.6 |
| Per-row [Refresh] button | YAGNI for MVP — section batch sufficient | 5.5.D candidate если adoption покажет need |
| `inviteeDisplayNameHint` capture в GenerateInviteSheet | Требует input field "Who is this?" + UX itération | 5.5.D candidate |
| Surface "Joined N min ago" ghost row для `.consumed` | Тестируем без — `team_members` row сам по себе affirmation | 5.5.D candidate |
| Bulk actions (Revoke all expired / Dismiss all terminal) | Adoption-pace надо оценить | post-MVP |
| Pending invites UI snapshot tests | Pattern не установлен в Leaf target — manual smoke covers MVP | post-MVP test infra |
| Background scheduler (periodic poll without UI trigger) | Per D7 — manual только в 5.5 | Phase 5.6 |
| Toast queue via WindowState | Если не существует в codebase — inline banner fallback | post-MVP UI infra |

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| **Refresh race** — admin Refresh съедает one-shot blob, invitee получает 404 на accept attempt | Documented в decomposition §8 Risk row "Manual Refresh race". UI hint copy в section header: "Refresh after your colleague tells you they opened the link". Re-share button reuses same token+OTP — admin может re-issue ту же ссылку, относительно безопасно (relay вернёт same blob если ещё не consumed by GET). Phase 5.6 решает via HEAD endpoint. |
| **Concurrent dismiss + poll** — admin dismiss'нул row пока poll loop в полёте → poll updates row которого нет → silent no-op via `PendingInvitesStore.updateStatus` semantics | `updateStatus` silent no-op gracefully handles. Test coverage: `testRevokeNonexistentTokenIdempotent`. |
| **Best-effort revoke relay DELETE failure** — DB говорит `.revoked` но relay still hosts blob | Mirror `InviteOutboxReader.revokeAndDismiss` precedent — log error, не roll back local. Token one-shot consume by `memberPubkeyHex`-bound — only original invitee может GET, OTP-binding crypto держит row сам. Operational risk — низкий. |
| **DB write contention** — pollPending делает N writes к `pending_invites` одной transaction'ой? Или per-row? | Per-row write через existing `Database.updatePendingInviteStatus` / `updatePendingInviteLastPolledAt` (каждый wraps `pool.write {}`). Цена: N pool.write для N rows. Acceptable для MVP (typically N≤5 для small team). Если adoption покажет >50 pending одновременно — batch SQL refactor. |
| **Display name "your colleague" weirdness в RU template** | RU template fallback: "колегу" заменён на "коллегу" placeholder если displayName nil. Спецификация template — `ShareTemplateButton.swift` (5.5.B), 5.5.C только passes displayName arg. Edge case (RU + unicode + emoji в hint, когда мы добавим capture в 5.5.D) — covered patterns в 5.5.B test suite. |
| **TeamView `.onAppear` double-trigger** — sweep runs twice on rapid tab switch | Sweep idempotent (UPDATE WHERE expires_at_ms < ? — monotonic). Test: `testSweepExpiredPendingInvitesAffectedCount` re-run returns 0. Performance — sub-ms even с N=100. |
| **Relay 5xx during Refresh** — partial poll outcome | `PollOutcome.networkErrors` count'ит пропущенные tokens. UI surface'ит non-blocking toast/banner "Refresh ran into network issue, X invites couldn't be checked. Try again later." Row не транзишится → остаётся .pending до следующего успешного poll. |

---

## 9. Implementation order (TBD при writing-plans)

Plan-level decomposition будет в `.claude/plans/phase-5-5-C.md` в следующей сессии (TDD per step, sequential commits). Estimated 8-10 atomic commits:

1. LeafCore — `LeafError` cases + `PendingInvitesStore.sweepExpired` + Database wrappers + tests.
2. LeafCore — `PendingInvitesService` + tests.
3. Leaf — `PendingInvitesReader` Observable + lazy-init pattern.
4. Leaf — `PendingInviteRow` + status badges layout.
5. Leaf — `PendingInvitesSection` + Refresh button + section header.
6. Leaf — TeamView wiring (env + onAppear + section rendering).
7. Leaf — LeafApp env injection.
8. Manual smoke + bug-fix commits as needed.

Final commits: review fixes (Stage 6), `docs(shared): Phase 5.5.C landed — current-state update`.

---

*End of spec. Plan-level breakdown lives in `.claude/plans/phase-5-5-C.md` (writing-plans skill output, separate session).*
