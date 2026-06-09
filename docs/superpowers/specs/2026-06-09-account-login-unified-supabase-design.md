# Дизайн: аккаунт-логин (рега на сайте → нативный логин в приле) на едином Supabase

- **Дата:** 2026-06-09
- **Автор:** Антон (+ Claude Code)
- **Статус:** design / на ревью
- **Триггер:** «хочу добавить логин при входе приложения, связать с сайтом где рега». При расследовании выяснилось, что **логин на сайте сломан** — Supabase-проект сайта удалён. Фикс бага и фича оказались одним решением.

---

## 1. Контекст и цель

Сейчас identity сайта и приложения живут на **двух разных Supabase-проектах**:

| | Проект | Модель |
|---|---|---|
| Сайт (`leaf-web`) | `jpzqmtmmypnzqhdltcvr` — **УДАЛЁН** (NXDOMAIN с чистой сети) | email/пароль + OTP + Google/GitHub |
| Приложение (`leaf`) | `jwxnhwyqjzjmjnmwpwyq` — **живой** (Track 5 backend) | анонимный вход + X25519 device-pubkey |

**Цель:** свести обе системы на **один общий Supabase-проект** (`jwxnhwyqjzjmjnmwpwyq`), где:
1. **Регистрация** — только на сайте (email/пароль + Google + GitHub).
2. **Логин** — нативно в Mac-приложении (те же 3 способа).
3. **Жёсткий gate** — без валидной сессии не работает ни UI, ни фоновый агент (даже локальный захват).

Побочно это чинит сломанный логин сайта (репойнт на живой проект).

---

## 2. Зафиксированные решения

1. **Один общий Supabase** — `jwxnhwyqjzjmjnmwpwyq`. Мёртвый `jpzqmtmmypnzqhdltcvr` сводится в утиль.
2. **Рега — только на сайте.** В приложении реги нет, только логин + ссылка «нет аккаунта? зарегайся на сайте →» (открывает браузер).
3. **Логин в приле — нативный:** email/пароль + Google + GitHub.
4. **Жёсткий gate.** Нет сессии → пустой gate-экран в UI, агент в простое. Соло-юзер обязан зарегаться.
5. **Анонимный bootstrap (`signInAnonymously`) удаляется** — его место занимает реальный логин.

> ⚠️ **Стратегический трейд-офф (зафиксирован осознанно):** жёсткий gate расходится с позиционированием whitepaper («free solo use requires no login», local-first, «ничего не уходит с устройства по умолчанию»). Приложение начинает «звонить домой» (auth) до любого действия. Принято в пользу аккаунт-центричной монетизации.

---

## 3. Проверенные факты текущего состояния (из разведки)

Подтверждено read-only аудитом кода и живыми DNS/HTTP-пробами:

