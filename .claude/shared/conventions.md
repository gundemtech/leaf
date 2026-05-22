# Соглашения команды

## Код
- Язык: Swift
- Отступы: **2 пробела** — enforced by swift-lsp plugin formatter (PostToolUse hook reformats on every Edit/Write). Не пытайся писать 4-space, hook всё равно перепишет.
- Стиль: TBD _(дополнять по мере накопления решений)_

## Git — app-репо (`gundemtech/leaf`, ПУБЛИЧНЫЙ)
- Репо: `git@github.com:gundemtech/leaf.git`
- Основная ветка: `main`
- Фича-ветки: `feature/<кратко>`, багфиксы: `fix/<кратко>`
- Коммиты: imperative, коротко, без внутренних имён / ship dates / клиентских деталей
- **Перед каждым `git push`: `/pre-push-leaf`** (проверка diff на утечки moat-деталей, см. корневой `CLAUDE.md`)

## Git — whitepaper (`gundemtech/leaf-docs`, ПУБЛИЧНЫЙ)
- Клон: `~/Desktop/Leaf/leaf-docs` (рядом с `~/Desktop/Leaf/leaf`)
- Прямой push в `main` (branch protection пока нет)
- Коммиты: `docs: <что>`, `fix: <опечатка>`, `chore: <служебное>`
- Триггер синка из сессии: автоматом при принятии решения уровня whitepaper, либо `/sync-docs`

## Git — relay (`gundemtech/leaf-relay`, ПРИВАТНЫЙ, будет создан)
- TypeScript / Cloudflare Workers код
- **Не** в `gundemtech/leaf`. В `leaf` только клиент WebSocket.

## Процесс работы
- Задачи — в Linear, проект `Leaf` (только таски, не второй мозг)
- Решения уровня whitepaper → автосинк в `leaf-docs` (см. корневой `CLAUDE.md`, раздел "Whitepaper — source of truth")
- Обоснования и альтернативы решений — в whitepaper в public-safe формулировке (admonition `!!! note "Изменение vX.Y"`)
- Implementation-детали (код, SQL, пороги) — в приватных модулях кода, НЕ в whitepaper

## Работа вдвоём

Оба разработчика работают на одном репо параллельно через Claude Code. Координация — поверх git, без отдельных трекеров и WIP-файлов в норме.

**Минимальная схема:**
- **Feature work — всегда на feature branch** (`feature/<short>` или `<who>/<short>`). Прямой push в `main` допустим только для chore-уровня: `chore:`, `ci:`, `docs:`, `release:`.
- **Имя ветки + последний commit message = весь контекст** для партнёра и его Claude. Никаких параллельных «что я сейчас делаю»-файлов в норме.

**Чек-лист первого шага сессии (Claude обязан выполнить перед содержательной работой):**

```bash
git fetch --all --prune
git -C ~/Desktop/Leaf/leaf-docs pull --ff-only --quiet
git branch -r --sort=-committerdate | head -10
```

Этого достаточно чтобы увидеть, что партнёр сейчас в полёте делает. Если непонятно — `git log origin/feature/<X> --stat -5` показывает затронутые файлы.

**Когда поднимать тревогу:**
- Если перед стартом задачи `git log` партнёрской ветки показывает активные изменения **тех же файлов / модулей**, что планируется трогать → стоп, согласовать до начала работы.
- В норме пересечения нет (один на UI, другой на network / storage / crypto) — работаем параллельно без обсуждения.

**`.claude/shared/wip.md` — только для исключений:**

Файл пустой / отсутствует в норме. Пишем туда **только** когда есть критичный констрейнт, не видный из git:
- «В полёте migration DB schema, не трогай `Storage/Migrations` до merge»
- «API провайдера X сломано upstream, не add'й новые fetch-методы туда»
- «Жду ответа от Sparkle / Apple — не закрывайте релизный flow»

Не писать «сегодня делаю фичу Y» — это уже видно из branch name.

**`current-state.md`** обновляется только в финальном merge-commit'е feature branch → main. Не во время работы — так нет merge-конфликтов на этом файле.

