# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. История — в whitepaper changelog + `.claude/plans/phase-*.md` + git log._

## Последнее обновление

**2026-05-07 — Phase 5.5.C pending invites list landed на `feature/phase-5-5-C-pending-invites-list`** (stack on `feature/phase-5-5-B-flow-rewrites` off `feature/phase-5-5-A-foundation` off `main`, alpha.11 baseline). Admin recall surface: `PendingInvitesService` orchestrator (LeafCore Team) поверх existing Database + RelayClient — `loadVisible` (sweep expired + filter consumed) / `pollPending` (200 stamps `lastPolledAtMs`, 404 → `.consumed`, transport/5xx counted) / `revokeLocal` sync + `tryRelayDelete` async best-effort split (D4 immediate UI feedback после Stage 6 fix) / `dismiss` (hard DELETE row); `PollOutcome` value type. 5 new `Database` public wrappers (`readAllPendingInvites` exclusion-of-consumed default + `readAllPendingInvitesByStatus` + `deletePendingInvite` + `updatePendingInviteLastPolledAt` + `sweepExpiredPendingInvites`); `PendingInvitesStore.sweepExpired` + `readAllExcludingConsumed` static helpers. `@MainActor @Observable PendingInvitesReader` mirror'ит InviteOutboxReader lazy-init + `#if LEAF_PROD` config injection — surface'ит `loading` / `loaded(rows:)` / `error(message:)` state, `isPolling` flag для inline ProgressView, `pollMessage` для one-shot outcome banner (auto-cleared on next refresh/revoke/dismiss per Stage 6 review #4). UI: `PendingInvitesSection` (hides when empty per D6, header `PENDING INVITES · N` + [↻ Refresh]) + `PendingInviteRow` (status badge accent/leafInk/red + per-status action cluster — [Re-share popover reuses ShareTemplateButton 5.5.B] + [Revoke] на `.pending`; [Dismiss] на `.revoked`/`.expired`/`.failed`; `.consumed` filtered at DB level per D1). TeamView wires reader env + `.onAppear refresh()` (D8 sweep) + section render между membersList и [Add member]. LeafApp Window scene env injection (MenuBarExtra correctly skipped — TeamView Window-only). **1007 SPM tests** total (989 + 18 new). 5/5 xcodebuild schemes green. Stage 6 review: 1 Important + 1 UX-polish + 2 inherited-pattern carry-overs — fixes shipped в `966918a` (split service revoke для optimistic UI + clear pollMessage на mutations). #2/#3 (sync DB on MainActor + error obliterates list) — inherited from InviteOutboxReader/MemberRemovalReader pattern, deferred как stack-wide refactor для 5.5.D. **Не merged в main** — стэк 5.5.{A,B,C} мерджим коллективным решением после two-Mac smoke gate. Tactical: `.claude/plans/phase-5-5-C.md`.

## Где мы

- **Whitepaper v1.10** в `leaf-docs.gundem.tech`. Структура `01-vision / 02-product / 03-architecture / 04-market / 05-reference`.
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

Полная картина — `.claude/shared/architecture.md` + whitepaper `leaf-docs/docs/03-architecture/`. TL;DR: two surfaces (Native UI primary + MCP bonus), opt-in transparency + Share Controls, granularity L1-L5, Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks), Layer B MVP = Linear+GitHub+Slack, presence relay через Cloudflare DO + AES-GCM, 21 SQLCipher tables (12 base + presence_state M005 + org/team_members/team_keys M006-M008 + rotation_outbox M009 + pending_invites M010), zero LLM в MVP, Sparkle 2 + EdDSA + R2 distribution. **12 MCP tools** total.

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

Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
