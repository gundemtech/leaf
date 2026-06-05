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
  - **Vendor-blocked surfaces (нет per-event API наружу — won't-list, Track-6 P7):**
    - **ChatGPT Desktop** (`com.openai.chat`) — capture сегодня только L1 attention (NSWorkspace foreground) + L2 intensity. Outbound surface отсутствует: no REST API на собственные sessions, no AppleScript dictionary, no App Intents introspection, no MCP server served by ChatGPT, no hook SDK. "Work with Apps" — inbound (ChatGPT читает другие apps через AX). Account-level export — email ZIP, не local stream. Re-evaluation trigger list — whitepaper `privacy-security/what-we-dont-capture.md`.
    - **GitHub Copilot** — org-aggregate через REST `/copilot/usage`, не per-event. Indistinguishable from L1 attention при работе в IDE.
    - **Apple Intelligence routing** — inbound в ChatGPT через Apple privacy framework; third-party readback Apple не exposes.
    - Generic AX window-title collector (line 56 выше) — currently planned, не shipped. Когда ship'нется — `com.openai.chat` default-OFF в per-app redaction list (chat title leak'ит intent).
- Spotlight `NSMetadataQuery` (`kMDItemFSName == ".git"`) — только onboarding wow-момент
- **Track-6 P6** — `AttentionEmissionPlanner` extension: for vscode-family
  bundles (`com.microsoft.VSCode`, Cursor, Insiders, VSCodium) a per-fork
  title parser (`Insights/Parsers/VSCodeFamily/`) replaces generic attention
  with `vscode_active_doc_changed` (parsed `workspace_name` + `file_basename`).
  Unparsed titles → `ide_window_title_observed` fallback (default OFF,
  `IDETitlePathSanitizer` strips path tokens). FSEvents on
  `~/Library/Application Support/{Code,Cursor,Code - Insiders,VSCodium}/User/workspaceStorage/`
  emits `vscode_workspace_opened`. FSEvents on
  `~/Library/Application Support/JetBrains/<Product><Y>/options/recentProjects*.xml`
  emits `jetbrains_recent_project_observed`. JetBrains bundle list 13
  (−AppCode, +DataGrip/RustRover/DataSpell). Plugin work (per-edit, debugger,
  terminal, extension list) = Layer D V2, separate track.

**Отложено в v1.1:** AppleScript / Automation (Slack huddle, Xcode active doc) — отдельный TCC-промпт per target app.

**Запрещено (ADR-010):** Screen Recording, keylogging, OCR canvas, захват UI-events целевых приложений, post-commit hooks в юзерском репо.