- **Отказ от анонимки безопасен.** Ни один путь не гейтит на `is_anonymous`/`auth.role()`. JWT-hook (`custom_access_token_hook`, `migrations/20260513120900_rls_policies.sql:5-23`) читает `auth.users.id`, не тип юзера. RLS-политики ключуются на `auth.jwt() ->> 'pubkey'`. `register_pubkey` (edge function) принимает любой валидный JWT. **→ бэкенд-схема меняется на 0.**
- **Ломается только атомарность бутстрапа.** `performBootstrap()` (`SupabaseClient.swift:229-265`) безусловно зовёт `performSignInAnonymously()` (стр. 244); шаги registerPubkey (стр. 259) + tokenRefresh (стр. 260) generic и работают с любым access_token.
- **~15 файлов зовут `ensureAuthenticated()`** (`SupabaseClient+*.swift`, `InviteAcceptService.swift:91`) — изменений не требуют, принимают любой метод аутентификации.
- **`config.toml` в `leaf-relay/supabase` разошёлся с живым проектом.** В файле: `enable_anonymous_sign_ins=false` (стр. 173), `[auth.hook.custom_access_token]` закомментирован (стр. 279-281), `site_url=http://127.0.0.1:3000` (стр. 154). Но прод реально использует анонимку и pubkey-claim работает → **живой проект сконфигурён через дашборд и дрифтанул от файла.** Источник правды для прода = дашборд, не `config.toml`.
- **`signOut()` неполный** (`SupabaseClient.swift:78-80`): чистит только in-memory `state`, не трогает персист.
- **Offline-grace уже есть**: `SupabaseClient+Retry.swift:70-79` — на 401 форсит `ensureFreshSession(force:true)` и ретраит; транзиентные сетевые ошибки гасит retry-policy.
- **Сессия персистится** в `~/Library/Application Support/Leaf/supabase-session.json` (mode 0600), структура `PersistedSession { refreshToken, userID, savedAtMs }` (`SupabaseSessionStore.swift:24`). Один и тот же файл читают и UI-процесс, и агент.
- **`leaf://` уже зарегистрирован** (`Info.plist:21-32`), диспатч через `.onOpenURL` → `InviteURLHandler` (`LeafApp.swift:698-700`).
- **OAuth-инфра уже есть**: `PKCE.swift`, `LoopbackCallbackListener.swift` (Linear/GitHub/Slack). Существующие интеграции используют **loopback + системный браузер**, не ASWebAuthenticationSession.
- **Сайт указывает на мёртвый проект**: `leaf-web/src/scripts/supabase-client.ts:5-6`. Воркер `leaf-contact` (`/api/account/delete`) берёт `SUPABASE_URL`/`SUPABASE_SECRET_KEY` из секретов CF — тоже сломан, если они на мёртвом проекте.
- **Turnstile на формах логина мёртвый**: `signup.astro:8` объявляет `TURNSTILE_SITE_KEY`, но виджета нет и `captchaToken` нигде не шлётся.

---

## 4. Целевая модель identity

- `auth.users` (Supabase) — **единственный источник правды о юзере**, создаётся регой на сайте.
- У каждого устройства остаётся свой X25519-ключ (нужен для E2E-крипты команды). При логине приложение регистрирует pubkey устройства под аккаунтом в `pubkey_registry(auth_id, pubkey)` → **один аккаунт ↔ много устройств**.
- Последовательность на первом логине (механически идентична сегодняшнему бутстрапу, только без анонимки):
  1. Логин (email/пароль или OAuth) → `access_token` (ещё без `pubkey`-claim).
  2. `registerPubkey(accessToken)` → строка в `pubkey_registry`.
  3. `tokenRefresh()` → новый JWT с `pubkey`-claim (инжектит JWT-hook).
- **Gate должен пускать дальше только когда сессия валидна И pubkey зарегистрирован** (сегодня это неявно гарантировано атомарностью; теперь — явная проверка).

---

## 5. Компонентный дизайн

### 5.A. Общий Supabase-проект (`jwxnhwyqjzjmjnmwpwyq`)

Источник правды для прода — **дашборд** (config.toml дрифтанул, его синхронизируем отдельно/опционально). Изменения:

- **Включить провайдеры:** email (уже), Google, GitHub.
- **OAuth-секреты** (вне git, через дашборд): Google client_id/secret (Google Cloud OAuth client), GitHub client_id/secret (GitHub OAuth App). В vault (AWS SSM) положить копии под `/leaf/prod/*`.
- **Site URL:** `https://leaf.gundem.tech`.
- **Redirect allow-list:** вебовые коллбэки (`https://leaf.gundem.tech/**`) **+** `leaf://auth/callback` (для приложения).
- **JWT-hook** `custom_access_token_hook` — убедиться, что привязан в дашборде (Authentication → Hooks). На проде он работает (анонимный pubkey-claim есть), но проверить явно.
- **Anonymous sign-ins** — выключить в дашборде (гигиена; приложение всё равно перестаёт звать). Не блокер.
- **Email confirmations** — **`on`** (решено §9.1) → нужен кастомный SMTP-провайдер (Resend/Postmark/SES), настроенный в Supabase Auth (дефолтный SMTP лимитирован и не годится для прода).
- **CAPTCHA protection (Turnstile)** — **включить** (решено §9.2): в Supabase Auth → CAPTCHA, provider=turnstile, secret-ключ (из Cloudflare). ⚠️ Защита **глобальная на проект** → `captchaToken` обязателен на всех auth-эндпоинтах (signup/password-signin/OTP/recover), включая нативный логин приложения (см. §5.C).
- **`config.toml`** (опционально, чтобы файл перестал врать): `site_url`, `additional_redirect_urls` (+`leaf://auth/callback`), раскомментировать `[auth.hook.custom_access_token]` → `pg-functions://postgres/public/custom_access_token_hook`, добавить `[auth.external.google]`/`[auth.external.github]` с `env(...)`-подстановкой секретов, `enable_anonymous_sign_ins=false`.

