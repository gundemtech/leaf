# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. История — в whitepaper changelog + `.claude/plans/phase-*.md` + git log._

## Последнее обновление

**2026-05-09 — Phase Track-1 D1 (Capture Extension) landed на `feature/track-1-D1-capture-extension`** (off `feature/track-1-detection-substrate` off `main`, alpha.11 baseline). Track 1 first sub-phase: bodies + attachments + Phase 4.8 PR metadata for Linear / GitHub / Slack collectors; Claude Code hooks audited (no parser gap surfaced — `default: .irrelevant` covers v2.1.133 schema additions). M011 expression index `idx_events_event_kind_ts` (`json_extract(payload_json, '$.event_kind'), ts`) для D3 query path. New payload keys via `Schema.EventPayloadKeys`: `body` / `body_truncated` / `attachments_json` / `comment_bodies_json` / `thread_replies_json` / `messages_json` / `files_count` / `additions` / `deletions` / `requested_reviewers_json` / `mention_count` / `link_count`. `AttachmentMeta` value type (LeafCore public). Moat: `BodyCap` 64KB cap + `SlackBudgets` thread fan-out + `PRBodyParser` regex'ы (LeafCorePrivate). **Architectural workaround:** `BodyCap.apply()` calls inside Prod*APIProviders (LeafCorePrivate); snapshots carry `*Truncated: Bool` to bridge moat boundary (LeafCore cannot import LeafCorePrivate). Linear: GraphQL fragment extended (description / comment.body / attachments title+contentType+metadata). GitHub: full commit message + PR body + comment body + release.assets[] + inline image URL parsing + Phase 4.8 PR metrics direct from REST. Slack: additive extension (no replacement) of SlackChannelMessageCount/SlackFileUploadSummary; new `fetchThreadReplies` (`conversations.replies` Tier 3) с `SlackBudgets.maxThreadsPerTick` cap; per-thread cursor (`slack:thread:<channelID>:<threadTs>`) + 429 graceful degrade с cursor preservation; aggregate-level body_truncated по sentinel detection. RateLimitError type. Bodies on-device only (ADR-010 §6 amendment); RelayBodyLeakageTests asserts bodies НЕ leak в presence_state.state_json. **1055 SPM tests** total (1022 baseline + 33 new) + 5/5 xcodebuild schemes green. **Не merged в main** — стэк Track 1 (D1 → D2 → D3) merges коллективно после D3 ship + acceptance gate. Whitepaper sync deferred до Track 1 ship per контракта §12. Tactical: `docs/superpowers/plans/2026-05-09-track-1-D1-capture-extension.md`, spec: `docs/superpowers/specs/2026-05-09-track-1-D1-capture-extension.md`.

## Где мы

- **Whitepaper v0.1-beta** (team-first re-positioning, 2026-05-08) в `leaf-docs.gundem.tech`. Byterover-style структура: `getting-started / memory-architecture / llm-providers / ai-tool-connectors / activity-connectors / surfaces / team-sharing / privacy-security / cookbook / faqs / reference`. Стратегические решения — `docs/reference/decisions.md`, открытые вопросы — `docs/reference/open-questions.md`.
- **Section A done (Phase 0-2).** Foundation: 3-target Xcode project, `LeafCore`/`LeafCorePrivate` SPM split, GRDB 7 + SQLCipher, Agent + 4 collectors, Derived Insights Engine, Native UI, stdio MCP server.
- **Section B done (Phase 3.0-3.5).** Distribution: Apple Developer ID + notarytool + Sparkle 2 + R2/CF + EdDSA appcast.
- **Layer B MVP closed (Phase 4.1-4.5).** Linear / GitHub / Slack OAuth + polling.
- **Phase 4.6 done.** Latency depth + Linear status transitions + synthesis (week-over-week, longest uninterrupted window, streaks). 8 MCP tools.
- **Phase 4.7 A+B+C SHIPPED в alpha.9 (2026-05-04).** 33 новых event_kind discriminators + `presence_state` M005 + `LinearIDExtractor` cross-provider linking + 4 presence-first MCP tools (12 total) + ModeClassifier types-only skeleton + Native UI redesign. ShareEventTypeKey registry 22 → 43.
- **Phase 4.10.B merged (2026-05-04).** Activity tab session enrichment (window_title + browser_url AX collector + on-device session aggregation + colored category dots + app icons). 652 SPM tests baseline.
- **Phase 5.1 stack CLOSED (2026-05-05).** Schema substrate (M006/M007/M008) + value types + GRDB helpers + `EnvelopeCodec` AES-GCM-256 (`ProdEnvelopeCodec` moat) + `OrgService.createPersonalOrg` + `TeamKeystore` + `OrgReader` + UI + persistence E2E. 714 SPM tests.
- **Phase 5.2 stack CLOSED (2026-05-05).** Invite handshake E2E: `IdentityService` X25519 + `InviteKDF` HKDF-SHA256 + `InviteBlobCodec` AES-GCM-256 + leaf-relay `/v1/invite/*` (live на `oauth.gundem.tech`) + `RelayClient` + `InviteService` admin + `InviteAcceptService` invitee + `AcceptInviteSheet` 2-step UX + Onboarding `.team` step. 802 SPM tests.
- **Phase 5.3 stack SHIPPED в alpha.10 + alpha.11 patch (`NSFullUserName` placeholder fix).** Member removal + key rotation: DB lifecycle mutators (5.3.A) + `RotationBlobCodec` substrate (5.3.B) + leaf-relay `/v1/key-rotation/*` wire (5.3.C, live) + `KeyRotationService` admin + M009 `rotation_outbox` (5.3.D) + `RotationFetchService`/`Scheduler` peer loop + `MemberRemovalReader` UI + `RemovedFromTeamBanner` (5.3.E).
- **Phase 5.5 stack in flight.** 5.5.A (substrate — `JoinCode` + `InviteURL` + M010 `pending_invites` + `PendingInvitesStore`, 971 tests) + 5.5.B (UX surface — deep-link routing + scenePhase clipboard auto-fetch + `.team` three-way + sheet rewrites + JoinCode/URL service overloads, 989 tests) + 5.5.C (admin recall — `PendingInvitesService` orchestrator + 5 Database wrappers + `PendingInvitesReader` Observable + `PendingInvitesSection`/`Row` UI + TeamView wiring, 1007 tests, optimistic D4 revoke). Все три ship'нули в свои feature branches. Стэк ждёт коллективный merge после two-Mac smoke gate.
- **Linear** = только таски. Второй мозг = whitepaper.

