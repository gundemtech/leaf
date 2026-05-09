# Термины проекта

Общий словарь — чтобы оба Claude Code и оба разработчика говорили одинаково.

| Термин | Значение |
|---|---|
| **Leaf** | Название продукта (macOS, далее iOS). Имя app-репо — `gundemtech/leaf`. |
| **leaf** (репо) | Публичный репо приложения, `gundemtech/leaf` |
| **leaf-docs** (репо) | Публичный репо whitepaper, `gundemtech/leaf-docs`. Сайт: `leaf-docs.gundem.tech` |
| **leaf-relay** (репо) | Приватный репо Cloudflare Worker (TypeScript, presence-relay). Live на `oauth.gundem.tech` (`/v1/invite/*` + `/v1/key-rotation/*`). |
| **Второй мозг** | Whitepaper в `leaf-docs`. Единственный источник правды для продуктовых и архитектурных решений. |
| **Shared memory** | `.claude/shared/*.md` в репо `leaf` — контекст, автоматически читаемый Claude Code у всей команды |
| **Whitepaper** | Публичная документация продукта, MkDocs Material, текущая версия v0.1-beta (team-first re-positioning, 2026-05-08). |
| **Implementation moat** | Детали, которые НЕ публикуем: SQL Derived Insights bodies, точные пороги/числа, crypto byte layouts (HKDF info, nonce gen), Share Controls preset bundle IDs, leaf-relay Worker код. Остаются в приватных модулях / `gundemtech/leaf-relay` (приватный). См. pre-push-leaf checklist в корневом CLAUDE.md. |

---

> Дополняется по мере появления доменных терминов. Домашние термины продукта (persistent memory, team-first, share controls, BYOK, untrusted relay, tier-based summarization и т.д.) — в `leaf-docs/docs/reference/glossary.md`.