**Бэкенд-схема (миграции/RLS/edge functions) — без изменений.**

### 5.B. Сайт (`leaf-web`) + воркер (`leaf-contact`) + доки

- `leaf-web/src/scripts/supabase-client.ts:5` — URL → `https://jwxnhwyqjzjmjnmwpwyq.supabase.co`.
- `leaf-web/src/scripts/supabase-client.ts:6` — ключ → anon/publishable общего проекта (из дашборда; supabase-js принимает и `sb_publishable_*`, и JWT-формат `eyJ...`; для единообразия с приложением — JWT anon-ключ).
- `leaf-contact` воркер — обновить секреты CF `SUPABASE_URL` + `SUPABASE_SECRET_KEY` (service_role общего проекта) через `wrangler secret put`, передеплоить. Это чинит `/api/account/delete`. Кода менять не надо.
- **Turnstile (полная обвязка, Вариант B — решено §9.2):** добавить виджет `<div class="cf-turnstile" data-sitekey={TURNSTILE_SITE_KEY}>` на формы signin+create в `signup.astro`, подключить `challenges.cloudflare.com/turnstile/v0/api.js`, в `signup-flow.ts` собирать `window.turnstile.getResponse()` и слать `options.captchaToken` в `signUp` **и** `signInWithPassword` (+ reset виджета после попытки). Site-ключ Turnstile должен соответствовать тому, чей secret введён в Supabase Auth.
- **Доки:** `leaf-docs/infra/README.md` (§19 про signup-проект) и `CHANGELOG.md` — заменить ссылки на мёртвый проект, отметить консолидацию (один free-tier слот вместо двух).
- UI реги/логина на сайте остаётся как есть — он уже полный.

### 5.C. Mac-приложение (`leaf`) — gate + нативный логин

- **Gate-слой** в `RootView.swift:55-66`, перед ветками `removedFromActiveWorkspace`/`shell`:
  ```
  if !hasValidSession { LoginGateView() }
  else if case .removedFromActiveWorkspace(let n) = state { RemovedFromTeamBanner(n) }
  else { shell }
  ```
  «Валидная сессия» = `SupabaseClient.currentSession() != nil && expiresAt > now()`.
- **`LoginView`/`LoginGateView`** (SwiftUI, новый, `Leaf/Auth/`): поля email+пароль; кнопки Google/GitHub; «Забыл пароль» и «Нет аккаунта? Зарегайся →» открывают сайт в браузере.
- **Новый `SupabaseOAuthService`** (`Leaf/Auth/SupabaseOAuthService.swift`, по образцу `LinearOAuthService`): email-path (без redirect) + OAuth-path.
  - **Redirect-механизм OAuth: ASWebAuthenticationSession + `leaf://auth/callback`** (а не loopback). Причина: Supabase allow-list требует точные redirect-URL; ephemeral-порты loopback с этим не дружат, а ASWebAuthenticationSession ловит фиксированный custom-scheme без локального веб-сервера. `PKCE.swift` переиспользуем (verifier/challenge). При этом `InviteURLHandler` для auth НЕ трогаем — ASWebAuthenticationSession отдаёт redirect в свой completion-handler.
