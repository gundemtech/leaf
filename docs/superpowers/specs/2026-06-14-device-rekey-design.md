# Device re-key — recovery для `accountBoundToDifferentDeviceKey`

**Дата:** 2026-06-14 · **Трек:** 5 (account-login) · **Автор сессии:** Anton (Mac)
**Связано:** [[2026-06-09-account-login-unified-supabase-design]] (#68 single-device guard), GUN-63 (соседний баг логина).

---

## 1. Проблема

Account-login (#68 `74a58a78`) ввёл проверку на логине: JWT несёт `pubkey`-claim (ключ устройства, привязанный к аккаунту на сервере), клиент сверяет его с локальным ключом этого Mac (`requireClaimMatchesLocalKey`, `SupabaseClient.swift`). Две разные ошибки при несовпадении:

| ошибка | смысл | recovery сейчас |
|---|---|---|
| `deviceKeyOwnedByAnotherAccount` | ключ **этого Mac** уже занят другим аккаунтом | ✅ есть: `.deviceConflict` → «Reset & Continue» → `resetIdentityAndRetry` (удалить локальную identity → register заново) |
| `accountBoundToDifferentDeviceKey` | **аккаунт** привязан к ключу другого устройства | ❌ нет (`.error`, текст «войди с того Mac, где настраивал»; код прямо пишет «reset не поможет») |

Второй случай **без пути восстановления**. Реальный триггер: юзер потерял/переустановил Mac или сбросил keystore (`~/Library/Application Support/Leaf/keystore/x25519.priv`) — аккаунт на сервере держит старый ключ, а текущее устройство имеет другой → юзер навсегда залочен из своего аккаунта.

(Антон поймал это локально по другой причине — Debug-сборка живёт в namespace `Leaf-Debug` со своим ключом; на боевом подписанном app логин проходит. Но product-дыра реальна для prod-юзеров.)

## 2. Решение (approach A — утверждено)

Дать `accountBoundToDifferentDeviceKey` явный, подтверждаемый юзером **re-key**: «сделать ЭТОТ Mac активным устройством аккаунта». Сервер перепривязывает аккаунт на текущий ключ; старое устройство теряет валидность claim'а (по сути выходит из аккаунта). **Доступ к командным воркспейсам обнуляется** — юзер переинвайтится (см. §3). Это консистентно с семантикой существующего reset (он тоже сиротит team-данные) и матчит single-device-модель MVP.

**Явно вне scope (YAGNI):** настоящий multi-device; авто-перенос/re-wrap `team_keys` на новый ключ; v1.1 safety-handle (admin-freeze потерянного устройства). Эти — отдельные треки.

## 3. Identity-модель (почему team-доступ сиротится)

Device X25519-ключ (`IdentityService.ensureLocalIdentity`, файл `keystore/x25519.priv`) — **двойного назначения**:
1. **Auth:** регистрируется в `pubkey_registry(auth_id, pubkey)`, попадает в JWT-claim, RLS ключуется на `auth.jwt()->>'pubkey'`.
2. **E2E:** тот же priv гоняет ECDH в `InviteService`/`InviteAcceptService` — им обёрнуты `team_keys` каждого воркспейса.

Re-key перепривязывает аккаунт на ключ текущего Mac (назначение 1). Но `team_keys` воркспейсов были обёрнуты под **старый** ключ устройства — текущий Mac их не расшифрует → членство в воркспейсах требует **переинвайта** (admin заново wrap'ит team_key на новый pubkey). Это ожидаемо: в кейсе «потерял Mac» доступ к команде ушёл вместе со старым устройством.

**Важно:** для `accountBoundToDifferentDeviceKey` локальную identity **НЕ удаляем** (в отличие от `deviceKeyOwnedByAnotherAccount`). Ключ этого Mac валиден и свободен — нужно лишь чтобы сервер принял его как ключ аккаунта. Сохранение локального ключа = меньше разрушения (любые локальные данные, привязанные к этому ключу, остаются валидны).

## 4. Дизайн — клиент (Mac, мой)

### 4.1 Роутинг ошибки
`SupabaseOAuthService.setFailureState` (сейчас `accountBoundToDifferentDeviceKey` → `.error`) → новый стейт `.deviceRekey` (отдельный от `.deviceConflict`, т.к. семантика и копирайт другие, и re-key **не** удаляет identity).

### 4.2 Confirm-диалог (`LoginView`)
Заголовок: «This account is set up on another Mac». Тело: «Make **this** Mac the active device for your account? The other Mac will be signed out, and you'll need to rejoin any shared workspaces here.» Кнопки: **Make This Mac Active** (destructive) / **Cancel**.

### 4.3 Re-key action (`SupabaseOAuthService`)
Новый `func rekeyToThisDeviceAndRetry()`:
1. **НЕ** трогает локальную identity.
2. Зовёт `registerPubkey(accessToken, rekey: true)` (новый флаг → серверный re-key путь, §5).
3. `tokenRefresh()` → новый JWT, claim теперь = локальный ключ.
4. `requireClaimMatchesLocalKey(claim)` → проходит → `.authenticated`.
5. Ошибка → `setFailureState`.
Cancel: `cancelDeviceConflict`-паттерн (signOut + `.idle`), т.к. на этом пути уже установлена claimless/mismatch-сессия.

## 5. Дизайн — сервер (VPS, по этой спеке)

`register_pubkey` (edge function, прод-дашборд/VPS) получает re-key режим: для аутентифицированного `auth_id` сделать **текущий posted pubkey каноническим ключом аккаунта**, чтобы JWT-hook (`custom_access_token_hook`) вернул его в claim.

Точная SQL-форма зависит от того, как hook выбирает claim при нескольких строках `pubkey_registry` для одного `auth_id` — **это нужно проверить против живого бэкенда** (исходник миграций/функций не в Mac-клонах; источник правды — дашборд проекта `jwxnhwyqjzjmjnmwpwyq`). Два варианта реализации (выбрать после верификации hook'а):
- **(а)** re-key = `DELETE FROM pubkey_registry WHERE auth_id=$me` затем `INSERT (auth_id, posted_pubkey)` — гарантирует единственную строку → hook однозначен. (Совпадает с single-device-намерением #68.)
- **(б)** если hook детерминированно выбирает «последнюю» строку — `UPSERT` достаточно.

Гард: re-key только для **своего** `auth_id` (из JWT). Без re-key-флага поведение `register_pubkey` не меняется (обратная совместимость с обычным логином).

## 5.1. As-built (задеплоено на прод 2026-06-14, project `jwxnhwyqjzjmjnmwpwyq`, verified live)

Факты, снятые с живого прода (резолвят OQ-1/OQ-2):
- `custom_access_token_hook` читает pubkey **live**: `SELECT pubkey FROM pubkey_registry WHERE auth_id = (event->>'user_id')::uuid` → claim обновляется на следующем refresh. **Триггеров на `pubkey_registry` нет.** Схема: `auth_id` **PK** + `pubkey` **UNIQUE** (один ключ на аккаунт — `multi-device` из §4 account-login спеки аспирационен, по факту single-key).
- **Upsert НЕ годится** (первая попытка): `upsert({auth_id, pubkey}, {onConflict: auth_id})` ловит **UNIQUE(pubkey) 23505**, если posted-ключ занят ДРУГИМ аккаунтом (тот же физический Mac под другим аккаунтом) → 409 → клиентский loop. Поймано на живом смоуке.
- **As-built логика (refines variant A) — take over device key:**
  ```
  delete from pubkey_registry where pubkey = <posted>;    -- освободить ключ этого Mac от любого аккаунта (legit: приватник есть только на этом Mac)
  delete from pubkey_registry where auth_id = <caller>;   -- снять старую привязку аккаунта
  insert into pubkey_registry (auth_id, pubkey) values (<caller>, <posted>);
  ```
  Net: ровно один ряд `{auth_id, pubkey}`, конфликтов PK/UNIQUE нет. Семантика «этот Mac теперь мой». Caller обязан владеть приватником posted-ключа (он выводится из локального x25519.priv) → забрать ключ может только тот, кто физически на этом устройстве — не кража.
- **Verified:** клиент `rekey:true` → 200 `rekeyed` → refresh → claim == локальный ключ → логин довёлся; БД-состояние подтверждено (аккаунт ↔ текущий device-ключ, старые привязки сняты).

⚠️ **Source-tracking gap (Диме):** исходник edge functions **не версионируется ни в одном клоне** (deployed-only). Re-key живёт на проде + в `~/leaf-sb-rekey/` (untracked) + в этой спеке. **Занести `register_pubkey` re-key в канонический backend-source**, иначе перезатрётся при следующем его деплое. Полный as-built TS — по §5.1-логике поверх скачанного `register_pubkey/index.ts`.

## 6. Безопасность

- Re-key требует **валидной аутентифицированной сессии** (после OAuth/password) — нельзя re-key'нуть чужой аккаунт.
- Эффект «старое устройство выходит» — by-design (это и есть «я переехал на новый Mac»). Старый Mac на следующем pubkey-чеке получит свой `accountBoundToDifferentDeviceKey` (теперь claim указывает на новый Mac) → сам сможет re-key'нуться обратно. Ping-pong возможен при реальном использовании двух Mac — приемлемо для single-device MVP (явное подтверждение каждый раз, не автомат).
- Rate-limit: низкий риск (требуется аутентификация); отдельный лимит не вводим в MVP, отметить как watch-item.

## 7. Open questions (под VPS-верификацию)

1. ~~**JWT-hook claim-selection** при нескольких строках на `auth_id`~~ — **RESOLVED (§5.1):** hook читает live `WHERE auth_id=…`, `auth_id` — PK (один ряд). As-built = delete-by-pubkey + delete-by-auth_id + insert.
2. ~~Текущее поведение `register_pubkey` на новый pubkey того же `auth_id`~~ — **RESOLVED (§5.1):** `auth_id` PK + `pubkey` UNIQUE → single-key-per-account, не multi-device.
3. Нужно ли чистить осиротевшие `team_keys`/workspace-membership строки локально на текущем Mac после re-key (косметика; RLS и так отрежет по новому pubkey). По умолчанию — нет (YAGNI).

## 8. Тестирование

- **Клиент (TDD, LeafCore/app):** `setFailureState` роутит `accountBoundToDifferentDeviceKey` → `.deviceRekey` (не `.error`, не `.deviceConflict`); `rekeyToThisDeviceAndRetry` НЕ зовёт `deleteLocalIdentity`, зовёт `registerPubkey(rekey:true)` → refresh → claim-match → `.authenticated`; mismatch после re-key → `setFailureState`. Не ломать существующие `deviceKeyOwnedByAnotherAccount`/`deviceConflict` тесты.
- **Сервер (VPS):** re-key заменяет binding для `auth_id`; после re-key refreshed JWT claim == posted pubkey; re-key чужого `auth_id` отклоняется; обычный `register_pubkey` (без флага) не регрессит.

## 9. §14 Local vs VPS responsibilities

- **Local (Mac, эта сессия):** клиентский код (`.deviceRekey` стейт + роутинг + диалог + `rekeyToThisDeviceAndRetry`), клиентский флаг `registerPubkey(rekey:)` в `SupabaseClient`, TDD клиента, эта спека + план. Клиентский контракт серверного re-key-флага фиксируется здесь.
- **VPS (серверная сессия):** верификация JWT-hook claim-selection (OQ-1), реализация re-key пути в `register_pubkey` edge function (вариант а/б), деплой на прод-проект `jwxnhwyqjzjmjnmwpwyq`, серверный smoke (re-key заменяет binding; claim матчит). Клиент готов слать `rekey:true` до серверного деплоя — до него путь = honest transient-fail (как AI-UI-4 до relay).

## 10. Не входит (YAGNI)
Multi-device (несколько активных устройств на аккаунт); авто re-wrap `team_keys` на новый ключ при re-key; admin-freeze потерянного устройства (v1.1 safety-handle, whitepaper `revocation.md`); rate-limit на re-key.
