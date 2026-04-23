# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. Обновляется вручную._

## Последнее обновление
2026-04-23 (Phase 0 scaffold commit)

## Где мы
- Инфраструктура команды готова: `leaf-docs` (whitepaper v1.2) + shared memory в LeafControl-репо.
- **Whitepaper v1.2 published** в `leaf-docs.gundem.tech`. Структура: 01-vision / 02-product / 03-architecture / 04-market / 05-reference.
- **Phase 0 done 2026-04-23.** 3-target Xcode project (app + Agent CLI + MCP CLI), local SPM `LeafControlCore` с public API-каркасом (enums, protocols, unimplemented stubs) + moat-target `LeafControlCorePrivate` с tracked Placeholder. Все 3 таргета собираются, helper-бинари embed'нуты в `LeafControl.app/Contents/MacOS/`, CI workflow написан.
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
- Phase 1 (vertical slice): Agent собирает NSWorkspace-события в SQLCipher → MenuBar показывает `timeInApp` → MCP отдаёт `get_timeline`. **~1.5-2 недели.**

## Следующим (top 3)
- GRDB+SQLCipher fork pin (DuckDuckGo vs groue + manual) и schema migration 001 — `events` таблица.
- Agent collector на NSWorkspace + CGEventSource idle + LaunchAgent через SMAppService.
- MenuBar UI с реальными данными через Derived Insights + stdio MCP server с одним tool.

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