## Одна phase = одна сессия (workflow для max quality)

Каждая phase из roadmap (например `5.1.A`, `5.1.B`, ..., `5.4`) делается в **новой Claude-сессии**. Контекст не размывается, каждая сессия — clean start с минимально-необходимым контекстом из shared memory + relevant spec'ов в `docs/superpowers/specs/`.

**Шаблон первого сообщения новой сессии:**

> «Делаем Phase X.Y.Z (короткое название). Контракт уровня phase'а — `docs/superpowers/specs/<contract>.md`. Если есть предыдущий phase spec — `docs/superpowers/specs/<prev-phase>.md`, тоже прочитай. Идём по 8-этапному workflow из `conventions.md` раздел "Одна phase = одна сессия".»

**8 этапов одной phase-сессии:**

1. **Discovery** — `Explore` subagent делает comprehensive snapshot релевантного кода; main session cross-check'ит ключевые файлы сам (verify subagent output).
2. **Brainstorm** — `superpowers:brainstorming` skill в полный flow: один вопрос за раз, approaches с tradeoffs, design sections с approval per section. Никаких пропусков «очевидных» решений. Длительность зависит от scope: фаза с готовым дизайном — 5-15 минут confirm; фаза с архитектурной поверхностью — 60-90 минут.
3. **Spec write** — spec в `docs/superpowers/specs/`, self-review (placeholders / consistency / scope / ambiguity), user review gate с явным approve.
4. **Plan** — `superpowers:writing-plans` skill. Step-by-step (atomic per commit), explicit acceptance criteria.
5. **Implementation** — `superpowers:test-driven-development` per step, **sequential**: test first → run → see fail → implement → run → see pass → commit. После каждого step: все tests still pass, build green. **Никакой parallelization** — sequential discipline, чтобы не пропустить cross-step concerns.
6. **Independent review** — `superpowers:code-reviewer` subagent проверяет всю branch против spec + plan; main session использует `superpowers:receiving-code-review` для обработки feedback. Каждое замечание адресуется (не «easy ones only»).
7. **Verification** — `superpowers:verification-before-completion` skill: все tests pass (verified, not assumed), все builds green, для UI — manual smoke (golden path + edge cases). Никакого «I think it works» — только verified.
8. **Ship** — финальный commit `docs(shared): Phase X.Y.Z landed — current-state update`, PR с резюме review verdict, merge + branch cleanup.

**Где задействованы subagent'ы:**
- Stage 1 — `Explore` (research bandwidth, не quality bypass)
- Stage 6 — `superpowers:code-reviewer` (independent eyes catch cross-step concerns)
- **Implementation parallelizing — нет.** Sequential discipline > speed.

**Skills задействованы (все в active list, применяются явно, не «подразумеваются»):**
- `superpowers:brainstorming` (Stage 2, mandatory)
- `superpowers:writing-plans` (Stage 4, mandatory)
- `superpowers:test-driven-development` (Stage 5 per step)
- `superpowers:requesting-code-review` (Stage 6 trigger)
- `superpowers:code-reviewer` subagent (Stage 6 worker)
- `superpowers:receiving-code-review` (Stage 6 digest feedback)
- `superpowers:verification-before-completion` (Stage 7)

**Контракт-уровневые решения уже зафиксированы** в общем design-doc для всей feature track (например `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md`). Brainstorm каждой phase уточняет только implementation-уровень — encoding choices, file layout, test pattern, commit decomposition.

## Shared memory hygiene

Файлы в `.claude/shared/` автоматически загружаются в контекст Claude Code при старте сессии. Чтобы не раздувать каждую сессию:

- Каждый файл ≤ 200 строк (ориентир ~8-10KB)
- `current-state.md` ≤ 50 строк
- Корневой `CLAUDE.md` ≤ 100 строк
- Это **текущий срез**, не история. Исторические решения — в whitepaper changelog
- Видишь что файл распух → предлагай рефактор. Ревизия — `/audit-brain`

---

> Частые правки этого файла — признак что пора зафиксировать решение в whitepaper.
