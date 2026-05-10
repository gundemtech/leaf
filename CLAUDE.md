# Leaf — общий контекст проекта

Этот файл читается Claude Code в начале каждой сессии у каждого разработчика команды.
Ниже подгружаются общие заметки (shared memory).

@.claude/shared/architecture.md
@.claude/shared/conventions.md
@.claude/shared/current-state.md
@.claude/shared/glossary.md

## Правила работы команды

- Язык общения: русский.
- **Linear** — только таск-трекер (проект `Leaf`). НЕ второй мозг. Никаких ADR, session logs, ideas docs там не ведём. Есть Linear MCP для работы с issues.
- **Whitepaper (`gundemtech/leaf-docs`) — единственный второй мозг команды.** Все содержательные решения (архитектура / продукт / философия / pricing / ICP / MVP scope) живут там в public-safe формулировке.
- Личная auto-memory каждого разработчика остаётся локально в `~/.claude/` и в репо **не** попадает.
- **Shared memory дисциплина:** файлы `.claude/shared/*.md` грузятся в контекст каждой сессии — держим компактно (каждый ≤ 200 строк, только "текущий срез", без истории). Ревизия: `/audit-brain`.

## Whitepaper — source of truth

Публичный whitepaper живёт в `gundemtech/leaf-docs` (клон в `~/Desktop/Leaf/leaf-docs`, рядом с `~/Desktop/Leaf/leaf`). Сайт: `leaf-docs.gundem.tech`, стек — MkDocs Material, push в `main` = автодеплой.

**Правила для Claude Code (обязательные, без напоминания):**

1. **Читай whitepaper как источник правды.** В любой сессии где обсуждаются архитектура / продукт / философия / ICP / pricing / MVP / конкуренты / глоссарий — свериться с `~/Desktop/Leaf/leaf-docs/docs/` перед ответом. Противоречие с whitepaper → whitepaper приоритетнее, явно проговори.
2. **Синхронизируй изменения автоматически.** Принято содержательное решение уровня whitepaper — **не дожидаясь просьбы**:
   - найти нужный раздел в `~/Desktop/Leaf/leaf-docs/docs/` (структура в `leaf-docs/CLAUDE.md`),
   - обновить markdown + admonition `!!! note "Изменение vX.Y — YYYY-MM-DD"` (раньше / теперь / причина),
   - дописать в `docs/05-reference/changelog.md` запись формата
     `- **YYYY-MM-DD HH:MM · Dmitrii** — описание` (HH:MM обязательно;
     детальный спек — `leaf-docs/CLAUDE.md` раздел «Правила работы с контентом»),
   - `git add` + коммит `docs: ...` + `git push origin main`,
   - отчитаться: "Засинкано в leaf-docs: файлы, коммит `<hash>`".
3. **Что синкать в whitepaper (public-safe концепты):** философия, видение, ICP, сигналы (типы/слои), архитектурный каркас, opt-in transparency, share-controls как модель, конкуренты, дифференциаторы, pricing tiers, глоссарий, won't-list, high-level changelog.
4. **Что НЕ синкать в whitepaper (implementation moat):** SQL-запросы, точные пороги (idle, polling, heartbeat, WAL checkpoint), SQLCipher pragma values, bytes layouts crypto envelope, HKDF info strings, exact nonce generation, git log format strings, Claude Code hooks JSON parser, Share Controls preset bundle IDs, Cloudflare Worker внутренности, ship timeline, имена сотрудников, клиентские детали.
5. **Явный триггер:** `/sync-docs <тема>` форсирует синк прямо сейчас.
6. **Pull перед новой задачей (обязательно).** Перед началом любой задачи, касающейся архитектуры / продукта / whitepaper, а также в начале сессии — выполнить `git -C ~/Desktop/Leaf/leaf-docs pull --ff-only --quiet`. Партнёр мог обновить whitepaper пока ты не смотрел. Если pull пишет про merge/conflict — остановись и покажи юзеру. Если pull успешен и что-то реально изменилось — коротко сообщи: "В leaf-docs подтянул N коммитов, последний: `<hash> — <msg>`".

Branch protection на `leaf-docs` пока нет — push прямой в `main`. Когда появится — PR-flow.

## Pre-push чек-лист для `gundemtech/leaf` (app-репо, ПУБЛИЧНЫЙ)

App-репо **публичный**. Перед каждым `git push` в `gundemtech/leaf` Claude Code **обязательно** пробегает diff по чек-листу. Если хоть одно ❌ — **остановись, покажи юзеру, спроси**.

### ❌ НЕ коммитить в `leaf`
- **Секреты:** OAuth client secrets, EdDSA/Sparkle signing keys, Cloudflare tokens, team keys, keychain raw values, GitHub PAT. → GitHub Secrets / Keychain / `.env` (в `.gitignore`).
- **SQL-запросы Derived Insights Engine** (тела функций `timeInApp`, `focusSessions`, `contextSwitchRate`, `teamPresenceOverlap`, `aiRatio` и т.д.) — moat. Коммить сигнатуры, тела держать в приватном модуле `LeafCore/Private/` (в `.gitignore`) или obfuscated.
- **Точные пороги и числа:** idle threshold, polling intervals (5 мин Linear), heartbeat (60с), WAL checkpoint (15 мин / 4MB), SQLCipher pragma values, KDF params. → `Config.swift` с публичными именами, значения из `.env` / build settings.
- **Share Controls preset** (bundle IDs "common dev defaults" — Xcode, Cursor, Slack…) — хардкод = reverse engineer. → runtime-конфиг с сервера при onboarding.
- **Cloudflare Worker / relay TypeScript код** — отдельный приватный репо `gundemtech/leaf-relay`. В `leaf` только клиент WebSocket.
- **Crypto envelope имплементация:** exact nonce generation, HKDF info strings, AAD content, byte layouts — приватный модуль.
- **Git polling command** (exact `git log --format=...`, parsing logic) — moat над конкурентами.
- **Claude Code hooks parser** (JSON schema, fallback `~/.claude/projects/*.jsonl` handler) — moat.
- **Коммит-сообщения и PR descriptions:** без имён сотрудников, ship dates, внутренних дискуссий, клиентских деталей, competitive intel.
- **TODO/FIXME c внутренним контекстом** ("hack because Linear quirk X") → Linear issue, не в код.

