# Архитектура Leaf

## Что это
Leaf — ambient memory layer для macOS (далее iOS) + Native UI + MCP-сервер + team presence-relay.
Фоновый агент собирает metadata о работе пользователя, отдаёт её через две поверхности и делится presence с командой end-to-end encrypted.
Репо: `git@github.com:gundemtech/leaf.git`

## Платформы
- **macOS** — приоритет 1, активная разработка
- **iOS** — после MVP на Mac

## Две поверхности (ADR-012, уточнено ADR-019)
- **Native UI** (primary) — полноценная витрина данных через Derived Insights Engine. Работает standalone, без внешних зависимостей. Home / Team / Connections / Organization / Settings.
- **MCP-сервер** (bonus channel) — тот же Derived Insights Engine, экспортированный через MCP tools для юзерских AI-клиентов (Claude Code / Cursor / Claude Desktop). Для natural-language вопросов.
- **Без AI-клиента — полный value.** Не требуем установки никакого AI-клиента. MCP — опция для тех, у кого уже есть AI-ассистент.
- UI ≠ workspace. Критерий: каждый экран понятен за 10 секунд.
- MVP экраны: Home, Team, Connections, Organization, Settings (+ Share Controls sub-screen, + Privacy dashboard reverse view).

## Модель приватности (ADR-013, ADR-014, ADR-020)
- **Opt-in transparency**: по умолчанию с командой не шарится ничего. Юзер явно whitelist-ит приложения и типы событий через Share Controls (ADR-020).
- **Private self**: raw metadata не покидает устройства (SQLCipher, ключ в Keychain) — остаётся в ADR-013.
- **Symmetric**: каждый конфигурирует свой share list; то, что пошарено, видно всем членам команды одинаково, без admin-override (ADR-014). Admin = обычный team-member + org/billing permissions, без privileged read access.
- **Non-shared app behavior** (default): команда видит "Active (generic)" без app/folder details. Юзер может переключить в "Fully invisible" или "Away" в Settings.
- **Invisible mode**: мгновенный override всего share list; non-retroactive (прошлое в team history не переписывается — audit > соблазн).
- **Right to deletion** (ADR-013): best-effort для online-устройств; локальная forever-history у ex-teammates — OT-1.
- **Safety handle**: admin может freeze/wipe устройство коллеги по запросу самого юзера (украденный MacBook).
- **Роли** (Dev/PM/Designer) — только для AI-рекомендаций, не для видимости.

## Granularity levels и маппинг на источники (ADR-013)
- **L1 App** — NSWorkspace.frontmostApplication
- **L2 App + intensity** — + CGEventSource idle (low idle + стабильный app = heavily focused)
- **L3 App + activity verb** — + Accessibility window title parsing
- **L4 App + folder/module** *(default ceiling)* — FSEvents (watched folder) или AX-path
- **L5 App + file name** *(opt-in per folder)* — FSEvents file-level
- **L6 content** — запрещено всегда

## Типы сигналов (раздел 6 whitepaper)
Ортогональная ось к layers и granularity. Каждое событие — один из пяти типов.

| Тип | Отвечает на | Масштаб | Хранимое |
|---|---|---|---|
| **Attention** | что делал | L1-L2 | app + duration + intensity |
| **Content** | с чем работал | L3-L5 | file / URL / window identifier; L6 content — нет |
| **Action** | что произошло | atomic + self-authored labels | commit message, issue title, branch name; bodies (comment text, message / email body) — нет |
| **Context** | почему | atomic | meeting state + Focus mode + sleep/wake; attendee PII — нет |
| **AI collaboration** | сколько/как работал с AI | per-event metadata | tool called + file attribution + session timing + derived activity pattern; prompt/response content — запрещено (см. AI collaboration в Layer A и ADR-010) |

**Presence** — производный view, композит `derive(Attention + Context + Content@L≤team_ceiling)`. Не 6-й тип — derived snapshot для team relay (ADR-016).