- **Новые методы в `SupabaseClient`** (`SupabaseClient.swift`, рядом с `ensureAuthenticated`): `signInWithPassword(email:password:captchaToken:)` (POST `/auth/v1/token?grant_type=password`, тело включает `gotrue_meta_security.captcha_token`), `exchangeOAuthCode(code:codeVerifier:redirectURI:)` (POST `/auth/v1/token?grant_type=pkce`). Эндпоинты — в `SupabaseEndpoint.swift`. Переиспользуют существующий `decodeAuthResponse` + header-паттерн.
- **CAPTCHA в нативе** (следствие глобальной защиты, §5.A): email/пароль-путь рендерит Turnstile в маленьком `WKWebView` (загрузить страницу с виджетом site-ключа, забрать token через JS-bridge), полученный `captchaToken` передать в `signInWithPassword`. **OAuth-путь (Google/GitHub) капчу не требует** — ASWebAuthSession/authorize-редирект ею не гейтится. Если позже глобальную капчу выключим — `WKWebView` убирается без других изменений.
- **Замена бутстрапа:** убрать безусловный `performSignInAnonymously()`. `ensureAuthenticated()`:
  1. валидная in-memory сессия → вернуть;
  2. иначе persisted refresh-token → `tokenRefresh` → вернуть;
  3. иначе **throw `unauthorized`** (без анонимного fallback). Caller (gate) показывает `LoginView`.
- После любого логина — `registerPubkey` → refresh; пускать в UI только при наличии `pubkey`-claim.
- **`signOut()`** доработать: `state=.notAuthenticated` **+** `sessionStore.clear()` (+ опц. `launchAgent.unregister()`). Кнопка — Settings → Account.
- **Offline-grace** — уже есть, ничего не добавляем; форс-логин только при реальном отказе refresh-token, не при транзиентной сети.

### 5.D. Фоновый агент (`LeafAgent`) — gate

- Агент — **отдельный launchd-процесс** (`Resources/LaunchAgents/tech.gundem.leaf.agent.plist`), читает тот же `supabase-session.json`.
- После открытия БД (`Agent.swift:54`): сконструировать `SupabaseClient` и вызвать `ensureAuthenticated()`.
  - Успех → запускать коллекторы как сейчас.
  - Ошибка (нет сессии / refresh отвергнут) → `exit(0)`. `KeepAlive{SuccessfulExit:false}` не рестартит.
- После логина в UI приложение поднимает агент через `LaunchAgentService.register()`. После sign-out — `unregister()`; уже запущенный агент при следующем тике/старте не найдёт сессию.

---

## 6. Вне scope (v1)

- Биллинг / гейт платного Team (paid-tier enforcement) — отдельно, позже. Логин лишь устанавливает identity.
- Управление аккаунтом в приле (профиль, удаление) — это на сайте (dashboard).
- Миграция существующих анонимных юзеров — некого (охват ~0).
- Полная синхронизация `config.toml` ↔ прод как IaC — опционально.
- Magic-link логин в приле (есть OTP на сайте; в приле — 3 заявленных способа).

---

## 7. Риски и митигации

| Риск | Митигация |
|---|---|
| Бутстрап частично падает (есть JWT, нет pubkey-claim) | Явный gate `ensureAuthenticatedAndPubkeyRegistered()` перед командами в команду; «Регистрирую устройство…» + retry в gate |
| `config.toml` дрифт → правка файла не меняет прод | Источник правды = дашборд; менять там, файл синхронизировать отдельно |
| Общий проект — рабочий бэкенд Track-5 (client-код в `LeafCore` шарится с треками Димы) | Согласовать с Димой окно изменений auth-конфига/клиента, чтобы не сломать его in-flight |
| Email-deliverability (дефолтный SMTP Supabase лимитирован) — а confirmations теперь on | Кастомный SMTP (Resend/Postmark/SES) настроить в Phase 0, до первой реги |
| Глобальная капча ломает нативный логин, если забыть про captchaToken | WKWebView-Turnstile в email-пути приложения (§5.C); OAuth-путь освобождён; покрыть тестом |
| Удаление анонимки ломает скрытую зависимость | Аудит показал 0 зависимостей; прогнать swift-test suite по `SupabaseClient*`/invite/join после правки |
| OAuth client-секреты утекут в git | Только дашборд + vault (`/leaf/prod/*`), `env(...)` в config.toml |
| Service_role ключ воркера на мёртвом проекте | Ротация секрета на общий проект при репойнте |

---

## 8. Acceptance / верификация

