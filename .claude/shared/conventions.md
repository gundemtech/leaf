# Соглашения команды

## Код
- Язык: Swift
- Отступы: 4 пробела
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

## Shared memory hygiene

Файлы в `.claude/shared/` автоматически загружаются в контекст Claude Code при старте сессии. Чтобы не раздувать каждую сессию:

- Каждый файл ≤ 200 строк (ориентир ~8-10KB)
- `current-state.md` ≤ 50 строк
- Корневой `CLAUDE.md` ≤ 100 строк
- Это **текущий срез**, не история. Исторические решения — в whitepaper changelog
- Видишь что файл распух → предлагай рефактор. Ревизия — `/audit-brain`

---

> Частые правки этого файла — признак что пора зафиксировать решение в whitepaper.