## Layer A — сбор данных на устройстве (ADR-011, ADR-015)
- `NSWorkspace.frontmostApplication` + `DidActivateApplicationNotification` — active app, free
- `CGEventSourceSecondsSinceLastEventType` (combinedSessionState) — idle, free
- `DistributedNotificationCenter` (`screenIsLocked/Unlocked`) + NSWorkspace sleep/wake — status, free
- `EventKit` (`EKEventStore.requestFullAccessToEvents`) — календарь + in_meeting, 1 prompt (~80% grant)
- `INFocusStatusCenter` — Focus mode, 1 prompt
- `Accessibility API` (`AXIsProcessTrustedWithOptions`) — window title + browser URL via `AXWebArea→AXURL`, 1 prompt (drop-off risk)
- `FSEvents` в watched folders через `NSOpenPanel` + security-scoped bookmarks — обходим TCC даже в `~/Documents`
- git log polling (`git -C <path> log --since`) в watched folders — не hooks (ADR-015)
- AI collaboration hooks — metadata only, prompt/response content отбрасываем на уровне хука (ADR-010 Won't-list):
  - **MVP:** Claude Code hooks (PostToolUse, SessionStart, SessionEnd, UserPromptSubmit) + fallback jsonl-парсинг `~/.claude/projects/*.jsonl`
  - **v1.1:** Cursor Hooks v1.7+ (beforeSubmitPrompt / afterFileEdit / postToolUse / stop), Windsurf Cascade Hooks (`.windsurf/hooks.json`), Continue.dev (`.continue/dev_data/*.jsonl` через FSEvents)
  - **Surface навсегда (нет per-event API):** GitHub Copilot (org-aggregate через REST `/copilot/usage`, не per-event), ChatGPT Desktop ("Work with Apps" односторонний). Degrade: AX window title + file inference.
- Spotlight `NSMetadataQuery` (`kMDItemFSName == ".git"`) — только onboarding wow-момент

**Отложено в v1.1:** AppleScript / Automation (Slack huddle, Xcode active doc) — отдельный TCC-промпт per target app.

**Запрещено (ADR-010):** Screen Recording, keylogging, OCR canvas, захват UI-events целевых приложений, post-commit hooks в юзерском репо.

## Layer B — MVP (ADR-009, ADR-011)
- **Только Linear.** OAuth 2.0 PKCE (localhost redirect на эфемерный порт), scope=`read`, actor=user.
- Polling раз в 5 мин: `issues(first:50, filter:{updatedAt:{gt:$since}})` ≈ 75 complexity pts/call, 900/hr при лимите 2M pts/hr.
- Safety margin `now - 30s` на каждый poll от clock skew.
- Slack / GitHub — v1.1+.

## Layer C (V1.5+) и Layer D (V2)
- Layer C: MCP-aggregator (Figma / Notion / Jira / Gmail / Calendar).
- Layer D: собственные плагины (Figma plugin, VS Code extension, Chrome extension).

## Хранение (ADR-017)
- **GRDB 7.10+ fork** + SQLCipher через SwiftPM (официальной интеграции нет — community fork).
- SQLite в WAL mode, три процесса (Agent writer + MCPServer reader + MenuBarApp reader) → один файл, cross-process POSIX locks, `DatabasePool` в каждом процессе.
- Обязательные pragma: `cipher_plaintext_header_size=32` + external salt (iOS-ready), `busy_timeout=5000`, `PRAGMA key = x'HEX'` с raw keyspec (без PBKDF2 на каждом open).
- Ключ в Keychain: `kSecClassGenericPassword`, `kSecAttrAccessGroup=$(TeamID).tech.gundem.leaf`, `AccessibleAfterFirstUnlockThisDeviceOnly`, `Synchronizable=false`.
- Writer запускает `PRAGMA wal_checkpoint(TRUNCATE)` раз в 15 мин / 4MB — без этого WAL распухает без границ.
- Путь: `~/Library/Application Support/Leaf/events.sqlite` (0600).

## Derived Insights Engine (ADR-019)
Чистый Swift-модуль в shared package (`LeafCore`), считает метрики из SQLCipher on-demand. Zero LLM dependency. Используется MenuBarApp (для Native UI) и MCPServer (для tool responses).

- **API (высокоуровнево):** `timeInApp(period:)`, `focusSessions(period:)`, `contextSwitchRate(period:)`, `filesTouched(period:)`, `aiRatio(period:)`, `teamPresenceOverlap(team:, period:)`, `deepWorkStreak()`, `peakProductivityHour()`, `weekOverWeekDelta()`.
- **Реализация:** SQL запросы через GRDB + Swift арифметика + SwiftUI Charts. Никаких LLM-вызовов.
- **Работает на любом Mac** (macOS 14+), без подписок, без интернета (кроме team presence sync).
- **In-app AI narrative** ("расскажи словами про мою неделю") — НЕ в MVP. Трек v1.1+ как optional "AI Coach" с BYO API key, явный opt-in, additive feature.

## Schema (ADR-019)
SQLCipher таблицы:
- `events` — raw event stream (5 signal types).
- `sessions` — aggregated work sessions (boundary = idle или app switch).
- `ai_events` — отдельно: tool/file attribution из Claude Code / Cursor / Windsurf / Continue hooks. Prompt/response content — нет (ADR-010).
- `correlations` — связи между events (populated post-MVP, схема готова).
- `integrations` — OAuth state (Linear MVP).
- `blocklist` — user exclusions (apps / URLs / folders).
- `watched_folders` — security-scoped bookmarks + L5 opt-in flag.
- `share_apps` — per-app whitelist: bundle_id, enabled, max_granularity, mode (shared / silent / invisible), added_ts.
- `share_event_types` — per-event-type whitelist: event_type (git_commit / linear_update / meeting_status / focus_mode / etc), enabled, redact_level, added_ts.
- `presence_outgoing` — audit log "что я шлю коллегам" (после Share Controls filter).
- `presence_history` — incoming presence от коллег (forever retention — fabric команды).
- `team_members` — long-term X25519 pubkeys.
- `team_keys` — history team key rotations.
- `org` — organization metadata (1 row).

Миграции — через GRDB migrations framework.

## Share Controls (ADR-020)
Юзер контролирует что именно видно команде. Default — пустой whitelist, ничего не шарится.

- **Per-app whitelist**: для каждого bundle ID юзер решает enabled + max_granularity (L1-L5) + mode (`shared`/`silent`/`invisible`).
- **Per-event-type whitelist**: git_commit / linear_update / meeting_status (только boolean "in_meeting", без title/attendees) / focus_mode / и т.д.
- **Onboarding template** — "common dev team defaults": предлагает типовой набор (Xcode, Cursor, Claude Code, Terminal, Slack, Linear, Chrome L3) с preset granularity. Юзер соглашается one-click или customize перед подтверждением. Personal apps (Signal, Discord, Spotify, Messages, Telegram и т.д.) — OFF.
- **Filter применяется до encryption** в Agent: если current app не в whitelist → `presence_snapshot = {status: "active_generic"}` без app/folder; если event_type не в whitelist → не включается в snapshot. Relay никогда не видит разницу "отфильтровано vs не было события".
- **Non-shared app default mode** = `active_generic` (команда видит что юзер работает, но не в чём). Юзер в Settings может переключить в `fully_invisible` (последний shared snapshot + "last seen N min ago") или `away_ambiguous`.
- **Individual control > team convention**: admin не может forced-add app в share list или установить team-wide minimum visibility. Этот запрет в ADR-010 Won't-list.
- **Privacy dashboard reverse view**: Native UI показывает юзеру "Team sees of me right now: Xcode (Leaf/Agent), 5 min ago" + quick-toggle "Stop sharing this app now".
- **Non-retroactive**: выключение sharing для app после-факта не удаляет что уже пошарено. Для полного удаления — right-to-deletion flow (ADR-013).

## Presence distribution (ADR-016)
- **Envelope:** `[version:1B | keyID:16B | nonce:12B | AES-GCM-256 ciphertext | tag:16B]`. `version=1` сейчас, резерв под MLS в v2.
- **Team key:** shared AES-256 в Keychain, `Synchronizable=false`.
- **Relay:** Cloudflare Durable Objects + WebSocket Hibernation. Один DO на команду. Хранит только последний snapshot per user (не история).
- **Client loop (Agent):** считает presence snapshot → **применяет Share Controls filter** (ADR-020) → encrypt → WebSocket send при материальном изменении + heartbeat 60с. Relay никогда не видит plaintext.
- **Invite:** 24h token + 6-значный OTP через Slack/Telegram (out-of-band) → X25519 ECDH(admin, invitee) + HKDF(OTP salt) → admin wrap'ит teamKey под shared secret → POST в relay → invitee fetches и расшифровывает.
- **Rotation при removal:** admin генерирует `teamKey[n+1]`, делает N−1 pairwise ECDH wraps для оставшихся. Для N≤50 тривиально без MLS TreeKEM.
- **Safety handle:** "Remove member" кнопка = "I lost my laptop" с первого дня (нет post-compromise security в MVP).
- **Миграция на MLS** (через wireapp/core-crypto + UniFFI Swift bindings) — V1.5+, если команды >50 чел или появится удержание истории на relay.

## Distribution (ADR-018)
- **Sparkle 2.6+**, EdDSA (ed25519) signing, `SURequireSignedFeed=YES`.
- Feed на **Cloudflare R2 + Workers** (egress free, ~10× дешевле S3+CloudFront).
- Delta updates автоматически через `generate_appcast`.
- Notarize отдельным CI-шагом: `xcrun notarytool submit --wait` → `xcrun stapler staple` → `generate_appcast`. Delta patches НЕ нотарайзим.
- Hardened Runtime ON, Sandbox OFF.
- MenuBarApp owns Sparkle; после install update → `launchctl kickstart -k` Agent (Sparkle не поддерживает self-update LaunchAgent нативно).
- Channels: `.dmg` + Homebrew cask с первого релиза.

## Стек
- Swift 6+, SwiftUI, Swift Charts (visualизации в Native UI)
- GRDB 7 (community fork) + SQLCipher
- CryptoKit (AES-GCM, X25519 ECDH, HKDF)
- Cloudflare Workers + Durable Objects (TypeScript relay, ~200 LOC) — **живёт в отдельном приватном репо `gundemtech/leaf-relay`**, не в публичном `leaf`
- Sparkle 2 + Developer ID + notarytool
- **Никаких LLM dependencies в MVP.** Ни Foundation Models, ни Claude/OpenAI API. In-app AI — optional v1.1 трек (BYO API key).
- Sync Mac↔iOS: TBD (CloudKit vs своё API — ADR после MVP)

## Ключевые подсистемы
- **Agent** — LaunchAgent, фоновый writer SQLCipher + derive presence snapshot + **apply Share Controls filter** + encrypt + WS send
- **LeafCore** (Swift module) — shared library, содержит **Derived Insights Engine** (метрики on-demand) + DB access layer (GRDB models) + CryptoKit wrappers. Линкуется в MenuBarApp и MCPServer.
- **MenuBarApp** — Native UI (Home / Team / Connections / Organization / Settings + Share Controls sub-screen + Privacy dashboard reverse view) + Invisible control + Sparkle update owner. Потребляет Derived Insights Engine для всех visualizations.
- **MCPServer** — on-demand bonus channel для AI-клиентов. MVP tools: `get_timeline`, `find_last_activity`, `get_current_session`, `get_presence`, `get_team_timeline`, `get_team_focus`, `get_team_overlap`, `get_ai_activity`. Отдаёт structured JSON через Derived Insights Engine.
- **PresenceRelay** — Cloudflare DO: broadcast encrypted blobs connected peers
- **Safety handle** — freeze/wipe устройство коллеги по запросу юзера. **Отложено в v1.1** (в MVP достаточно "Remove member" + self-wipe).

---

> Текущий срез "как оно сейчас устроено". Подробности и обоснования (в public-safe формулировке) — в whitepaper `~/Desktop/leaf-docs/docs/03-architecture/`. Ярлыки ADR-XXX в тексте — исторические, живой источник правды = whitepaper. Implementation moat (SQL, точные пороги, crypto layouts) — в приватных модулях кода, не здесь.
