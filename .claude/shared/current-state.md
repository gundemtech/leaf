# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. Детали — git log + `docs/superpowers/specs/` + `.claude/plans/`. История — whitepaper changelog._

## Последнее обновление

**🏁 AI Coworker трек ЗАКРЫТ — P5 Verifiable (v1.5) landed (2026-06-06, #35 `53c7d9d0`, moat `d661d0c`).** Client-side attestation seam + рабочий PoC-verifier: opt-in `InferencePath.attested` (open-weight, verify-before-send, fail-closed, assurance `.poc`); Claude-пути остаются default trust-based (frontier+attestable сегодня не совмещаются). Verify-core публичен+тестируем (freshness+signature-vs-injected-root+constant-time-measurement+TLS-SPKI-binding); pins/endpoint/`AttestedSummarizer`/transport — moat (placeholder, fail-closed до Tinfoil-аккаунта). Honest-claim: НЕ маркетим «verifiable» пока `.poc`. Audit-DB/MCP-tool/M033 + real-Tinfoil-формат/VCEK+Rekor → deferred прод-вайринг. **`.attested` built+tested+injectable, НЕ runtime-wired** (зеркалит AI-included).

**Гигиена (Ph C, 2026-06-02) держится:** трунк объединён, enforced:
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
- **AI Coworker P0–P5 — ВСЕ ЗАКРЫТЫ (трек завершён 2026-06-06).** Граница §8.1 (`LLMPolicy.makeContext`/`makeEscalation` + opaque `PromptSafeContext`/`EscalatedBodies`, fail-closed) + `Summarizer`/`ModelGate`/`InferencePath` seam (P0/P0b). Live consumers: MCP `ask_about_my_work` (P1, BYOK-only), synthesis-кластеры (P2), `escalate_to_ai`+`get_ai_escalation_log` (P3, первый bodies-путь, audit-first, M031, prompt-injection §8 п.3), team-handoff «Draft with AI»+`get_handoff_log` (P4, M032, первая in-app AI-поверхность). P5: attested-путь (см. «Последнее обновление»). **Pending two-Mac signed-build smoke** (TCC/Keychain/APNs). Канон+все follow-ups — `.claude/plans/2026-05-31-ai-coworker-track.md` (§13.11).

## Архитектура

Полная — `architecture.md` + whitepaper `memory-architecture/`. TL;DR: MCP primary + Native macOS app + E2E team relay (Cloudflare DO → Supabase миграция отдельным треком). Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks/AppleScript/intensity/browser/GoogleCalendar) + Layer B (Linear/GitHub/Slack), L1–L5 granularity, Share Controls (default OFF), **SQLCipher M001–M032**, zero-LLM substrate, Sparkle 2 + EdDSA + R2. **20 MCP tools** (+`ask_about_my_work`/`escalate_to_ai`/`get_ai_escalation_log`/`get_handoff_log`), **189 ShareEventTypeKey**, multi-workspace per device, tier-gate (`tier` default `"team"` MVP). AI Coworker = первая in-app AI-поверхность (P4): `HandoffDrafter`/`HandoffDraftReader`. P5: opt-in `InferencePath.attested` (verifiable open-weight, off-by-default, не runtime-wired) — public verify-core + moat pins.

## Следующим

- **Tracks 1–5 + integration-T10 acceptance gate** (two-Mac signed-build smoke) → whitepaper sync + VPS deploy (Supabase Edge Functions + migrations — см. specs/plans).
- **Track-7/9 detail-UI + GoogleCalendar-UI re-apply** на unified trunk — отдельный post-Ph-C трек. Источник: теги `dev-track7-source` + `archive/code-style-phase-2-3-C` (Track-7 P1–P5 detail screens).
- **leaf-private follow-up**: `SlackD3SmokeInspector.testInspectLiveDB` + 2 stale handshake integration-теста → catch `databaseSchemaFromFuture`/skip + org→workspace API refresh. NB: локальная dev `events.sqlite` может быть pre-unification-несовместима с трунком (migration-guard на ней корректно срабатывает; recovery/wipe — решение владельца машины).
- **Cleanup**: delete `KeychainKeyStore.swift` после stable runtime; leaf-relay README + CI deploy hook.
- **AI Coworker P5 прод-вайринг (deferred)**: Tinfoil-аккаунт + real SEV-SNP/Sigstore parser + реальные pins (measurement/root/endpoint) + VCEK→AMD-chain + Sigstore-Rekor (→ assurance `.full`) + M033 `llm_attestation_audit` + `get_attestation_log` + live routing `.attested` через тулы + EU-residency. До этого `.attested` = built+tested, не live. leaf-relay attested-backend (`/v1/ai/*` → TEE) — в `gundemtech/leaf-relay`.
- **AI Coworker P4 follow-ups**: escalation-в-черновике («копнуть глубже» через P3-путь — нужна in-app escalation-модалка) · header-bell+счётчик (сейчас reuse inbox badge) · in-app Privacy «ИИ-handoffs»-лента (на in-app AI surface) · NL-чат-вход «передай коллеге…» · AI-разворачивание при pickup · period-picker в sheet (сейчас фикс 7д) · dedicated handoff system prompt (moat quality). **whitepaper §6 team-handoff как МОДЕЛЬ — amendment ПОСЛЕ ревью партнёра** (internals/E2E/M032 — НЕ синкаем).
- **AI Coworker P3 follow-ups**: Slack temporal-B deriver (substrate-blocked); in-app escalation-модалка + Privacy-«ИИ получал»-лента; array-body kinds на escalation; detector-excerpt-by-id; per-source forward-deny (§13.3 allowlist).
- **AI-included live-wiring** (P1 deferred): concrete Supabase-backed `AIInferenceAuthTokenProvider` + surface с Supabase-сессией (in-app или MCP-with-own-SupabaseClient) → `prodAIProxySummarizerMoat`. `RelayProxySummarizer` + `ProdModelGate` уже built+tested. + **leaf-relay Worker `/v1/ai/*`** (SigV4→Bedrock + per-team budget + JWT local-verify) — отдельный трек в `gundemtech/leaf-relay`.
- **GitHub commit-subject self-authored** (P1 CR-1 deferred): per-commit author==viewer verification → тогда `self_authored_commit` снова идёт.

## Open tensions

- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