- Сайт: `/signup` создаёт аккаунт на `jwxnhwyqjzjmjnmwpwyq` (DevTools → запросы идут на новый хост); signin/reset работают; `/api/account/delete` отвечает.
- Приложение: чистый запуск без сессии → `LoginView`; email-логин и Google, и GitHub → попадание в основной UI; `pubkey` зарегистрирован; перезапуск → сессия восстановлена (оффлайн тоже).
- Агент: без сессии — `exit(0)`, локального захвата нет; после логина — поднимается и пишет.
- Sign-out → возврат на gate, `supabase-session.json` удалён, агент в простое.
- Swift-test: suite по `SupabaseClient*`, invite/join — зелёный после удаления анонимки.

---

## 9. Решения по открытым вопросам (приняты 2026-06-09)

1. **Email confirmations — `on` сразу.** → нужен кастомный SMTP с самого начала (§5.A, §14).
2. **Turnstile — обвязать сразу (Вариант B).** Глобальная CAPTCHA-защита Supabase on → captchaToken на всех auth-вызовах, включая натив (§5.A, §5.B, §5.C).
3. **OAuth redirect в приле — ASWebAuthenticationSession + `leaf://auth/callback`.**

---

## 10. Фазировка

Реализуется двумя независимыми фазами — Phase 0 чинит сайт сразу, не дожидаясь работы по приложению.

- **Phase 0 — разблокировать сайт (срочно):** репойнт `leaf-web` на живой проект (§5.B), дашборд-конфиг общего проекта (§5.A: Site URL, redirect, email-провайдер, email-confirmations on, кастомный SMTP, CAPTCHA-защита), полная обвязка Turnstile на сайте (§5.B), ротация секретов воркера `leaf-contact`. Результат: рега/логин на сайте снова работают. От приложения не зависит.
- **Phase 1 — нативный логин в приле:** gate (UI + агент), `LoginView`, `SupabaseOAuthService`, методы `SupabaseClient`/`SupabaseEndpoint`, замена анонимного бутстрапа, `signOut`, Google/GitHub провайдеры в дашборде + OAuth-клиенты. Зависит от Phase 0 (общий проект уже настроен).

---

## 14. Local vs VPS / dashboard responsibilities

(по конвенции — кто что выполняет; Mac-сессия пишет код, инфра-операции отдельно)

- **Mac-сессия (Claude Code пишет код):**
  - `leaf` — gate, `LoginView`, `SupabaseOAuthService`, методы `SupabaseClient`/`SupabaseEndpoint`, замена бутстрапа, `signOut`, gate агента.
  - `leaf-web` — правка `supabase-client.ts`, удаление мёртвого Turnstile-ключа.
  - `leaf-contact` — код не меняется.
  - `leaf-relay/supabase/config.toml` — опц. синхронизация.
  - `leaf-docs/infra` — обновление ссылок.
- **Supabase Dashboard (Антон, руками через `!` / браузер):**
  - Включить Google/GitHub провайдеры + ввести OAuth client_id/secret.
  - Site URL + redirect allow-list (+`leaf://auth/callback`).
  - Проверить привязку JWT-hook; выключить anonymous sign-ins; **email-confirmations = on**.
  - **Настроить кастомный SMTP** (Resend/Postmark/SES) для писем подтверждения/сброса.
  - **Включить CAPTCHA protection** (provider=turnstile) + ввести Turnstile secret.
  - Достать anon-ключ общего проекта для сайта.
- **Cloudflare / wrangler (Mac, но секрет-операции — Антон):**
  - `wrangler secret put SUPABASE_URL` + `SUPABASE_SECRET_KEY` на общий проект для `leaf-contact`, передеплой.
- **External:** Google Cloud OAuth client, GitHub OAuth App (создать, redirect = Supabase callback); SMTP-провайдер (Resend/Postmark/SES) — аккаунт+API-ключ; Cloudflare Turnstile — site+secret ключи для auth (можно отдельный виджет от waitlist). Все секреты → vault `/leaf/prod/*`.
- **Координация:** предупредить Диму перед изменением auth-конфига общего (Track-5) проекта.
