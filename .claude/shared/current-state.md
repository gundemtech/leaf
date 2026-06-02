# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. Детали — git log + `docs/superpowers/specs/` + `.claude/plans/`. История — whitepaper changelog._

## Последнее обновление

**Трек «Чистка проекта» ЗАКРЫТ (Ph C, 2026-06-02).** Трунк объединён, гигиена enforced:
- **Один транк `dev`**; `main` = release-теги (сейчас `v1.0.0-alpha.24` @ `c54a6cef`). `git branch -a` = **3 уникальных имени** (`dev`, `main`, `feature/moat-leaf-private-bootstrap`). 13 local + 15 remote merged/folded веток снесены — контент сохранён (в `dev` либо в тегах `dev-track7-source` + `archive/*`).
- **`just preflight`** = phase-done gate (R1): leak-guard + check-tokens + check-migrations + gitleaks + build-all (5 схем, exit-honest) + SPM-тесты.
- **pre-push hook** (`.githooks/pre-push` → leak-guard, `core.hooksPath`; R2) + **gitleaks** (pinned binary + `.gitleaks.toml` allowlist) в CI+preflight (D-C3).
- **check-migrations.sh** (R3, линейность Mxxx). **migration-guard** (R7): несовместимая БД → `DatabaseRecoveryView` (Backup&Reset/Reveal/Quit), Agent `exit(0)`, не «Couldn't load Home».
- Правила гигиены **R1–R8** + phase-close чеклист в `conventions.md`.

## Где мы

- **Whitepaper v0.1-beta** на `leaf-docs.gundem.tech`. Решения — `docs/reference/decisions.md`, OQ — `open-questions.md`.
- **Foundation + Distribution + Layer B** (Linear/GitHub/Slack OAuth+polling), **Phase 4.6/4.7 A–C** (event_kinds + `presence_state` + MCP), **Phase 5.1–5.3/5.5** (E2E team relay: invite/rotation/removal) — shipped, в трунке.
- **Tracks 1–5 + integration-T10 P1–P7** влиты в трунк (integration-канон): T1 capture/FTS/detectors · T2 design tokens · T3 Linear/GitHub/Slack depth · T4 Layer A collectors + intensity · T5 Supabase backend + multi-workspace + magic-link + DM + broadcast + tier-gate · T10 Claude/Xcode/Browser/Zoom/IDE deep. **Ждут two-Mac signed-build acceptance gate** (работа в `dev`, не в отдельных ветках).
- **alpha.24** signed; grant-once daily-driver работает.

## Архитектура

Полная — `architecture.md` + whitepaper `memory-architecture/`. TL;DR: MCP primary + Native macOS app + E2E team relay (Cloudflare DO → Supabase миграция отдельным треком). Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks/AppleScript/intensity/browser/GoogleCalendar) + Layer B (Linear/GitHub/Slack), L1–L5 granularity, Share Controls (default OFF), **SQLCipher M001–M030**, zero-LLM substrate, Sparkle 2 + EdDSA + R2. **16 MCP tools**, **189 ShareEventTypeKey**, multi-workspace per device, tier-gate (`tier` default `"team"` MVP).

## Следующим

- **Tracks 1–5 + integration-T10 acceptance gate** (two-Mac signed-build smoke) → whitepaper sync + VPS deploy (Supabase Edge Functions + migrations — см. specs/plans).
- **Track-7/9 detail-UI + GoogleCalendar-UI re-apply** на unified trunk — отдельный post-Ph-C трек. Источник: теги `dev-track7-source` + `archive/code-style-phase-2-3-C` (Track-7 P1–P5 detail screens).
- **leaf-private follow-up**: `SlackD3SmokeInspector.testInspectLiveDB` + 2 stale handshake integration-теста → catch `databaseSchemaFromFuture`/skip + org→workspace API refresh. NB: локальная dev `events.sqlite` может быть pre-unification-несовместима с трунком (migration-guard на ней корректно срабатывает; recovery/wipe — решение владельца машины).
- **Cleanup**: delete `KeychainKeyStore.swift` после stable runtime; leaf-relay README + CI deploy hook.

## Open tensions

- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