## Layer B — MVP (ADR-009, ADR-011)
- **Linear + GitHub + Slack.**
- **Linear:** OAuth 2.0 PKCE (loopback redirect на эфемерный порт), scope=`read`, actor=user. Polling 5 мин per-action attribution: `issues(filter:{or:[{activity:{some:{user:{isMe:{eq:true}},createdAt:{gt:$since}}}},{creator:{isMe:{eq:true}},createdAt:{gt:$since}}]})` — server-side filter по моей activity (комментарии / status changes / labels / assigns) + `creator.isMe` backstop. Workspace-wide `updatedAt` filter (Phase 4.2 baseline) был заменён в Phase 4.5 — старая shape засчитывала teammate updates в user activity. Complexity ≈ 75 pts/page, 900/hr под лимит 2M/hr.
- **GitHub:** OAuth Device Flow (RFC 8628 — OAuth Apps не поддерживают PKCE). Polling 5 мин REST `/users/<login>/events` под 5000/hr primary rate-limit. Парсер поддерживает full + stripped PushEvent shapes (authenticated feed возвращает stripped без `commits[]`).
- **Slack:** OAuth 2.0 PKCE distributed-app flow через HTTPS relay (`oauth.gundem.tech/<provider>/callback` Cloudflare Worker → 302 на loopback `127.0.0.1:47824/callback`, обходит Slack distributed-app HTTPS requirement без shipping `client_secret`). Worker — приватный репо `gundemtech/leaf-relay`. Polling 5 мин: `users.profile.get` (huddle state) + `search.messages from:@me` + per-channel `conversations.history` (Phase 4.6.A.3 для reactions count — `search.messages` не возвращает reactions field). DM channels anonymized → "DM" bucket до записи.
- **Phase 4.6 depth (latency / transitions / synthesis):** Layer B расширен без новых провайдеров. **A** latency stats (GitHub PR cycle / review delay; Linear completion duration; Slack reactions count + huddle session distribution) — generic shared `LatencyStats {median, avg, max, sampleCount}`. **B** Linear status transitions — новый event flavor `linear_status_transition` (`payload.event_kind` discriminator поверх baseline `issue_updated`) через nested `Issue.history(first: 10, orderBy: createdAt)` GraphQL fragment + **client-side actor filter** (Linear's history connection не поддерживает filter arg, tянем `viewer { id }` для матча `actor.id == viewer.id`). Mutually-exclusive bucketing started/completed/canceled/reopened по `WorkflowState.type`. **C** synthesis (surface global `weekOverWeekDelta` + новая `longestUninterruptedWindow` derived metric + per-provider streaks `commitStreak`/`issueCloseStreak`/`huddleParticipationStreak`).
- **Phase 4.7.A — wide cheap (events feed expansion + cross-provider linking):** Layer B parsers расширены 11 новыми event_kind discriminators поверх existing tick'ов (no new HTTP/GraphQL fetch methods). GitHub: `pr_review_comment_authored` / `issue_comment_authored` / `release_published` / `branch_created` / `branch_deleted` / `tag_created` / `discussion_authored` / `discussion_comment_authored`. Slack: `slack_status_change` (custom emoji transitions, ADR-010 — text body не читаем) и `slack_thread_reply_aggregate` (subset of message count, derived from `thread_ts`). Linear: `linear_comment_authored` aggregate через nested comments fragment с client-side actor filter. **Cross-provider linking:** `LinearIDExtractor` (regex `[A-Z][A-Z0-9]{1,4}-\d+` + prefix whitelist) hook'ается в GitHub commit messages + PR titles → metadata `linked_linear_id`. Tactical плана и full design — `.claude/plans/phase-4-7-design.md` / `phase-4-7-A.md`.
- **Phase 4.7.B — presence-first first-class APIs (state-snapshot endpoints + `presence_state` writers + 4 MCP tools):** Layer B расширен state-snapshot endpoints всех трёх провайдеров (то что **не** сидит в per-event feeds), composite write в `presence_state` table (созданной в A) + 11 новых event_kind discriminators. **GitHub:** `fetchNotifications` / `fetchPRsAwaitingReview` / `fetchMyOpenPRs` / `fetchActionsRunsForActor` (bounded fan-out top-10 active repos) / `fetchCheckRunsForCommit` (push-triggered) / `fetchContributionsCalendar` (daily GraphQL cooldown). **Linear:** existing `viewerActivityIssues` query расширен 3 root-level fields — `viewer.assignedIssues` (workload pulse) / `viewer.teams.activeCycle` (cycle progress per team) / per-issue `attachments(first:10)` enrichment (link extraction → `linked_github_pr_count` / `linked_slack_message_count` payload fields). **Slack:** `fetchPresence` (users.getPresence) / `fetchDND` (dnd.info) / `fetchMentionsReceived` (search.messages `<@USER_ID>`) / `fetchFilesUploaded` (search.files `from:me`, mime-type bucket image/code/doc/other). 11 новых event_kinds + composite presence_state.{github,linear,slack} writes через atomic `writeEventsOffsetAndPresence` (B-0 infrastructure). 4 новых MCP tools: `get_current_presence` / `get_workload_pulse` / `get_review_activity` / `get_cross_provider_thread`. ADR-010: bodies / message text / titles / filenames / preview / output.* НЕ хранятся; только counts + buckets + structured metadata. Tactical: `.claude/plans/phase-4-7-B.md`.
- **Phase 4.7.C — triage / state-change depth + skeleton queries + ModeClassifier substrate:** Layer B `Issue.history` fragment расширен 6 transition flavors (cost-free piggy-back на existing connection): `linear_priority_changed` (raw int 1=Urgent..4=Low) / `linear_label_added` + `linear_label_removed` (один history entry → N+M events с label.id+name) / `linear_assignee_changed` (anonymized 7-bucket enum: assigned_to_self / to_other / unassigned_from_self / from_other / reassigned_self_to_other / other_to_self / other_to_other — raw third-party assignee IDs не покидают provider) / `linear_cycle_changed` (added/moved/removed) / `linear_estimate_changed` (story points). Все mirror 4.6.B status pattern: actor.id == viewer.id client-side filter + cursor guard + degenerate-noop reject. **Linear separate-from-history queries (piggy-back fragments в той же `LeafPoll` query — single HTTP call):** `linear_project_update_authored` (top-level `projectUpdates(filter: { user: { isMe }})` — id + project + health enum, body НЕ запрашивается) / `linear_document_edited` skeleton (top-level `documents(filter: { creator: { isMe }})` — id + title + project, content/preview никогда; per-tick graceful degrade на legacy workspaces) / `linear_initiative_observed` (`viewer.initiatives` fragment — context signal, observedAtMs = tick timestamp; membership snapshot, не state change). **GitHub:** `pr_review_thread_resolved` (single new case в mapEvents switch — only action=resolved emits; unresolved skipped). **ModeClassifier substrate** (types-only, под Phase 4.9): `Mode` enum (code/coordination/review/focus/meeting) + `Pulse` enum (heavy/medium/light) + `ClassifiedMode` struct + `ModeClassifier` protocol в `LeafCore/Insights/`. `DefaultModeClassifier` impl откладывается на 4.9; `presence_state.derived_mode` остаётся NULL. ShareEventTypeKey registry 33 → 43 (8 outcome-bearing ON by default, documents/initiatives skeleton OFF). ADR-010: per-flavor sentinel-injection regression tests + integration test sentinel walk по всему RawEvent payload tree. Tactical: `.claude/plans/phase-4-7-C.md`.

## Layer C (V1.5+) и Layer D (V2)
- Layer C: MCP-aggregator (Figma / Notion / Jira / Gmail / Calendar).
- Layer D: собственные плагины (Figma plugin, VS Code extension, Chrome extension).

## Хранение (ADR-017)
- **GRDB 7.10+ fork** + SQLCipher через SwiftPM (официальной интеграции нет — community fork).
- SQLite в WAL mode, три процесса (Agent writer + MCPServer reader + MenuBarApp reader) → один файл, cross-process POSIX locks, `DatabasePool` в каждом процессе. (AI Coworker P3: MCPServer `escalate_to_ai` дополнительно открывает кратковременный writer для append в `ai_escalation_audit` — обоснованное ADR-019-отступление «каждая эскалация залогирована».)
- Обязательные pragma: `cipher_plaintext_header_size` (tuned value в moat) + external salt (iOS-ready), `busy_timeout` (tuned value в moat), `PRAGMA key = x'HEX'` с raw keyspec (без PBKDF2 на каждом open).
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
- AI collaboration events живут в unified `events` table с `signal_type='aiCollaboration'`; per-kind discriminators в `payload_json.event_kind` (Track-6 P1: 16 visible claude_* kinds + retroactive `tool_use`/`user_prompt`). Tool/file attribution из Claude Code / Cursor / Windsurf / Continue hooks landed via ADR-010 allowlist (parser strips `command`/`tool_input`/`tool_response`/`content`/`thinking`/`signature` before emit). Subagent rows distinguishable via non-null `payload_json.agent_id` (M024 partial expression index `idx_events_ai_subagent` covers Phase 4.9 rollup queries). Prompt/response content — никогда (ADR-010).
- `correlations` — связи между events (populated post-MVP, схема готова).
- `integrations` — OAuth state (Linear MVP).
- `blocklist` — user exclusions (apps / URLs / folders).
- `watched_folders` — security-scoped bookmarks + L5 opt-in flag.
- `share_apps` — per-app whitelist: bundle_id, enabled, max_granularity, mode (shared / silent / invisible), added_ts.
- `share_event_types` — per-event-type whitelist: event_type (git_commit / linear_update / meeting_status / focus_mode / etc), enabled, redact_level, added_ts.
- `presence_state` — single-row-per-provider materialized view current presence ceiling (Phase 4.7.A M005). Read by MenuBarApp self-UI и Phase 5 broadcaster (encrypted snapshot). PK — `provider`. Writes — Track 4.7.B (composite GitHub / Linear / Slack rows landed; `derived_mode` column остаётся NULL до Phase 4.9).
- `presence_outgoing` — audit log "что я шлю коллегам" (после Share Controls filter).
- `presence_history` — incoming presence от коллег (forever retention — fabric команды).
- `team_members` — long-term X25519 pubkeys.
- `team_keys` — history team key rotations.
- `org` — organization metadata (1 row).
- `events_fts` — FTS5 contentless virtual table over D1 bodies (Phase Track-1 D2 M012); `events_fts_meta` sidecar `(fts_rowid, event_id, body_kind)` retrieves matches.
- `event_links` — cross-source association graph (Phase Track-1 D2 M013): `(from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms)` composite PK + reverse-lookup index.
- `decisions` — DecisionDetector hits (Phase Track-1 D3 M014): `(event_id UNIQUE → events.id logical FK, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms)`.
- `open_questions` — OpenQuestionDetector hits + resolution flow (D3 M014): `(event_id UNIQUE, question_excerpt, alternatives_json, slack_thread_ts/linear_issue_ref/github_pr_ref context refs, resolved_by_event_id NULLABLE, opened_at_ms, resolved_at_ms NULLABLE)` + 4 partial filtered indexes.
- `blockers` — BlockerPatternDetector + LinearStuckScanner hits (D3 M014): `(target_kind, target_ref, blocker_kind, blocker_excerpt, detected_by_event_id, started_at_ms, resolved_at_ms NULLABLE, resolved_by_event_id NULLABLE)` + partial unique `idx_blockers_open` WHERE resolved IS NULL (один OPEN blocker per target).
- `where_stopped_log` — append-only WhereStoppedDeriver snapshots (D3 M014): `(generated_at_ms, anchor_event_id NULLABLE, excerpt, wip_signals_json)`. Заменяет планировавшийся sessions extension (substrate не имеет sessions table).
- `detector_offsets` — per-detector cursor (D3 M014): `(detector_kind PK, cursor_event_id, last_run_at_ms)` pre-seeded `decision`/`open_question`/`blocker_pattern`. Scheduled detectors (linear_stuck, where_stopped) cursor не используют.
- `ai_escalation_audit` — append-only reverse-audit AI-эскалаций (AI Coworker P3, M031): `(id PK, generated_at_ms, question_excerpt NULLABLE, model, event_ids_json, source_summary)` + index на `generated_at_ms`. Метаданные+refs (event ids) + свой вопрос, НЕ тела; пишется audit-first перед LLM-POST. Read-back — MCP `get_ai_escalation_log`.
- `handoff_audit` — append-only reverse-audit AI-handoff'ов команде (AI Coworker P4, M032): `(id PK, generated_at_ms, message_id, recipient_member_id, model, path, period_start/end_ms, fact_count, escalated, crossposted_slack/linear, source_summary, topic_excerpt NULLABLE)` + index. AI-provenance + refs + свой topic, НЕ тела, НЕ recipient pubkey; пишется at-send (E2E team-egress, §8 п.4). Read-back — MCP `get_handoff_log`.

Миграции — через GRDB migrations framework. Текущий счёт: M001..M032 (unified trunk; счёт таблиц — см. git). **Migration-guard (Ph C, R7):** на open БД, чьи applied-миграции новее бинаря (`migrator.hasBeenSuperseded`), `Database.openForWrite`/`openForRead` бросают `LeafError.databaseSchemaFromFuture` → MenuBarApp показывает `DatabaseRecoveryView` (Backup&Reset/Reveal/Quit), Agent `exit(0)` (no launchd crash-loop), MCP — clean error; не «Couldn't load Home».

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
- **MCPServer** — on-demand bonus channel для AI-клиентов. 12 tools: `get_timeline`, `find_last_activity`, `get_current_session`, `get_ai_activity`, `get_linear_activity`, `get_github_activity`, `get_slack_activity`, `get_uninterrupted_window` (Phase 4.6 baseline) + Phase 4.7.B presence-first additions: `get_current_presence`, `get_workload_pulse`, `get_review_activity`, `get_cross_provider_thread`. + AI Coworker: `ask_about_my_work` (P1, structured Q&A) / `escalate_to_ai` + `get_ai_escalation_log` (P3, bodies-эскалация + reverse-audit) / `get_handoff_log` (P4, AI-handoff reverse-audit). Live registry — 20 tools (см. `MCPServer.swift`). Отдаёт structured JSON через Derived Insights Engine. **AI Coworker P4 — первая in-app AI-поверхность:** `HandoffDrafter` (LeafCore, body-free draft через §8.1-границу) + `HandoffDraftReader` (app, «Draft with AI» в `SendDirectMessageSheet`) → одобренный текст уходит E2E коллеге существующим `DirectMessageService` (kind `.handoff`), send-time → `handoff_audit`.
- **PresenceRelay** — Cloudflare DO + AES-GCM: broadcast encrypted blobs connected peers (фактически built — `oauth.gundem.tech/v1/invite/*` + `/v1/key-rotation/*` live на Workers; whitepaper v0.1-beta планирует миграцию на Supabase + XChaCha20-Poly1305 — substrate готов, миграция отдельным треком)
- **Safety handle** — freeze/wipe устройство коллеги по запросу юзера. **Отложено в v1.1** (в MVP достаточно "Remove member" + self-wipe).

---

> Текущий срез "как оно сейчас устроено" (substrate). Подробности и обоснования (в public-safe формулировке) — в whitepaper `~/Desktop/Leaf/leaf-docs/docs/memory-architecture/` (capture / storage / summarization / query) + `team-sharing/` + `privacy-security/`. Ярлыки ADR-XXX в тексте — исторические, живой источник правды = whitepaper v0.1-beta. Implementation moat (SQL Derived Insights bodies, точные пороги, crypto byte layouts, Share Controls preset) — в приватных модулях кода (`LeafCore/Private/`), не здесь, не в публичном `gundemtech/leaf` repo, не в whitepaper. См. `pre-push-leaf` checklist в корневом CLAUDE.md.