## Архитектура

Полная картина — `.claude/shared/architecture.md` + whitepaper `leaf-docs/docs/memory-architecture/`. TL;DR substrate'а: MCP primary surface (Cursor / Claude Code / Claude Desktop) + Native macOS app + Phase 5 E2E team relay. Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks), Layer B MVP = Linear+GitHub+Slack, granularity L1-L5, Share Controls, presence relay через **Cloudflare DO + AES-GCM** (фактически built, whitepaper v0.1-beta планирует миграцию на Supabase + XChaCha20-Poly1305 — substrate готов, миграция отдельным треком), 21 SQLCipher tables (12 base + presence_state M005 + org/team_members/team_keys M006-M008 + rotation_outbox M009 + pending_invites M010), zero-LLM substrate (whitepaper планирует tier-based summarization: on-device Apple FM / BYOK / Leaf Cloud — отдельный track), Sparkle 2 + EdDSA + R2 distribution. **12 MCP tools** total.

## Следующим

- **Phase 5.5 two-Mac smoke gate** — manual end-to-end check 5.5.A+B+C на двух Mac'ах (admin + invitee, full 7-step golden path per decomposition §4.8 + 5.5.C-specific 8-step §5.3) перед коллективным merge стэка в `main`.
- **Phase 5.5.D candidates** (post-smoke, scoped if adoption surfaces gaps): `inviteeDisplayNameHint` capture в GenerateInviteSheet (D7); per-row [Refresh]; "Joined N min ago" ghost row для `.consumed`; bulk Revoke-all-expired / Dismiss-all-terminal; centralize "transient mutation error doesn't blank list" pattern across PendingInvitesReader/InviteOutboxReader/MemberRemovalReader.
- **Phase 5.6** — auto-poll loop через HEAD `/v1/invite/<token>` (requires `gundemtech/leaf-relay` extension); background scheduler.
- **Phase 5.4** (parallel track) — `presence_outgoing` + `presence_history` M011/M012 + WS broadcast loop в Agent + Swift WS client + Team presence grid live UI; first real consumer `ProdEnvelopeCodec` 5.1.C.
- **Phase 4.7 carry-overs** (non-blocking, Linear cleanup для 4.8): hoist GitHubCollector UTC `DateFormatter` to static; split `GitHubAPIProvider.swift` если 4.8 добавит structs; document `fetchEvents` failure short-circuit; tighten `testQueryShapeIncludesAssignedIssuesBlock` slice. Plus 4.7.C: refactor C-8 piggy-back на separate HTTP call если Linear API rejects whole query на legacy workspaces.
- **Phase 4.8 — Deep payload metadata (NOT designed yet).** files_count/+/-lines, requested_reviewers, mention_count/link_count, expression-индекс на `payload.event_kind`.
- **Phase 4.9 — Derived modes (NOT designed yet).** `DefaultModeClassifier` impl поверх 4.7.C skeleton, `mode_history` table, новые MCP tools.
- **Layer C (V1.5+)**: MCP-aggregator поверх Notion / Figma / Jira / Gmail / Calendar.
- **Cleanup**: delete `KeychainKeyStore.swift` + `LeafError.keychainUnavailable` после ~2 недель stable alpha.6 runtime (target ~2026-05-13). leaf-relay README + CI deploy hook.
- **Release tooling improvements** (lessons alpha.7+9): (a) `release.sh` auto-bump `CURRENT_PROJECT_VERSION` или fail-fast если build number == prior; (b) version-aware stamps в `build/releases/.stamps/` (auto-clean или `archive.<version>` имя) — сейчас на новой версии переупаковывает старые артефакты.
- **Sparkle ship gotchas**: (a) Xcode Debug LeafAgent залипает в launchd → `pkill -f "DerivedData.*LeafAgent"` pre-ship; (b) AX permission иногда требует toggle после bundle replace (CDHash меняется); (c) `CFBundleVersion` monotonic per ship — без bump'а Sparkle detection ломается; (d) dev-only: переключение `/Applications/Leaf.app` ↔ DerivedData сбрасывает BTM disposition (production update path не страдает).

## Open tensions

Substrate-level (технические, не в whitepaper):
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.

Стратегические open questions (whitepaper) — `leaf-docs/docs/reference/open-questions.md`.
