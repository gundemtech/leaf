# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. Обновляется вручную._

## Последнее обновление
2026-04-24 (Phase 1.1 storage foundation)

## Где мы
- Инфраструктура команды готова: `leaf-docs` (whitepaper v1.2) + shared memory в LeafControl-репо.
- **Whitepaper v1.2 published** в `leaf-docs.gundem.tech`. Структура: 01-vision / 02-product / 03-architecture / 04-market / 05-reference.
- **Phase 0 done 2026-04-23.** 3-target Xcode project (app + Agent CLI + MCP CLI), local SPM `LeafControlCore` с public API-каркасом (enums, protocols, unimplemented stubs) + moat-target `LeafControlCorePrivate` с tracked Placeholder. Все 3 таргета собираются, helper-бинари embed'нуты в `LeafControl.app/Contents/MacOS/`, CI workflow написан.
- **Phase 1.1 done 2026-04-24.** Storage foundation: GRDB 7.10 (plain SQLite, SQLCipher → Phase 1.5), `Database` класс с writer/reader режимами через `DatabasePool`, migration M001 (events table + 2 индекса), `KeychainKeyStore` для 32-byte key (готов к использованию в 1.5), moat-injection pattern (optional `Config/Local.xcconfig` → `#if LEAFCONTROL_PROD`). 20/20 тестов зелёные.
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
- Phase 1.2 (Agent daemon + LaunchAgent): NSWorkspace collector + CGEventSource idle + SMAppService toggle. ~3 дня.

## Следующим (Phase 1.3 → 1.4 → 1.5 → demo)
- Phase 1.3 — Real `timeInApp` (moat SQL) + MenuBar UI с Swift Chart.
- Phase 1.4 — stdio MCP server + `get_timeline` tool + `claude mcp add` integration.
- Phase 1.5 — SQLCipher migration (до любой distribution).

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
