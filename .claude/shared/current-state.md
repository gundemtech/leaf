# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. Обновляется вручную._

## Последнее обновление
2026-04-24 (Phase 1.4 stdio MCP server + `get_timeline` tool)

## Где мы
- Инфраструктура команды готова: `leaf-docs` (whitepaper v1.2) + shared memory в LeafControl-репо.
- **Whitepaper v1.2 published** в `leaf-docs.gundem.tech`. Структура: 01-vision / 02-product / 03-architecture / 04-market / 05-reference.
- **Phase 0 done 2026-04-23.** 3-target Xcode project (app + Agent CLI + MCP CLI), local SPM `LeafControlCore` с public API-каркасом (enums, protocols, unimplemented stubs) + moat-target `LeafControlCorePrivate` с tracked Placeholder. Все 3 таргета собираются, helper-бинари embed'нуты в `LeafControl.app/Contents/MacOS/`, CI workflow написан.
- **Phase 1.1 done 2026-04-24.** Storage foundation: GRDB 7.10 (plain SQLite, SQLCipher → Phase 1.5), `Database` класс с writer/reader режимами через `DatabasePool`, migration M001 (events table + 2 индекса), `KeychainKeyStore` для 32-byte key (готов к использованию в 1.5), moat-injection pattern (optional `Config/Local.xcconfig` → `#if LEAFCONTROL_PROD`). 20/20 тестов зелёные.
- **Phase 1.2 done 2026-04-24.** Agent daemon: `@main enum AgentMain` с `RunLoop.main.run()`, `ActiveAppCollector` на `NSWorkspace.didActivateApplicationNotification`, `IdleCollector` на `CGEventSource.secondsSinceLastEventType`, `EventWriter` actor с batching + periodic flush, graceful shutdown на SIGTERM/SIGINT через `DispatchSource`, hardcoded Phase-1 blocklist. LaunchAgent plist embedded в `LeafControl.app/Contents/Library/LaunchAgents/` через Copy Files phase. App: `@Observable LaunchAgentService` обёртка над `SMAppService.agent(plistName:)`, Settings с real toggle + status indicator.
- **Phase 1.3 done 2026-04-24.** Первая визуальная метрика: `timeInApp` реализован в moat (`ProdInsights` с LEAD-window SQL + Swift tail-bonus), остальные 11 Insights методов throw `.notImplemented`. Factory перешёл с `#if LEAFCONTROL_PROD` на runtime DI (регистрация провайдера в `LeafControlApp.init()`) т.к. Xcode не прокидывает compilation conditions в SPM dependencies. MenuBarExtra style сменён на `.window`, popover показывает Today header + top-5 apps + SwiftUI Charts bar chart + warning banner когда Agent off. `InsightsReader @MainActor @Observable` с state machine (notConfigured/loading/loaded/empty/error), cancellation previous task при новом refresh, file-exists precheck. `AppNameResolver` (3-tier lookup + cache), `formatDuration`, `Database.readSQL` как public moat bridge. Новый test target `LeafControlCorePrivateTests` с Placeholder + gitignore pattern для dev-only тестов. 32/32 тестов в dev (вкл. 5 ProdInsightsTests), 27/27 public simulation.
- **Phase 1.4 done 2026-04-24.** stdio MCP server: JSON-RPC 2.0 поверх newline-delimited stdio (protocolVersion `2025-11-25`). Pure protocol layer в новом SPM target `LeafControlMCPProtocol` (15 unit-тестов: JSONRPC round-trip, MCP types, Dispatcher, Initialize/ToolsList/ToolsCall handlers). Binary в Xcode target `LeafControlMCP/`: `enum MCPLog` с `nonisolated static` методами (stderr writes, не unified log — Claude Code MCP debug pipe ожидает stderr), `actor StdioTransport` на `FileHandle.standardInput.bytes.lines`, `@main enum MCPMain` с `async main()`. Shutdown через stdin EOF (нет signal handlers — в async main без `RunLoop.main.run()` DispatchSource на `.main` ненадёжен). Tool `get_timeline(period: today|yesterday|last_7_days)` → `DerivedInsightsFactory.make(database:).timeInApp(period:)` через тот же runtime DI что у MenuBar. `claude mcp add --transport stdio leafcontrol -- ...` → `✓ Connected`; Claude Code на "что я делал сегодня?" получает JSON с реальным top-apps. 47/47 тестов зелёные (32 existing + 15 MCP).
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
- Demo-видео ≤ 2 мин — acceptance criterion Phase 1. Menu-bar popover + Claude Code "что я делал сегодня?".

## Следующим (Phase 1.5 → distribution)
- Phase 1.5 — SQLCipher migration (блокер до любой distribution).
- Phase 2 — остальные Insights функции + дополнительные MCP tools.

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
