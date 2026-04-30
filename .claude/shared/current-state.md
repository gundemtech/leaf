# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. История — в whitepaper changelog + `.claude/plans/phase-*.md` + git log._

## Последнее обновление
2026-04-30 — **alpha.7 SHIPPED.** Bundled Phase 4.6 (A+B+C) + AppIcon set (visible в Finder/Dock/DMG) + DMG drag-to-Applications layout (стандартный install gesture). `notarytool Accepted` + stapled, R2 + CF cache purged, appcast 3 items (alpha.5 / alpha.6 / alpha.7), 3 deltas (`Leaf7-6` legacy 1.8MB + `Leaf8-7` 3MB + `Leaf8-6` 3.4MB). Live: `https://updates.gundem.tech/appcast.xml`. **Ship pipeline fixes (`gundemtech/leaf:main`):** (1) `81b001b` AppIcon assets (16/32/128/256/512 @1x+@2x); (2) `42c50f8` DMG layout `--window-size 540 380 --icon-size 128 --icon Leaf.app 140 190 --app-drop-link 400 190`; (3) `fa2f72a` `MARKETING_VERSION` 6→7; (4) `0283ef2` **`CURRENT_PROJECT_VERSION` 7→8 (fixed regression)** — alpha.6 ship забыл bump build number, что сломало бы Sparkle update detection alpha.6→alpha.7 (Sparkle compares `CFBundleVersion`, not short string); (5) `7593005` `step_appcast` теперь hide ALL `*.dmg` (не только current) — prior-version DMGs остающиеся в `build/releases/` дублировали `CFBundleVersion` со своими `.zip`. Pre-existing **Phase 4.6.B done E2E (Linear status transitions)** в коммитах `e5f4f82` + `3235b3a`. Tactical: `.claude/plans/phase-4-6-B.md`.

## Где мы
- **Whitepaper v1.4** published в `leaf-docs.gundem.tech`. Структура `01-vision / 02-product / 03-architecture / 04-market / 05-reference`.
- **Section A done (Phase 0-2, 2026-04-23 → 2026-04-26).** Foundation: 3-target Xcode project, `LeafCore`/`LeafCorePrivate` SPM split, encrypted storage (GRDB 7 fork + SQLCipher AES-256), Agent daemon + 4 MVP collectors, Derived Insights Engine, MenuBarApp Native UI, stdio MCP server. Tactical: `.claude/plans/phase-2*.md`.
- **Section B done (Phase 3.0-3.5, 2026-04-27 → 2026-04-28).** Distribution: Apple Developer ID + notarytool + Sparkle 2 + R2/CF + EdDSA-signed appcast. Shipped **1.0.0-alpha.5** → **alpha.6** (2026-04-29) → **alpha.7** (2026-04-30, bundled Phase 4.6). Tactical: `.claude/plans/phase-3*.md`.
- **Layer B MVP closed (Phase 4.1-4.5, 2026-04-28 → 2026-04-29).** Linear (PKCE loopback fixed-port + GraphQL per-action attribution через `activity.user.isMe` + `creator.isMe` backstop), GitHub (Device Flow RFC 8628, REST `/users/<X>/events` polling), Slack (PKCE distributed-app через HTTPS relay `oauth.gundem.tech/<provider>/callback` Cloudflare Worker — bouncer на loopback). 7 MCP tools, popover lines per provider. Tactical: `.claude/plans/phase-4-{1,2,3,4,5}.md`.
- **Phase 4.6 done E2E (Layer B Depth, 2026-04-30, alpha.7 ready).** Layer B перешёл из "что произошло + сколько раз" → "что произошло + насколько долго + какой темп". **A** latency depth (GitHub PR cycle + review delay; Linear completion duration; Slack reactions count + huddle session distribution — all через generic `LatencyStats` aggregation). **B** Linear status transitions (новый `linear_status_transition` event flavor через nested history fragment + client-side actor filter). **C** synthesis (surface existing `weekOverWeekDelta` + новая `longestUninterruptedWindow` 8-й MCP tool + per-provider streaks 60-day lookback). **8 MCP tools** total. **321 SPM tests**, 6 xcodebuild green. Tactical: `.claude/plans/phase-4-6{,-A-3,-B,-C-1,-C-2,-C-3}.md`.
- **Linear** = только таски. Второй мозг = whitepaper.

## Архитектура
Полная картина — `.claude/shared/architecture.md` + whitepaper `leaf-docs/docs/03-architecture/`. TL;DR: two surfaces (Native UI primary + MCP bonus), opt-in transparency + Share Controls, granularity L1-L5, Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks), Layer B MVP = Linear+GitHub+Slack (+ Phase 4.6 latency/transitions/synthesis depth), presence relay через Cloudflare DO + AES-GCM, 14 SQLCipher tables, zero LLM в MVP, Sparkle 2 + EdDSA + R2 distribution.

## Следующим
- **Phase 5 (presence relay)** — отдельный alpha.8 ship cycle. Cloudflare Durable Objects + WebSocket Hibernation, AES-GCM envelope, X25519 ECDH invite, key rotation на removal.
- **Layer C (V1.5+)**: MCP-aggregator поверх Notion / Figma / Jira / Gmail / Calendar.
- **Phase 3.5+ cleanup**: delete `KeychainKeyStore.swift` + `LeafError.keychainUnavailable` после ~2 недель stable runtime alpha.6 (target ~2026-05-13).
- **leaf-relay репо housekeeping**: README + CI deploy hook (Wrangler) + документация по `oauth.gundem.tech/<provider>/callback` routing для будущих v1.1+ providers (Notion / Figma).
- **Release tooling improvements** (после alpha.7 lessons): (a) `release.sh` должен auto-bump `CURRENT_PROJECT_VERSION` (или хотя бы fail-fast если build number == prior-version) — alpha.6 ship забыл bump, обнаружили только при alpha.7; (b) `upload-release.sh` whitelist не включает `*.html` release notes — добавить когда понадобится.
- **Sparkle ship gotchas**: (a) Xcode Debug LeafAgent залипает в launchd registration → SMAppService.register() в shipped Leaf.app filter "already registered" — `pkill -f "DerivedData.*LeafAgent"` pre-ship; (b) macOS TCC AX permission иногда требует toggle off+on после Sparkle bundle replace (CDHash меняется); (c) **CFBundleVersion должен быть monotonically increasing per ship** — Sparkle update detection ломается без bump'а.

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