### ✅ Можно в коммит
- Архитектурный каркас: имена модулей (Agent / LeafCore / MenuBarApp / MCPServer), имена таблиц БД, имена 8 MCP tools, имена 12 функций Derived Insights Engine — это уже в whitepaper.
- Публичные версии библиотек (GRDB 7, Sparkle 2.6+, CryptoKit, Swift 6) — видны в `Package.swift` всё равно.
- High-level комменты со ссылками на whitepaper: `// See: leaf-docs/03-architecture/share-controls.md`.
- Generic patterns: Keychain access errors, AX permission flow, WAL checkpoint discipline (известно в OSS), Linear now-30s clock skew.
- UI-код: SwiftUI views, layouts, styling, Liquid Glass — витрина продукта, moat не тут.

### Механизм

Ручной проход diff — команда `/pre-push-leaf` (см. `.claude/commands/pre-push-leaf.md`). Запускать **перед каждым** `git push` в `gundemtech/leaf`.

Автоматический: добавим `gitleaks` pre-commit hook когда появится код.

## Команды

- `/sync-docs <тема>` — синхронизация решения в whitepaper (leaf-docs).
- `/pre-push-leaf` — ручная проверка diff перед пушем в публичный app-репо.
- `/audit-brain` — ревизия shared memory (размеры `.claude/shared/*.md`).

## leaf-internal — internal dashboard

Этот репо подаёт данные на внутренний дашборд `leaf-internal.gundem.tech` (приватный, под basic auth, только Антон + Дима).

### Когда обновлять architecture.yaml

После добавления нового компонента в `Packages/LeafCore/Sources/LeafCore/{Detection,Collectors,DB,MCP,E2E}/...`:

1. Открой `~/Desktop/Leaf/leaf-internal/architecture.yaml`.
2. Найди соответствующий layer (или создай новый).
3. Добавь component узел (status: in-progress / done / planned / blocked, owner: dima / anton / claude-vps).
4. Сохрани — settings.json hook автоматом sanitize-публикует и пушит в leaf-internal.

### Когда обновлять roadmap.yaml

После закрытия milestone (Phase X.Y wrap, Track X done): обнови phase-узел status → done + completed_at, parent's progress_pct.

### Handoff/blocked-комменты в плане

В `~/Desktop/Leaf/leaf/.claude/plans/<plan>.md`:

- `<!-- @anton: возьми с Task 12 -->` — handoff
- `<!-- BLOCKED: ждём merge PR #142 -->` — блокер
- `<!-- TBD -->` — фаза не расписана

Дашборд парсит и выводит на главной «Требует внимания».

### Spec

Полное описание — [leaf-docs/infra/specs/2026-05-10-leaf-internal-dashboard-design.md](https://github.com/gundemtech/leaf-docs/blob/main/infra/specs/2026-05-10-leaf-internal-dashboard-design.md).

## Team awareness через leaf-presence MCP

Если у текущей Claude Code сессии есть MCP сервер `leaf-presence` (проверь через mention в tool inventory: `leaf_team_status`, `leaf_handoff_list`, `leaf_question_list` и др.):

**В начале сессии**, если cwd одна из `~/Desktop/Leaf/{leaf,leaf-internal,leaf-docs,leaf-relay}`:

1. Вызови `leaf_handoff_list(scope="me")` — pending handoffs ко мне
2. Вызови `leaf_question_list(scope="me-target")` — open questions ко мне
3. Прочитай `leaf://team/drifts/active` — есть ли у меня drift'ы (текущая ветка/план не в `roadmap.yaml`)
4. Если что-то ненулевое — суммируй первым сообщением: «У тебя N handoffs, M questions, K drifts. [Список одной строкой]. Что разбираем?»
5. Если всё пусто — не упоминай team awareness, переходи к запросу пользователя.

**Когда пользователь говорит** «спроси Диму X» / «уточни у Антона Y» — используй `leaf_ask_question(to="dima"/"anton", text=..., plan_ref=current_plan, branch_ref=current_branch)` вместо Telegram. Текст question'а ≤ 140 символов.

**Когда видишь open question касающийся текущего плана/ветки** (через `leaf_question_list(scope="me-target")` или `leaf://team/questions/open`) — ответь через `leaf_answer_question(question_id, text)` с текстом ≤ 280 символов, или явно скажи пользователю «не знаю, эскалируй».

**Когда заканчиваешь работу над feature** с незакрытыми TodoWrite items и пользователь подтвердил pause — предложи `leaf_handoff_create(...)` для другого члена команды или для будущей own session.

**Drift response.** Если `leaf://team/drifts/active` показал что моя ветка/план не в roadmap — упомяни пользователю: «branch X не в roadmap.yaml — добавить или это draft?» Не добавляй сам, только спроси.

**Когда НЕ использовать** ask_question / handoff_create:
- Если вопрос/задача — short, in-flight clarification («какой именно параметр функции?») — это inline conversation, не async question.
- Если пользователь явно сказал «не пиши Диме / не дёргай команду».
