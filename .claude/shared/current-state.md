# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. История — в whitepaper changelog + `.claude/plans/phase-*.md` + git log._

## Последнее обновление
2026-05-01 — **Native UI redesign committed** (`74386a2`). Не shipped юзерам (требует alpha.8). Split на две поверхности: **popover** минимальный (`FOCUS TODAY` + total + top-3 apps + Open/Quit, 280pt, 189 LOC vs прежних 580); **main window** через `Window("Leaf", id: "main")` — primary surface c sidebar 6 секций (Home / Team / Connections / Organization / Settings / Profile). Открывается дабл-кликом из /Applications, Cmd+, (deep-link в Settings), Open кнопкой в popover. **LSUIElement → false** (dual-presence: Dock + menubar). **Theme** — adaptive cream/olive (Light) + deep ink/olive (Dark) через 7 BrandX Color Sets с Light + Dark + High Contrast. AccentColor → BrandOlive. Типографика — system serif (New York) для headlines, SF Mono для UPPERCASE-меток, SF Pro для body. **Liquid Glass** через `.leafGlass` shim — `.glassEffect` на macOS 26+, `.ultraThinMaterial` fallback macOS 14/15 (deployment target 14.0 не бампим). LeafCore / Agent / MCPServer / OAuth / SQLCipher / Sparkle pipeline не тронуты — pure UI refactor. Whitepaper synced (`leaf-docs:ab73328`, mvp-scope.md + changelog v1.10). Tactical: `.claude/plans/floofy-doodling-dusk.md`. **2026-04-30 — alpha.7 SHIPPED** ранее (Phase 4.6 A+B+C + AppIcon + DMG drag-to-Applications). Live: `https://updates.gundem.tech/appcast.xml`.

## Где мы
- **Whitepaper v1.10** published в `leaf-docs.gundem.tech`. Структура `01-vision / 02-product / 03-architecture / 04-market / 05-reference`.
- **Section A done (Phase 0-2, 2026-04-23 → 2026-04-26).** Foundation: 3-target Xcode project, `LeafCore`/`LeafCorePrivate` SPM split, encrypted storage (GRDB 7 fork + SQLCipher AES-256), Agent daemon + 4 MVP collectors, Derived Insights Engine, MenuBarApp Native UI, stdio MCP server. Tactical: `.claude/plans/phase-2*.md`.
- **Section B done (Phase 3.0-3.5, 2026-04-27 → 2026-04-28).** Distribution: Apple Developer ID + notarytool + Sparkle 2 + R2/CF + EdDSA-signed appcast. Shipped **1.0.0-alpha.5** → **alpha.6** (2026-04-29) → **alpha.7** (2026-04-30, bundled Phase 4.6). Tactical: `.claude/plans/phase-3*.md`.
- **Layer B MVP closed (Phase 4.1-4.5, 2026-04-28 → 2026-04-29).** Linear (PKCE loopback fixed-port + GraphQL per-action attribution через `activity.user.isMe` + `creator.isMe` backstop), GitHub (Device Flow RFC 8628, REST `/users/<X>/events` polling), Slack (PKCE distributed-app через HTTPS relay `oauth.gundem.tech/<provider>/callback` Cloudflare Worker — bouncer на loopback). 7 MCP tools, popover lines per provider. Tactical: `.claude/plans/phase-4-{1,2,3,4,5}.md`.
- **Phase 4.6 done E2E (Layer B Depth, 2026-04-30, alpha.7 ready).** Layer B перешёл из "что произошло + сколько раз" → "что произошло + насколько долго + какой темп". **A** latency depth (GitHub PR cycle + review delay; Linear completion duration; Slack reactions count + huddle session distribution — all через generic `LatencyStats` aggregation). **B** Linear status transitions (новый `linear_status_transition` event flavor через nested history fragment + client-side actor filter). **C** synthesis (surface existing `weekOverWeekDelta` + новая `longestUninterruptedWindow` 8-й MCP tool + per-provider streaks 60-day lookback). **8 MCP tools** total. **321 SPM tests**, 6 xcodebuild green. Tactical: `.claude/plans/phase-4-6{,-A-3,-B,-C-1,-C-2,-C-3}.md`.
- **Linear** = только таски. Второй мозг = whitepaper.

## Архитектура
Полная картина — `.claude/shared/architecture.md` + whitepaper `leaf-docs/docs/03-architecture/`. TL;DR: two surfaces (Native UI primary + MCP bonus), opt-in transparency + Share Controls, granularity L1-L5, Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks), Layer B MVP = Linear+GitHub+Slack (+ Phase 4.6 latency/transitions/synthesis depth), presence relay через Cloudflare DO + AES-GCM, 14 SQLCipher tables, zero LLM в MVP, Sparkle 2 + EdDSA + R2 distribution.

## Следующим
- **alpha.8 ship cycle** — UI redesign (`74386a2`) + bump `MARKETING_VERSION` 7→8 + `CURRENT_PROJECT_VERSION` 8→9 + release.sh + appcast. Phase 5 (presence relay) идёт отдельным циклом.
- **Phase 5 (presence relay)** — Cloudflare Durable Objects + WebSocket Hibernation, AES-GCM envelope, X25519 ECDH invite, key rotation на removal.
- **Layer C (V1.5+)**: MCP-aggregator поверх Notion / Figma / Jira / Gmail / Calendar.
- **Phase 3.5+ cleanup**: delete `KeychainKeyStore.swift` + `LeafError.keychainUnavailable` после ~2 недель stable runtime alpha.6 (target ~2026-05-13).
- **leaf-relay репо housekeeping**: README + CI deploy hook (Wrangler) + документация по `oauth.gundem.tech/<provider>/callback` routing для будущих v1.1+ providers (Notion / Figma).
- **Release tooling improvements** (после alpha.7 lessons): (a) `release.sh` должен auto-bump `CURRENT_PROJECT_VERSION` (или хотя бы fail-fast если build number == prior-version) — alpha.6 ship забыл bump, обнаружили только при alpha.7; (b) `upload-release.sh` whitelist не включает `*.html` release notes — добавить когда понадобится.
- **Sparkle ship gotchas**: (a) Xcode Debug LeafAgent залипает в launchd registration → SMAppService.register() в shipped Leaf.app filter "already registered" — `pkill -f "DerivedData.*LeafAgent"` pre-ship; (b) macOS TCC AX permission иногда требует toggle off+on после Sparkle bundle replace (CDHash меняется); (c) **CFBundleVersion должен быть monotonically increasing per ship** — Sparkle update detection ломается без bump'а; (d) **dev-only**: переключение между `/Applications/Leaf.app` (alpha) и `DerivedData/.../Leaf.app` (Debug) сбрасывает BTM parent disposition в `disabled` — агент `spawn failed exit 78` пока юзер не toggle'нёт Login Items → "Allow in the Background" → Leaf ON. Production update path (Sparkle in-place replace) не страдает.

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
