# Термины проекта

Общий словарь — чтобы оба Claude Code и оба разработчика говорили одинаково.

| Термин | Значение |
|---|---|
| **Leaf** | Название продукта (macOS, далее iOS). Имя app-репо — `gundemtech/leaf`. |
| **leaf** (репо) | Публичный репо приложения, `gundemtech/leaf` |
| **leaf-docs** (репо) | Публичный репо whitepaper, `gundemtech/leaf-docs`. Сайт: `leaf-docs.gundem.tech` |
| **leaf-relay** (репо) | Приватный репо Cloudflare Worker (TypeScript, presence-relay). Будет создан. |
| **Второй мозг** | Whitepaper в `leaf-docs`. Единственный источник правды для продуктовых и архитектурных решений. |
| **Shared memory** | `.claude/shared/*.md` в репо `leaf` — контекст, автоматически читаемый Claude Code у всей команды |
| **Whitepaper** | Публичная документация продукта, MkDocs Material, текущая версия v1.4 |
| **Implementation moat** | Детали, которые НЕ публикуем: SQL queries, точные пороги/числа, crypto internals, preset bundle IDs, Cloudflare код. Остаются в приватных модулях. |

---

> Дополняется по мере появления доменных терминов. Домашние термины продукта (ambient memory, metadata-first, opt-in transparency, share controls и т.д.) — в `leaf-docs/docs/05-reference/glossary.md`.
