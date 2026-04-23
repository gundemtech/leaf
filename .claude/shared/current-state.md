# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. Обновляется вручную._

## Последнее обновление
2026-04-23

## Где мы
- Инфраструктура команды готова: `leaf-docs` (whitepaper v1.2) + shared memory в LeafControl-репо.
- **Whitepaper v1.2 published** в `leaf-docs.gundem.tech`. Структура: 01-vision / 02-product / 03-architecture / 04-market / 05-reference.
- **Код приложения ещё не начат.** Скелет Xcode.
- **Linear переведён в режим "только таски"**. Второй мозг = whitepaper.

## Ключевые архитектурные решения (актуальный срез)
Все живут в whitepaper `leaf-docs/docs/`. Сжатая выжимка:

- **Two surfaces:** Native UI primary standalone; MCP — bonus channel для AI-клиентов.
- **Opt-in transparency + Share Controls:** whitelist model per-app + per-event-type, default empty, preset в onboarding.
- **Private self + Symmetric visibility:** raw on-device (SQLCipher), admin = обычный team-member + billing.
- **Granularity L1-L5**, L6 content запрещено всегда.
- **Layer A:** NSWorkspace / CGEventSource / EventKit / Focus / AX / FSEvents / git polling / Claude Code hooks. Без AppleScript и без post-commit hooks в MVP.
- **Layer B MVP = Linear** (OAuth PKCE).
- **Presence Relay:** Cloudflare DO + WebSocket + AES-GCM-256 + ECDH invite/rotation + Share Controls filter до encryption.
- **Storage:** GRDB 7 fork + SQLCipher, 14 таблиц, multi-process WAL.
- **Derived Insights Engine:** 12 функций, Swift + SQL, zero LLM в MVP.
- **Distribution:** Sparkle 2 + EdDSA + Cloudflare R2 + notarytool.

## В работе прямо сейчас
- Настройка правил публикации в публичный app-репо `gundemtech/leaf` (фильтр implementation moat).
- **MVP ship target: 18 недель** (один инженер).

## Следующим (top 3)
- Первые строки кода: `LeafControlCore` package (GRDB+SQLCipher, schema migrations, Derived Insights Engine skeleton, Share Controls filter).
- Дизайн presence-enum + формат L1-L5 в Native UI.
- Дизайн onboarding (6 экранов), финализация "common dev defaults" preset apps list.

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
