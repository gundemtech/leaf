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
- Клон: `~/Desktop/leaf-docs`
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

## Shared memory hygiene

Файлы в `.claude/shared/` автоматически загружаются в контекст Claude Code при старте сессии. Чтобы не раздувать каждую сессию:

- Каждый файл ≤ 200 строк (ориентир ~8-10KB)
- `current-state.md` ≤ 50 строк
- Корневой `CLAUDE.md` ≤ 100 строк
- Это **текущий срез**, не история. Исторические решения — в whitepaper changelog
- Видишь что файл распух → предлагай рефактор. Ревизия — `/audit-brain`

---

> Частые правки этого файла — признак что пора зафиксировать решение в whitepaper.
