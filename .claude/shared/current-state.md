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
- **AI Coworker P0–P3 закрыты** (2026-06-05). **P3 Escalation** (#33 `b57134b0`, +moat leaf-private) — первый bodies-путь, рядом с §8.1 не ослабляя её: отдельный opaque `EscalatedBodies` + `LLMPolicy.makeEscalation` (тот же `isNeverToCloud` — bucket-1 бьёт явный выбор; cap; provenance); `AIDetailAnswerer` audit-FIRST → abort-on-fail (тело не уходит незалогированным); **M031** `ai_escalation_audit` append-only (event-id refs + counts + свой вопрос, НЕ тела) + read-back `get_ai_escalation_log`; MCP `escalate_to_ai` (explicit `event_ids` = consent, BYOK-only, brief-writer ADR-019-отступление); prompt-injection §8 п.3 (4-й DATA-сегмент + whitespace-collapse anti-forge + hardened system prompt + no-tools, moat); `PRRefNormalizer` (public) `owner/repo/pull/42→#42` re-enables github_pr + Slack-PR cross-links. Slack temporal-B / in-app modal+Privacy-feed / detector-excerpts → follow-up. **P2 Synthesis** (#32 `c6af2756`, public-only, без миграций/moat) — кластеры 3-4: cross-provider (`linked_linear_id` денормализ. inline на self-authored gh_* + `event_links` JOIN `target_kind='linear_issue'`-only → `cross_link_fact`; github_pr/owner-repo + github_user + `link_confidence` excluded; `from_ref` из safe id, не branch/title) + тренды/латентность (`trend_metrics`/`latency_metrics` via Derived Insights, identity-free magnitudes; source-NAMES не шлём, только count). `repo` fenced. Slack-B + github_pr cross-links → P3/follow-up. **P0** (#29 `71112962`) — LLM egress-граница (fail-closed `LeafCore/Egress/*` + opaque `PromptSafeContext` §8.1) + `Summarizer`/BYOK-Anthropic seam. **P0b** (#30 `96b47df5`, moat `4a7c4ac`) — AI-included seam `ModelGate`/`RelayProxySummarizer`/auth-provider. **P1 Default Q&A** (#31 `8c72e2b9`, moat `bce149e`) — первый live consumer: MCP-tool `ask_about_my_work` (кластеры 1-2). `WorkFactGatherer`→[EgressEvent]→`makeContext`→`AIWorkAnswerer`(ModelGate+Summarizer). `derivedScalarFacts` allowlist + `bodyFields` fence (excerpts/window_title/paths) + synthetic sentinel-suite. `PromptSafeQuestion`+QA-overload, `FileAnthropicKeyStore` (file-based BYOK), `StrictModeReader` (shared suite §4.3), GitHub `authored_by_viewer` (pr/issue/branch only — commits excluded, CR-1). **BYOK-only live**; AI-included built+tested не wired (нет Supabase в MCP). Default = structured-only (excerpts→P3). Без миграций. `just set-byok-key`/`ai-strict-mode`. Канон — `.claude/plans/2026-05-31-ai-coworker-track.md`.

## Архитектура

Полная — `architecture.md` + whitepaper `memory-architecture/`. TL;DR: MCP primary + Native macOS app + E2E team relay (Cloudflare DO → Supabase миграция отдельным треком). Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks/AppleScript/intensity/browser/GoogleCalendar) + Layer B (Linear/GitHub/Slack), L1–L5 granularity, Share Controls (default OFF), **SQLCipher M001–M031**, zero-LLM substrate, Sparkle 2 + EdDSA + R2. **19 MCP tools** (+`ask_about_my_work`/`escalate_to_ai`/`get_ai_escalation_log`), **189 ShareEventTypeKey**, multi-workspace per device, tier-gate (`tier` default `"team"` MVP).

## Следующим

- **Tracks 1–5 + integration-T10 acceptance gate** (two-Mac signed-build smoke) → whitepaper sync + VPS deploy (Supabase Edge Functions + migrations — см. specs/plans).
- **Track-7/9 detail-UI + GoogleCalendar-UI re-apply** на unified trunk — отдельный post-Ph-C трек. Источник: теги `dev-track7-source` + `archive/code-style-phase-2-3-C` (Track-7 P1–P5 detail screens).
- **leaf-private follow-up**: `SlackD3SmokeInspector.testInspectLiveDB` + 2 stale handshake integration-теста → catch `databaseSchemaFromFuture`/skip + org→workspace API refresh. NB: локальная dev `events.sqlite` может быть pre-unification-несовместима с трунком (migration-guard на ней корректно срабатывает; recovery/wipe — решение владельца машины).
- **Cleanup**: delete `KeychainKeyStore.swift` после stable runtime; leaf-relay README + CI deploy hook.
- **AI Coworker P4** (Team handoff §6/§13.6): AI-ген handoff поверх leaf-presence + E2E-транспорт (Phase-5 substrate); переиспользует P1-P3 gatherer+boundary + escalation-модалку для «копнуть глубже»; закрывает §8 п.1/п.4.
- **AI Coworker P3 follow-ups**: Slack temporal-B deriver (substrate-blocked — нет work-channel allowlist); in-app модалка + Privacy-«ИИ получал»-лента (на in-app AI-поверхность); array-body kinds (Slack/Linear comment-массивы) на escalation; detector-excerpt-by-id escalation; per-source forward-deny (нужен §13.3 work-resource allowlist).
- **AI-included live-wiring** (P1 deferred): concrete Supabase-backed `AIInferenceAuthTokenProvider` + surface с Supabase-сессией (in-app или MCP-with-own-SupabaseClient) → `prodAIProxySummarizerMoat`. `RelayProxySummarizer` + `ProdModelGate` уже built+tested. + **leaf-relay Worker `/v1/ai/*`** (SigV4→Bedrock + per-team budget + JWT local-verify) — отдельный трек в `gundemtech/leaf-relay`.
- **GitHub commit-subject self-authored** (P1 CR-1 deferred): per-commit author==viewer verification → тогда `self_authored_commit` снова идёт.

## Open tensions

- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
