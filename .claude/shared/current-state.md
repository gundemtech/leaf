# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. История — в whitepaper changelog + `.claude/plans/phase-*.md` + git log._

## Последнее обновление

**2026-05-07 — Phase 5.5.A foundation landed на `feature/phase-5-5-A-foundation`** (off `main`, alpha.11 baseline). Substrate-only sub-phase открывает 5.5 stack: `JoinCode` value type (base32-Crockford 76-char wire + CRC32-low-20 checksum + lenient legacy hex fallback per D10) в `Crypto/JoinCode.swift`, `InviteURL` value type (`leaf://invite/<token>#<otp>` strict parse/compose) в new `URLScheme/InviteURL.swift`, M010 `pending_invites` table + `PendingInvitesStore` static-method CRUD (mirror `PresenceStateWriter` pattern), `PendingInviteStatus` enum (5 cases lowercase TEXT contract), 3 new `LeafError` cases (`joinCodeMalformed`, `joinCodeChecksumMismatch`, `inviteURLMalformed`). 29 new tests (970 total SPM pass). 5/5 xcodebuild schemes green. **Не merged в main** — stack под 5.5.B (UX rewrites: deep-link handler, three-way `.team` onboarding, AcceptInviteSheet/GenerateInviteSheet rewrites). Tactical: `.claude/plans/phase-5-5-A.md`. Subagent-driven flow: 7 implementer + spec-review + quality-review циклов на task; 1 nit fix (test fixture-dependency scoping).

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
- **Phase 5.5.A foundation closed (2026-05-07).** Branch `feature/phase-5-5-A-foundation` off main. M010 `pending_invites` + `JoinCode`/`InviteURL` value types + `PendingInvitesStore` CRUD + `PendingInviteStatus`. 970 SPM tests. Awaiting Stage 6 final review + push; merge as part of 5.5 stack (5.5.A→C).
- **Linear** = только таски. Второй мозг = whitepaper.

## Архитектура

Полная картина — `.claude/shared/architecture.md` + whitepaper `leaf-docs/docs/03-architecture/`. TL;DR: two surfaces (Native UI primary + MCP bonus), opt-in transparency + Share Controls, granularity L1-L5, Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks), Layer B MVP = Linear+GitHub+Slack, presence relay через Cloudflare DO + AES-GCM, 21 SQLCipher tables (12 base + presence_state M005 + org/team_members/team_keys M006-M008 + rotation_outbox M009 + pending_invites M010), zero LLM в MVP, Sparkle 2 + EdDSA + R2 distribution. **12 MCP tools** total.

## Следующим

- **Phase 5.5.B** (отдельная сессия) — Onboarding `.team` three-way restructure + deep-link handler (Info.plist `CFBundleURLTypes` + `NSAppleEventManager`) + clipboard auto-detect on app foreground + `AcceptInviteSheet`/`GenerateInviteSheet` rewrites + `ShareTemplateButton` (Mail/Messages/Copy templates) + `InviteService`/`InviteAcceptService` JoinCode parse path. Stacks on 5.5.A.
- **Phase 5.5.C** (отдельная сессия) — `PendingInvitesReader` Observable + manual [Refresh] + `PendingInvitesSection` в TeamView + `PendingInviteRow` (Re-share / Revoke). Stacks on 5.5.B.
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
