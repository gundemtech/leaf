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
   - дописать в `docs/reference/changelog.md` запись формата
     `- **YYYY-MM-DD HH:MM · <автор>** — описание` (HH:MM обязательно; автор —
     метка по git identity сессии, список валидных меток — `leaf-docs/CLAUDE.md`;
     детальный спек — там же, раздел «Правила работы с контентом»),
   - `git add` + коммит `docs: ...` + `git push origin main`,
   - отчитаться: "Засинкано в leaf-docs: файлы, коммит `<hash>`".
3. **Что синкать в whitepaper (public-safe концепты):** философия, видение, ICP, сигналы (типы/слои), архитектурный каркас, opt-in transparency, share-controls как модель, конкуренты, дифференциаторы, pricing tiers, глоссарий, won't-list, high-level changelog.
4. **Что НЕ синкать в whitepaper (implementation moat):** SQL-запросы, точные пороги (idle, polling, heartbeat, WAL checkpoint), SQLCipher pragma values, bytes layouts crypto envelope, HKDF info strings, exact nonce generation, git log format strings, Claude Code hooks JSON parser, Share Controls preset bundle IDs, Cloudflare Worker внутренности, ship timeline, имена сотрудников, клиентские детали.
5. **Явный триггер:** `/sync-docs <тема>` форсирует синк прямо сейчас.
6. **Pull перед новой задачей (обязательно).** Перед началом любой задачи, касающейся архитектуры / продукта / whitepaper, а также в начале сессии — выполнить `git -C ~/Desktop/Leaf/leaf-docs pull --ff-only --quiet`. Партнёр мог обновить whitepaper пока ты не смотрел. Если pull пишет про merge/conflict — остановись и покажи юзеру. Если pull успешен и что-то реально изменилось — коротко сообщи: "В leaf-docs подтянул N коммитов, последний: `<hash> — <msg>`".

Branch protection на `leaf-docs` пока нет — push прямой в `main`. Когда появится — PR-flow.

## Pre-push в `gundemtech/leaf` (публичный app-репо)

Перед каждым `git push` в `gundemtech/leaf` — **обязательно** `/pre-push-leaf`. Если хоть одно ❌ → остановись, покажи юзеру, спроси.

❌ Не коммитим: секреты (OAuth secrets, Sparkle keys, CF tokens, team keys, PAT), SQL DI bodies (`timeInApp`/`focusSessions`/etc — moat), точные пороги (idle, polling, heartbeat, WAL checkpoint, SQLCipher pragma, KDF params), Share Controls preset bundle IDs, Cloudflare Worker / relay код (приватный `gundemtech/leaf-relay`), crypto envelope details (nonce gen / HKDF info / AAD / byte layouts), git polling command, Claude Code hooks parser, commit messages с именами/датами/клиентскими деталями.

✅ OK: имена модулей / таблиц / MCP tools / DI функций (уже в whitepaper), public lib versions, generic patterns (Keychain errors, AX flow, WAL discipline), UI-код.

Полный чек-лист (что ❌ / что ✅) — `.claude/commands/pre-push-leaf.md`. Автоматический `gitleaks` hook — добавим когда появится код.

## Команды

- `/sync-docs <тема>` — синхронизация решения в whitepaper (leaf-docs).
- `/pre-push-leaf` — ручная проверка diff перед пушем в публичный app-репо.
- `/audit-brain` — ревизия shared memory (размеры `.claude/shared/*.md`).

## leaf-internal — internal dashboard

Репо подаёт данные на внутренний дашборд `leaf-internal.gundem.tech` (приватный, basic auth). Settings.json hook автоматом sanitize-публикует изменения `~/Desktop/Leaf/leaf-internal/architecture.yaml` (после добавления нового компонента в LeafCore — добавь component узел с status/owner) и `roadmap.yaml` (после закрытия milestone — phase status → done + completed_at + progress_pct).

Handoff/blocked-комменты в `.claude/plans/<plan>.md` — дашборд парсит и выводит на «Требует внимания»:

- `<!-- @anton: возьми с Task 12 -->` — handoff
- `<!-- BLOCKED: ждём merge PR #142 -->` — блокер
- `<!-- TBD -->` — фаза не расписана

Полное описание — [leaf-docs/infra/specs/2026-05-10-leaf-internal-dashboard-design.md](https://github.com/gundemtech/leaf-docs/blob/main/infra/specs/2026-05-10-leaf-internal-dashboard-design.md).

## Team awareness через leaf-presence MCP

Если у текущей Claude Code сессии есть MCP сервер `leaf-presence` (проверь через mention в tool inventory: `leaf_team_status`, `leaf_handoff_list`, `leaf_question_list` и др.):

**В начале сессии**, если cwd одна из `~/Desktop/Leaf/{leaf,leaf-internal,leaf-docs,leaf-relay}`:

1. Вызови `leaf_handoff_list(scope="me")` — pending handoffs ко мне
2. Вызови `leaf_question_list(scope="me-target")` — open questions ко мне
3. Прочитай `leaf://team/drifts/active` — есть ли у меня drift'ы (текущая ветка/план не в `roadmap.yaml`)
4. Если что-то ненулевое — суммируй первым сообщением: «У тебя N handoffs, M questions, K drifts. [Список одной строкой]. Что разбираем?»
5. Если всё пусто — не упоминай team awareness, переходи к запросу пользователя.

**Когда пользователь говорит** «спроси Алекса X» / «уточни у Саши Y» — используй `leaf_ask_question(to="dima"/"anton", text=..., plan_ref=current_plan, branch_ref=current_branch)` вместо Telegram. Текст question'а ≤ 140 символов.

**Когда видишь open question касающийся текущего плана/ветки** (через `leaf_question_list(scope="me-target")` или `leaf://team/questions/open`) — ответь через `leaf_answer_question(question_id, text)` с текстом ≤ 280 символов, или явно скажи пользователю «не знаю, эскалируй».

**Когда заканчиваешь работу над feature** с незакрытыми TodoWrite items и пользователь подтвердил pause — предложи `leaf_handoff_create(...)` для другого члена команды или для будущей own session.

**Drift response.** Если `leaf://team/drifts/active` показал что моя ветка/план не в roadmap — упомяни пользователю: «branch X не в roadmap.yaml — добавить или это draft?» Не добавляй сам, только спроси.

**Когда НЕ использовать** ask_question / handoff_create:
- Если вопрос/задача — short, in-flight clarification («какой именно параметр функции?») — это inline conversation, не async question.
- Если пользователь явно сказал «не пиши Алексу / не дёргай команду».
