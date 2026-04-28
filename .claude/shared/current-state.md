# Текущее состояние проекта

_Срез "где мы сейчас" за 30 секунд. История — в whitepaper changelog + `.claude/plans/phase-*.md` + git log._

## Последнее обновление
2026-04-29 — Phase 4.3 done end-to-end (GitHub Device Flow + collector + insights + MCP tool). Real-workspace smoke verified (popover показал `GitHub today: 4 events · gundemtech/leaf` после Connect → 5min poll). Bug-fix patched в moat: authenticated REST events feed возвращает stripped PushEvent payload (без `commits[]` массива) → parser теперь поддерживает оба shape'а.

## Где мы
- **Whitepaper v1.4** published в `leaf-docs.gundem.tech`. Структура `01-vision / 02-product / 03-architecture / 04-market / 05-reference`.
- **Section A done (Phase 0-2, 2026-04-23 → 2026-04-26).** Foundation: 3-target Xcode project (Leaf app + LeafAgent + LeafMCP), `LeafCore`/`LeafCorePrivate` SPM split, encrypted storage (GRDB 7 fork + SQLCipher AES-256, file-based key store), Agent daemon + 4 MVP collectors, Derived Insights Engine, MenuBarApp Native UI, stdio MCP server, maintenance scheduler. 135 SPM tests. Tactical: `.claude/plans/phase-2*.md`.
- **Section B done (Phase 3.0-3.5, 2026-04-27 → 2026-04-28).** Distribution: Apple Developer ID + notarytool + Sparkle 2 + R2/CF + EdDSA-signed appcast. Shipped **1.0.0-alpha.5**. Tactical: `.claude/plans/phase-3*.md`.
- **Phase 4.1+4.2 done (Linear OAuth + collector + insights, 2026-04-28).** PKCE loopback, `LinearCollector` 5min polling, `DerivedInsights.linearActivity`, MCP tool `get_linear_activity`, `.reconnectNeeded` UI. `ProdLinearGraphQLProvider` — moat stub. 161 SPM tests. Tactical: `.claude/plans/phase-4-{1,2}.md`. **Pending**: real prod GraphQL query, sync-docs.
- **Phase 4.3 done (GitHub Device Flow + collector + insights, 2026-04-29).** OAuth Device Flow (RFC 8628, no PKCE — OAuth Apps не поддерживают), `GitHubCollector` 5min polling REST `/users/<login>/events`, `ProdGitHubAPIProvider` (moat) с PushEvent/PR/Issue/Review mapping + ADR-010 enforcement. 6-й MCP tool `get_github_activity`. 169 SPM tests, build green Debug+Release × 3 targets. **Real-workspace smoke verified**: после Connect → 5min poll → popover показал `GitHub today: 4 events · gundemtech/leaf`. Schema gotcha обнаружен и пропатчен в moat: authenticated REST events feed для `/users/<X>/events` возвращает **stripped** PushEvent payload (без `commits[]` массива — только `before/head/push_id/ref/repository_id`), public feed и webhook payload — full с `commits[]`. Парсер теперь поддерживает оба shape'а — full → N snapshots по N коммитам с subject (ADR-010 first line), stripped → 1 snapshot c `sha=head`, `title=""` (commit message в feed недоступен — ADR-010 trivially enforced). Tactical: `.claude/plans/phase-4-3.md`.
- **Linear** = только таски. Второй мозг = whitepaper.

## Архитектура
Полная картина — `.claude/shared/architecture.md` + whitepaper `leaf-docs/docs/03-architecture/`. TL;DR: two surfaces (Native UI primary + MCP bonus), opt-in transparency + Share Controls, granularity L1-L5, Layer A (NSWorkspace/CGEventSource/EventKit/Focus/AX/FSEvents/Claude Code hooks), Layer B MVP = Linear+GitHub, presence relay через Cloudflare DO + AES-GCM, 14 SQLCipher tables, zero LLM в MVP, Sparkle 2 + EdDSA + R2 distribution.

## Следующим
- **Phase 4.3 follow-ups (low priority):** (a) regression test в `GitHubAPIProviderTests` под stripped PushEvent shape (фиксирующий что 1 snapshot per push без commits[] handled); (b) расширить `mapPullRequestEvent`/`mapIssuesEvent`/`mapReviewEvent` под потенциальный stripped shape (мы не verified — все 4 PR events в feed были старше cursor); (c) опционально fetch `/repos/<owner>/<repo>/commits/<head>` per stripped PushEvent для recovery commit subject — extra API call, на v1.1.
- **Phase 4.2/4.3 prod providers**: заполнить `ProdLinearGraphQLProvider` (currently no-op, нужна paginated query + retry + complexity budget). `ProdGitHubAPIProvider` уже реальный — single-page MVP, без pagination follow / ETag (v1.1).
- **Phase 4.2/4.3 prod providers**: заполнить `ProdLinearGraphQLProvider` (currently no-op, нужна paginated query + retry + complexity budget). `ProdGitHubAPIProvider` уже реальный — single-page MVP, без pagination follow / ETag (v1.1).
- **Phase 4.4**: Slack OAuth + collector pattern уже отлажен на Linear+GitHub.
- **Real Sparkle E2E (alpha.5 → alpha.6)** — следующий ship cycle закроет verify "alpha-юзер кликает Check for Updates → Install → relaunch → bridge migration".
- **Phase 3.5+ cleanup**: delete `KeychainKeyStore.swift` + tests + `LeafError.keychainUnavailable` после ~2 недель stable runtime у alpha-юзеров.

## Open tensions
Живут в `leaf-docs/docs/05-reference/open-tensions.md`. Топ-2:
- **OT-1** distributed deletion локальной forever-history у ex-teammates.
- **OT-2** storage compression для forever retention.
