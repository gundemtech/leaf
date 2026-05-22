# Track-9 T8 — INBOX block full feeder expansion + universal sourceURL synthesis

**Status:** SPEC — pending implementation
**Date:** 2026-05-21
**Phase:** Track-9 eighth phase (UI surface half)
**Branch:** `feature/track-9-substrate` (off T7 SHIPPED tip `aa89eeb7`)
**Master spec:** `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` §3.4 + §T8 (lines 91-119 + 207-213)
**Predecessor:** T7 `2026-05-21-track-9-T7-where-stopped-4line.md` (zero-migration substrate-purity precedent)

---

## 1. Scope

### 1.1 In scope

- Universal `InboxSourceURLDeriver` (typed enum dispatch, public LeafCore)
- `InboxKind` enum expansion: 5 → 14 cases (3 viable new + 6 placeholder)
- `InboxFilter` enum expansion: 4 → 5 chips (add `.alerts` umbrella)
- 3 new viable feeder methods in `ProdInsights+InboxItems` (moat LeafCorePrivate): `queryBuildFailed` / `queryCIFailed` / `queryLiveMeeting`
- 6 placeholder feeder methods (`return []` + TODO comment with substrate phase reference): `queryCalInviteDeclined` / `queryCalUpcoming15min` / `queryCalConflict` / `queryMailUnreadBucket` / `queryReminderDueToday` / `querySlackDM`
- D3 feeders enriched with sourceURL synthesis: `queryOpenQuestionsForMe` + `queryBlockersAffectingMe` read context_ref columns → `InboxSourceURLDeriver.synthesize(...)` → `InboxItem.sourceURL` populated. Closes carry C-16.
- `(kind, sourceURL)` aggregation kernel activation — kernel already present at dispatcher level; T8 lights up real `aggregatedCount` values via viable feeders supplying URLs
- 5th `.alerts` filter chip rendering in `InboxFilterRow`
- Master spec §9.1 status markers update (C-14 / C-15 / C-16)

### 1.2 Out of scope (carry post-Track-9)

- Substrate enrichment for placeholder kinds (cal_invite_declined / cal_upcoming_15min / cal_conflict / mail_unread_bucket / reminder_due_today / slack_dm) — each requires dedicated substrate phase with its own brainstorm/spec/plan
- Per-kind dedicated `InboxFilter` chips beyond `.alerts` — single umbrella sufficient for T8; per-category split when placeholders light up post-Track-9
- `xcode_build_failed` branch context discrimination (main vs dev) — substrate gap, future enrichment
- `gh_check_runs_status` payload extension for branch context — substrate gap
- Search debounce / SQL re-fetch on filter change (C-14) — defer; cardinality stays manageable under 14d cutoff baseline
- `RouteCoordinator.openURL(_:URL)` extraction (C-15) — defer; `NSWorkspace.shared.open(_:)` direct call pattern sufficient for now (centralize when 2+ blocks share)
- New SQLCipher migrations (none — `where_stopped_log` M028 reservation released by T7 already)
- New event_kinds (T2 + T3 already supplied all substrate-side new kinds Track-9 needs)
- New MCP tools (15-tool inventory frozen; `get_inbox` carry post-Track-9 if AI clients request)
- New ShareEventTypeKey registry entries (frozen at 198 post-T3)
- Localization track (C-19) — `severityWord` hardcoded English persists, separate track owns extraction

---

## 2. Scope locks (brainstorm decisions, 2026-05-21)

| # | Decision | Value |
|---|---|---|
| 1 | Scope strategy vs master spec §3.4 | **Option C — Hybrid placeholder.** Substrate-purity invariant preserved (T1-T7 zero-migration streak); placeholder enum cases ship now with `return []` feeders; substrate phases (post-Track-9) light up feeders without enum migration. **Placeholder case names may EXTEND (not replace) when substrate phases land** — e.g., when Calendar invitation-response substrate lands, may add `.calInvitationAccepted` + `.calInvitationTentative` alongside the locked `.calInviteDeclined`; renames discouraged once shipped. |
| 2 | Viable kind mapping + fold strategy | **Option C1 — fold + minimal new.** Fold `slack_mention_received_aggregate` → existing `.mention` (literal mention semantic); fold `slack_thread_reply_aggregate` → existing `.commentOnMyWork` (thread replies on my participation = comments on my work). 3 new distinct kinds: `.buildFailed` / `.ciFailed` / `.liveMeeting`. |
| 3 | InboxFilter expansion | **F1 — umbrella `.alerts` chip.** Single chip admits `.buildFailed` + `.ciFailed` + `.liveMeeting`. Placeholder kinds get no chip (chip implies admittable rows; empty chip = broken UX). Total 5 chips: `.all / .reviews / .questions / .mentions / .alerts`. |
| 4 | InboxSourceURLDeriver API shape | **S1 — typed enum dispatch.** Single `InboxSourceContextRef` enum + `InboxSourceURLDeriver.synthesize(_:) -> URL?`. Compile-time discipline — adding new kind forces enum case + dispatch update. Single sentinel test iterates all cases via switch. |
| 5 | Severity tone defaults for new viable kinds | **SV1 — tiered.** `.ciFailed` = `.danger` (remote CI red blocks merge/deployment, urgent), `.buildFailed` = `.warn` (local build error, recoverable), `.liveMeeting` = `.muted` (informational presence, not actionable). Sort ladder works naturally. |

---

## 3. Master spec contract closure

| Master spec reference | T8 closure |
|---|---|
| §3.4 INBOX pillar — universal `InboxSourceURLDeriver` | ✅ shipped (S1 typed enum dispatch) |
| §3.4 — `InboxKind` enum expansion | ✅ shipped (14 cases — viable + placeholder hybrid per scope lock C) |
| §3.4 — `(kind, sourceURL)` aggregation activation | ✅ shipped (kernel already present; viable feeders supply URLs) |
| §3.4 — D3 sourceURL synthesis | ✅ shipped (C-16 close — `queryOpenQuestionsForMe` + `queryBlockersAffectingMe` enriched) |
| §3.4 — 10 feeder methods | **Adjusted** — 5 viable (3 new + 2 existing route into existing kinds via fold) + 6 placeholder = 11 methods. Master spec letter close enough; Option C placeholder hybrid documented in §2 scope lock #1. |
| §3.4 — `gh_pr_review_requested` event_kind | already shipped by T3 |
| §3.4 — viewer_login + workspace_slug presence | already shipped by T2/T3 |
| §3.4 — Slack DM bucket | **carry post-Track-9** — substrate absent (T3 wrap C-19 carry confirmed) |
| §3.4 — `event_links` (M013) as inbox source | **out-of-scope T8** — master spec §3.4 line 105 notes event_links "exists but not consumed by inbox substrate"; T8 also doesn't consume. D3 detectors write `context_ref` columns directly to detection tables (open_questions/blockers) — T8 reads those, not event_links. Future cross-source linking via event_links → post-Track-9 carry if InboxKind expansion requires. |
| §T8 — 10 feeder methods | see "Adjusted" above |
| §T8 — 10 sentinel-injection tests | **Adjusted** — 1 integration sweep test iterates all `InboxSourceContextRef` cases via S1 switch + 1 write-boundary test. Pattern parity with T3 (4 sentinel tests via integration sweep). Per-case tests redundant under S1 typed enum dispatch. |

Master spec §9.1 status markers post-T8 ship:
- **C-14** search debounce → DEFERRED carry (no substrate change required by T8)
- **C-15** `RouteCoordinator.openURL` extraction → DEFERRED carry (single-callsite pattern persists; centralize when 2+ blocks share)
- **C-16** `InboxItem.sourceURL` nil for D3-derived → **RESOLVED T8** — D3 feeders synthesize URLs via `InboxSourceURLDeriver` from existing context_ref columns

---

## 4. Components

### 4.1 `InboxSourceContextRef` enum

**New file:** `Packages/LeafCore/Sources/LeafCore/Insights/InboxSourceContextRef.swift`

```swift
import Foundation

public enum InboxSourceContextRef: Equatable, Sendable {
    case linearIssue(workspaceSlug: String, key: String)
    case githubPR(owner: String, repo: String, number: Int)
    case githubIssue(owner: String, repo: String, number: Int)
    case githubPRComment(owner: String, repo: String, number: Int, commentID: Int64)
    case githubIssueComment(owner: String, repo: String, number: Int, commentID: Int64)
    case githubNotificationsRoot
    case slackThread(teamID: String, channelID: String, ts: String)
    case slackChannel(teamID: String, channelID: String)
    case calendarEvent(eventID: String)
    case zoomMeeting(meetingID: String)
    case xcodeBuild(projectPath: String?)
    case mailMailbox(accountID: String, mailboxID: String)
    case reminderList(listID: String)
}
```

ADR-010 invariant: associated values are opaque refs only (slug / key / number / opaque ID / sanitized path). No body / title / comment text / email subject / note content reaches the enum cases. Sentinel-injection regression test (§7.3) iterates all cases via switch and asserts padded sentinel never appears in synthesized URL string.

**LOC budget:** ≤60.

### 4.2 `InboxSourceURLDeriver`

**New file:** `Packages/LeafCore/Sources/LeafCore/Insights/InboxSourceURLDeriver.swift`

```swift
import Foundation

public enum InboxSourceURLDeriver {
    public static func synthesize(_ ref: InboxSourceContextRef) -> URL? {
        switch ref {
        case .linearIssue(let slug, let key):
            guard !slug.isEmpty, !key.isEmpty else { return nil }
            return URL(string: "https://linear.app/\(slug)/issue/\(key)")
        case .githubPR(let owner, let repo, let number):
            guard !owner.isEmpty, !repo.isEmpty, number > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")
        case .githubIssue(let owner, let repo, let number):
            guard !owner.isEmpty, !repo.isEmpty, number > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/issues/\(number)")
        case .githubPRComment(let owner, let repo, let number, let commentID):
            guard !owner.isEmpty, !repo.isEmpty, number > 0, commentID > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)#discussion_r\(commentID)")
        case .githubIssueComment(let owner, let repo, let number, let commentID):
            guard !owner.isEmpty, !repo.isEmpty, number > 0, commentID > 0 else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/issues/\(number)#issuecomment-\(commentID)")
        case .githubNotificationsRoot:
            return URL(string: "https://github.com/notifications")
        case .slackThread(let teamID, let channelID, let ts):
            guard !teamID.isEmpty, !channelID.isEmpty, !ts.isEmpty else { return nil }
            return URL(string: "slack://channel?team=\(teamID)&id=\(channelID)&message=\(ts)")
        case .slackChannel(let teamID, let channelID):
            guard !teamID.isEmpty, !channelID.isEmpty else { return nil }
            return URL(string: "slack://channel?team=\(teamID)&id=\(channelID)")
        case .calendarEvent(let eventID):
            guard !eventID.isEmpty else { return nil }
            return URL(string: "ical://\(eventID)")
        case .zoomMeeting(let meetingID):
            guard !meetingID.isEmpty else { return nil }
            return URL(string: "zoommtg://zoom.us/join?confno=\(meetingID)")
        case .xcodeBuild(let projectPath):
            guard let path = projectPath, !path.isEmpty else { return nil }
            return URL(string: "xcode://\(path)")
        case .mailMailbox(let accountID, let mailboxID):
            guard !accountID.isEmpty, !mailboxID.isEmpty else { return nil }
            return URL(string: "message://%3C\(accountID)/\(mailboxID)%3E")
        case .reminderList(let listID):
            guard !listID.isEmpty else { return nil }
            return URL(string: "x-apple-reminderkit://REMCDReminder/\(listID)")
        }
    }
}
```

Pure-function dispatch. Empty/zero refs → nil graceful. No DB access, no async, no actor-bound state. Testable from public LeafCoreTests.

**LOC budget:** ≤120.

### 4.3 `InboxItem.swift` expansion

**Modify:** `Packages/LeafCore/Sources/LeafCore/Insights/InboxItem.swift`

```swift
public enum InboxKind: String, Equatable, Hashable, Sendable, CaseIterable {
    // Existing 5 (preserved order)
    case reviewRequest
    case commentOnMyWork
    case mention
    case openQuestion
    case blocker

    // T8 viable new (3)
    case buildFailed
    case ciFailed
    case liveMeeting

    // T8 placeholder (6) — feeders return [] until substrate phases land
    case calInviteDeclined
    case calUpcoming15min
    case calConflict
    case mailUnreadBucket
    case reminderDueToday
    case slackDM
}

public enum InboxFilter: String, Equatable, Hashable, Sendable, CaseIterable {
    case all
    case reviews
    case questions
    case mentions
    case alerts     // NEW — admits buildFailed + ciFailed + liveMeeting

    public func admits(_ kind: InboxKind) -> Bool {
        switch self {
        case .all: return true
        case .reviews: return kind == .reviewRequest
        case .questions: return kind == .openQuestion
        case .mentions: return kind == .mention
        case .alerts:
            return kind == .buildFailed || kind == .ciFailed || kind == .liveMeeting
        }
    }
}
```

`InboxItem` struct itself unchanged. `InboxSeverity` enum unchanged.

**LOC budget:** ≤120 (current 66).

### 4.4 Viable feeders (moat, gitignored)

**Extend:** `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+InboxItems.swift`

#### 4.4.1 `queryBuildFailed()` — `.warn` severity

- Read semantic (real query body lives in LeafCorePrivate moat): pull `xcode_build_finished` events from the action stream with a failed result inside the cutoff window, ordered newest first.
- Cutoff: `nowMs - 8 * 3600 * 1000` (**8h rationale:** local build errors are fixed in minutes-to-hours; >8h = user gave up or moved on, stale)
- Aggregation: group by `payload_json.project_path` (if present); aggregate row counts per project
- Per-row InboxItem:
  - `kind = .buildFailed`
  - `severity = .warn`
  - `title = "Build failed: \(projectName)"` where `projectName` = basename of `project_path` (substrate-trust, no NSString re-derivation in row producer — Track-9 T7 lineage)
  - `sourceMeta = "Xcode · \(error_count) errors"`
  - `sourceURL = InboxSourceURLDeriver.synthesize(.xcodeBuild(projectPath: payload.project_path))` — may be nil if path absent
  - `aggregatedCount` = per-project count from the aggregation
  - `createdAtMs` = latest event timestamp in the group
- Forbidden: error message text from `payload.errors[].message` — ADR-010 walkback (substrate today doesn't capture per-Track-6 P2 §B `errors[].message` walked at parser boundary)

#### 4.4.2 `queryCIFailed()` — `.danger` severity

- Read semantic (real query body lives in LeafCorePrivate moat): for each `(repo, sha)` pair, keep the latest `gh_check_runs_status` pulse and filter to those whose conclusion indicates a failing state (failure / timed_out / cancelled), restricted to ts >= cutoff.
- Cutoff: `nowMs - 24 * 3600 * 1000` (**24h rationale:** CI runs ~10min; user may be offline overnight; 24h covers typical "return to work, see red CI" pattern. Tighter risks missing user; looser bloats INBOX. Post-Track-9 may tighten to 12h if cardinality shows >50 stale rows/day)
- Aggregation: group by `(repo, sha)`. PR mapping **NOT** performed in T8 (substrate gap — `gh_check_runs_status` payload carries `(repo, sha)` only; PR number derivation requires cross-referencing against `gh_pr_synchronize` events which adds Stage 5 complexity)
- Per-row InboxItem:
  - `kind = .ciFailed`
  - `severity = .danger`
  - `title = "CI failed: \(repo) @\(sha_short)"` (always sha-based — no PR linking in T8)
  - `sourceMeta = "GitHub · \(failed_check_count) checks failed"`
  - `sourceURL = nil` for T8 (graceful — sha→PR mapping deferred; tap behavior degrades to non-tappable row, matches existing D3 sourceURL=nil pattern). **Post-Track-9 carry:** substrate-side `(sha → pr_number)` lookup table or cross-reference substrate enrichment phase
  - `aggregatedCount` = count of distinct (sha, check_run_id) pairs
- Forbidden: commit message text, check output text — ADR-010 walkback (substrate `gh_check_runs_status` parser today strips `output.title` / `output.summary` / `output.text` at write boundary per Phase 4.7.B)

#### 4.4.3 `queryLiveMeeting()` — `.muted` severity

- Read semantic (real query body lives in LeafCorePrivate moat): find `zoom_meeting_started` events inside the cutoff window that do **not** have a matching `zoom_meeting_ended` partner (same `meeting_id`, later timestamp). Uses an unmatched-pair subquery pattern (O(N) on the started feed, not O(N²)).
- Cutoff: `nowMs - 4 * 3600 * 1000` (**4h rationale:** Zoom auto-disconnects after 30hr paid / 40min free; most meetings <2h; 4h covers all-hands long sessions; >4h likely indicates missed `_ended` event due to crash, stale)
- Aggregation: at most 1 row per `meeting_id` (live meetings don't aggregate — at most one active per user)
- Per-row InboxItem:
  - `kind = .liveMeeting`
  - `severity = .muted`
  - `title = "In Zoom meeting"` (generic — meeting topic/title NOT read; ADR-010 walkback)
  - `sourceMeta = "Zoom · started \(relativeTime)"`
  - `sourceURL = InboxSourceURLDeriver.synthesize(.zoomMeeting(meetingID: payload.meeting_id))` — may be nil if PMI not captured
  - `aggregatedCount = 1`
- Forbidden: meeting title / topic / agenda — ADR-010 walkback (Track-6 P5 already walks `meeting_topic` at parser boundary)

### 4.5 Placeholder feeders (moat, gitignored)

```swift
// MARK: - Placeholder feeders (substrate-absent — feeder ships return [] until substrate phase lands)
// See docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md §3.4 lines 100-108
// for substrate gap inventory. Each placeholder feeder unlocks naturally when its substrate phase lands
// (no public LeafCore InboxKind enum change required).

extension ProdInsights {
    /// TODO: Activate when Calendar invitation-response substrate lands.
    /// Substrate gap: Track-6 P4 captures state-change kinds only (focus_block / ooo / working_location /
    /// event_observed), no attendee response event_kind.
    func queryCalInviteDeclined(nowMs: Int64) throws -> [InboxItem] {
        return []
    }

    /// TODO: Activate when Calendar upcoming-window deriver substrate lands.
    /// Substrate gap: requires deriver synthesizing from `google_calendar_event_observed` start times.
    func queryCalUpcoming15min(nowMs: Int64) throws -> [InboxItem] {
        return []
    }

    /// TODO: Activate when Calendar conflict deriver substrate lands.
    /// Substrate gap: requires deriver detecting overlapping events.
    func queryCalConflict(nowMs: Int64) throws -> [InboxItem] {
        return []
    }

    /// TODO: Activate when Mail unread-count substrate lands.
    /// Substrate gap: `mail_active_mailbox_changed` (Track-4 S2) emits mailbox-switch only, no unread counts.
    func queryMailUnreadBucket(nowMs: Int64) throws -> [InboxItem] {
        return []
    }

    /// TODO: Activate when Reminders due-today substrate lands.
    /// Substrate gap: `reminder_completed` (Track-4 S2) emits on completion only, no due-today enumeration.
    func queryReminderDueToday(nowMs: Int64) throws -> [InboxItem] {
        return []
    }

    /// TODO: Activate when Slack DM substrate lands (T3 wrap C-19 carry).
    /// Substrate gap: confirmed absent — no `slack_dm_received` event_kind, no `conversations.list types=im`
    /// polling, no DM bucket in `presence_state.slack`.
    func querySlackDM(nowMs: Int64) throws -> [InboxItem] {
        return []
    }
}
```

### 4.6 D3 sourceURL enrichment (C-16 close)

**Modify:** `queryOpenQuestionsForMe()` + `queryBlockersAffectingMe()` in same file.

Read `context_ref_kind` + `context_ref` columns from M014 tables. Dispatch into `InboxSourceContextRef` cases:

- `context_ref_kind = 'linear_issue'` → parse `context_ref` as `"WORKSPACE/KEY"` → `.linearIssue(workspaceSlug:, key:)`
- `context_ref_kind = 'github_pr'` → parse `context_ref` as `"owner/repo/N"` → `.githubPR(owner:, repo:, number:)`
- `context_ref_kind = 'github_issue'` → parse `"owner/repo/N"` → `.githubIssue(owner:, repo:, number:)`
- `context_ref_kind = 'slack_thread'` → parse `"team/channel/ts"` → `.slackThread(teamID:, channelID:, ts:)`
- Other ref kinds (zoom / cal / xcode) → graceful nil if D3 doesn't currently populate; future-proofs without enforcement

Linear `workspaceSlug` resolution: read `presence_state.linear.workspace_slug` from the presence row (graceful nil if absent — D3 row falls back to sourceURL=nil, preserved current behavior).

**LOC budget for ProdInsights+InboxItems.swift:** ≤700 (current 400; +~200 viable + ~80 placeholder + ~20 D3 enrichment).

### 4.7 UI surface — `InboxFilterRow` 5th chip

**Modify:** `Leaf/Views/Window/Home/Blocks/InboxFilterRow.swift`

Add 5th `LeafPill` button for `.alerts` filter. Same render pattern as existing 4 chips. `.accessibilityAddTraits([.isButton, .isSelected])` on selected chip (P9 a11y pattern).

`InboxBlock.swift` body unchanged — filter dispatch already pure-function via `InboxFiltering.filtered(items:filter:query:)` (P9 C-17 extraction).

**LOC budget:** `InboxFilterRow.swift` ≤45 (current 35); `InboxBlock.swift` ≤95 (current 86).

### 4.8 Dispatcher — `inboxItems(filter:query:)`

**Modify:** main dispatch method in `ProdInsights+InboxItems.swift`.

Append results from 14 feeders (5 viable existing + 3 viable new + 6 placeholder). The aggregation kernel — keyed on `(kind, sourceURL)` with summed aggregate counts — already exists and is unchanged.

Sort order preserved: severity ASC (`.danger=0 → .warn=1 → .muted=2`), then `createdAtMs` DESC.

Filter + query applied view-side via existing `InboxFiltering.filtered(...)` — no change.

---

## 5. Implementation calls (locked sequence)

| # | Call | File | Type |
|---|---|---|---|
| A | Create `InboxSourceContextRef.swift` with 13 enum cases | Public LeafCore | NEW |
| B | Create `InboxSourceURLDeriver.swift` with `synthesize(_:) -> URL?` | Public LeafCore | NEW |
| C | Extend `InboxKind` enum: +9 cases (3 viable + 6 placeholder) | Public LeafCore | MODIFY |
| D | Extend `InboxFilter` enum: +1 case `.alerts` + `admits` switch update | Public LeafCore | MODIFY |
| E | Add `queryBuildFailed()` moat feeder | LeafCorePrivate | NEW |
| F | Add `queryCIFailed()` moat feeder | LeafCorePrivate | NEW |
| G | Add `queryLiveMeeting()` moat feeder | LeafCorePrivate | NEW |
| H | Add 6 placeholder feeders (`queryCal*` × 3 + `queryMailUnreadBucket` + `queryReminderDueToday` + `querySlackDM`) — all `return []` | LeafCorePrivate | NEW |
| I | Enrich `queryOpenQuestionsForMe` + `queryBlockersAffectingMe` with sourceURL synthesis via D3 context_ref columns | LeafCorePrivate | MODIFY |
| J | Wire 9 new feeders into `inboxItems(filter:query:)` dispatcher | LeafCorePrivate | MODIFY |
| K | Add `.alerts` chip rendering in `InboxFilterRow.swift` | Leaf app target | MODIFY |
| L | Master spec §9.1 status markers update (C-14/C-15 DEFERRED, C-16 RESOLVED T8) | docs | MODIFY |

---

## 6. ADR-010 invariants

Per T7 lineage + master spec §6:

1. `InboxSourceContextRef` enum associated values are opaque refs only (slug / key / number / opaque ID / sanitized path). No body / title / comment text / email subject / note content.
2. `InboxSourceURLDeriver.synthesize(_:)` performs pure string interpolation from opaque refs. Never reads payload body fields directly.
3. `queryBuildFailed()` reads `project_path` (already substrate-stripped per Track-6 P2 — ProdXcodeAdapter parses `errors[].message` at parser boundary, doesn't reach RawEvent.payload).
4. `queryCIFailed()` reads `repo` + `pr_number` + `conclusion` enum (`gh_check_runs_status` parser already strips `output.title` / `output.summary` / `output.text` per Phase 4.7.B).
5. `queryLiveMeeting()` reads `meeting_id` opaque ref (Track-6 P5 already walks `meeting_topic` at parser boundary).
6. D3 context_ref columns are opaque ref strings — `LinearIDExtractor` precedent (`[A-Z][A-Z0-9]{1,4}-\d+` structural match, no body bytes).

Sentinel-injection regression test (§7.3) integration sweep covers all `InboxSourceContextRef` cases via switch dispatch + write-boundary test covers `presence_state.{zoom,xcode}.state_json` non-leakage for viable kinds.

---

## 7. Testing strategy

### 7.1 Public LeafCore tests (LeafCoreTests/)

#### `InboxItemTests.swift` additions (+2 tests)

- `testInboxKindCount_14CasesUnderT8` — `InboxKind.allCases.count == 14` + iterate raw values lock against regression
- `testInboxFilterAdmits_5FilterMatrix` — each of 5 filters × each of 14 kinds = 70 admit assertions (table-driven)

#### `InboxFilteringTests.swift` additions (+1 test)

- `testFilterAlerts_admitsBuildAndCIAndLiveMeeting_onlyThose` — `.alerts` filter returns rows for buildFailed/ciFailed/liveMeeting kinds, excludes reviewRequest/openQuestion/mention/etc.

#### `InboxSourceURLDeriverTests.swift` (NEW, +13 tests)

- `testLinearIssue_synthesizesCanonical` — input `(slug:"leaf", key:"LEAF-42")` → `"https://linear.app/leaf/issue/LEAF-42"`
- `testLinearIssue_emptySlugReturnsNil` — graceful empty-input handling
- `testGithubPR_synthesizesCanonical` — `(owner:"gundemtech", repo:"leaf", number:142)` → `"https://github.com/gundemtech/leaf/pull/142"`
- `testGithubIssue_synthesizesCanonical` — parallel to PR
- `testGithubPRComment_appendsDiscussionAnchor` — fragment `#discussion_r<commentID>`
- `testGithubIssueComment_appendsIssueCommentAnchor` — fragment `#issuecomment-<commentID>`
- `testGithubNotificationsRoot_synthesizesCanonical` — `"https://github.com/notifications"`
- `testSlackThread_synthesizesDeepLink` — `slack://channel?team=...&id=...&message=...`
- `testSlackChannel_synthesizesDeepLink` — without `message=` fragment
- `testCalendarEvent_synthesizesIcalScheme` — `ical://<event_id>`
- `testZoomMeeting_synthesizesDeepLink` — `zoommtg://zoom.us/join?confno=<id>`
- `testXcodeBuild_returnsNilWhenProjectPathAbsent` — `.xcodeBuild(projectPath: nil)` → nil
- `testMailMailbox_synthesizesMessageScheme` — `message://%3C<acct>/<mailbox>%3E`
- `testReminderList_synthesizesAppleReminderKitScheme` — `x-apple-reminderkit://REMCDReminder/<list_id>`

### 7.2 Moat tests (LeafCorePrivate/Tests/, gitignored)

#### `ProdInsightsInboxItemsTests.swift` additions (+~12 tests)

Viable feeders (+3):
- `test_queryBuildFailed_returnsRowsForErrorsGreaterZeroWithinCutoff`
- `test_queryCIFailed_aggregatesByPRWithDangerSeverity`
- `test_queryLiveMeeting_excludesEndedMeetings_returnsActiveOnly`

Placeholder feeders (+6 regressions locking `return []` contract):
- `test_queryCalInviteDeclined_returnsEmpty_substrateAbsent`
- `test_queryCalUpcoming15min_returnsEmpty_substrateAbsent`
- `test_queryCalConflict_returnsEmpty_substrateAbsent`
- `test_queryMailUnreadBucket_returnsEmpty_substrateAbsent`
- `test_queryReminderDueToday_returnsEmpty_substrateAbsent`
- `test_querySlackDM_returnsEmpty_substrateAbsent`

D3 sourceURL enrichment (+3):
- `test_queryOpenQuestionsForMe_synthesizesLinearURLWhenContextRefPresent`
- `test_queryBlockersAffectingMe_synthesizesGitHubPRURLWhenContextRefPresent`
- `test_d3SourceURLEnrichment_gracefulNilWhenWorkspaceSlugAbsent`

### 7.3 Sentinel-injection regression (LeafCoreTests/RelayBodyLeakageTests.swift)

Pattern parity with T3 (write-boundary through `writeEventsOffsetAndPresence`, not pure-function deriver test). **Reasoning:** `InboxSourceURLDeriver.synthesize(_:)` is a pure-function on opaque refs — it cannot leak body bytes it never reads. Sentinel injected directly INTO ref args (e.g., `slug = "leaf-SENTINEL"`) would produce sentinel in URL by design (structural composition working as documented), which is not a leak. Real leak detection requires the **full feeder + deriver path** exercised via public API.

- `test_t8_walkback_inboxItems_dispatcherDoesNotLeakSentinel` — integration sweep. For each of 3 viable kinds (buildFailed/ciFailed/liveMeeting) + 2 D3 enrichment kinds (openQuestion/blocker):
  1. Write event via public `writeEventsOffsetAndPresence` API with `LEAKED_SENTINEL_T8_INBOX_BODY` padded into body-position payload fields (xcode `errors[].message` if substrate carried it, gh_check_runs `output.text`, zoom `meeting_topic`, slack `message_text`, mail `subject`). Clean opaque refs (no sentinel in `project_path` / `repo` / `sha` / `meeting_id` / etc).
  2. Invoke public `derived.inboxItems(filter: .all, query: "")` via `DerivedInsights` protocol.
  3. Assert no returned `InboxItem.{title, sourceMeta, sourceURL absoluteString}` contains sentinel substring.
  4. Single test sweeps all 5 path types via switch dispatch.

- `test_t8_walkback_buildFailedAndLiveMeeting_payloadsDoNotLeakIntoPresenceState` — write-boundary sentinel through `writeEventsOffsetAndPresence` with sentinel-bearing payload body fields. Assert `presence_state.zoom.state_json` + `presence_state.xcode` equivalent state surfaces don't contain sentinel fragments. Validates `PresenceStateWriter.{zoomComposite, xcodeComposite}` paths (already shipped Track-6 P2/P5) don't bleed body bytes — regression-locks existing invariant under new feeder activation.

**Total new tests: 27-30 net new** (2 InboxItem + 1 InboxFiltering + 13 deriver structural + 12 moat + 2 walkback; range allows fixture/refactor wiggle). Baseline post-T7: 2994 → target ~3022.

---

## 8. Acceptance criteria

| # | Gate | Verification command | Target |
|---|---|---|---|
| AC-1 | xcodebuild Debug build all schemes | `xcodebuild -scheme <X> -configuration Debug build` × 5 | 5/5 SUCCESS |
| AC-2 | SPM tests pass | `swift test --package-path Packages/LeafCore` + `--package-path Packages/LeafCorePrivate` | ≥3017 total, 0 failures, ≤4 skipped |
| AC-3 | `just check-tokens` | `just check-tokens` | 3-tier clean (BASE + MIGRATION + RETIRED) |
| AC-4 | SQLCipher migrations frozen | `git diff aa89eeb7..HEAD -- Packages/LeafCore/Sources/LeafCore/DB/` | empty |
| AC-5 | ShareEventTypeRegistry frozen | `git diff aa89eeb7..HEAD -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | empty (registry at 198 post-T3) |
| AC-6 | LeafMCP inventory frozen | `git diff aa89eeb7..HEAD -- LeafMCP/ Packages/LeafCore/Sources/LeafCore/MCP/` | empty (15 tools) |
| AC-7 | Privacy walkback narrow grep | `grep -rnE "absolute_path\|full_comment_body\|raw_email\|notes_body\|prompt\|tool_input\|tool_response\|response_body\|email_subject\|note_body\|file_contents" <T8 file scope>` | 0 hits |
| AC-8 | LOC budgets | `wc -l` per file | `InboxItem.swift` ≤120 (current 66); `InboxSourceURLDeriver.swift` ≤120; `InboxSourceContextRef.swift` ≤60; `ProdInsights+InboxItems.swift` ≤700 (current 400); `InboxBlock.swift` ≤95 (current 86); `InboxFilterRow.swift` ≤45 (current 35); `HomeView.swift` ≤280 unchanged |
| AC-9 | Sentinel-injection coverage | Test count in `RelayBodyLeakageTests` | +2 vs T7 baseline (integration sweep + write-boundary) |
| AC-10 | Master spec §9.1 status markers | `grep "RESOLVED T8\|DEFERRED" docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` | C-14 DEFERRED, C-15 DEFERRED, **C-16 RESOLVED T8** |

---

## 9. Carry-overs

### 9.1 Master spec §9.1 status markers post-T8

- **C-14** search debounce / SQL re-fetch — DEFERRED (no substrate change; defer until 14d cardinality > 1000 observed)
- **C-15** `RouteCoordinator.openURL(_:URL)` extraction — DEFERRED (single-callsite pattern persists)
- **C-16** `InboxItem.sourceURL` nil for D3-derived — **RESOLVED T8** (D3 feeders synthesize via `InboxSourceURLDeriver`)

### 9.2 T8 net new carries (post-Track-9 backlog)

- **Placeholder kind substrate enrichment** — 6 dedicated substrate phases (Calendar invitation-response observer / Calendar upcoming-15min deriver / Calendar conflict deriver / Mail unread-count substrate / Reminders due-today substrate / Slack DM polling). Each phase: own brainstorm + spec + plan + sentinel test, lights up corresponding feeder method without public LeafCore enum change.
- **`gh_check_runs_status` sha→PR mapping substrate enrichment** — T8 ships `.ciFailed` with `sourceURL = nil` + sha-based title (graceful degrade). Future substrate phase: JOIN-side mapping table or `gh_pr_synchronize` payload extension to enable `sourceURL = .githubPR(...)` and "PR #N" title format.
- **Per-category InboxFilter chips** — beyond umbrella `.alerts`, split when placeholders land (`.calendar` / `.communications` / etc).
- **`xcode_build_failed` branch context** — substrate gap; future enrichment for main vs dev severity discrimination.
- **`gh_check_runs_status` branch context** — substrate gap; same (separate from sha→PR mapping above).
- **liveMeeting INBOX vs YOU·NOW double-surface** — T5 YOU·NOW shows `.inMeeting` state for current meeting; T8 INBOX shows `.liveMeeting` for same state. Mild redundancy. Acceptable carry — Track-7 P3+ surface design might consolidate (one canonical surface for "currently in meeting"). UX feedback driven.
- **`get_inbox` MCP tool** — future if AI clients request INBOX queries.
- **Localization track (C-19)** — `InboxKind` severity word + filter chip labels hardcoded English; separate track owns extraction. Includes scrutiny of `.alerts` chip label — "alert" implies urgent but `.liveMeeting` (`.muted`) sits awkwardly under it; localization rename candidate.
- **Helper testability hoisting** — Stage 6 review may flag `InboxSourceURLDeriver` internal helpers (e.g., URL-escape utilities) for testability hoisting. Carry to Track-9 wrap T10 if surfaces.

### 9.3 Out-of-scope confirmations

Per §1.2 above — all T8-deferred items documented inline with substrate-phase or post-Track-9 phase reference.

---

## 10. References

- Track-9 master spec: `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` §3.4 + §T8
- T7 predecessor spec (substrate-purity precedent): `docs/superpowers/specs/2026-05-21-track-9-T7-where-stopped-4line.md`
- Track-8 master spec §9.1 carry backlog: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md`
- Phase 8.6 INBOX wire-up: `docs/superpowers/specs/2026-05-18-phase-8-6-inbox.md`
- T7 ship summary: `.claude/shared/current-state.md` (2026-05-21 entry)
- ADR-010 walkback discipline: `RelayBodyLeakageTests` Track-3 D1..D3 + Track-6 P1..P7 + Track-9 T1..T7 sentinel-injection lineage
- Architecture: `.claude/shared/architecture.md`
- Conventions / per-phase workflow: `.claude/shared/conventions.md` (one-phase-one-session, 8-stage workflow)

---

## 11. Workflow

Per `.claude/shared/conventions.md` "Одна phase = одна сессия":

1. ✅ Discovery (Stage 1 — Explore subagent + main cross-check inventory)
2. ✅ Brainstorm (Stage 2 — `superpowers:brainstorming` skill, Q1-5 + Sec 1-3 approval)
3. ⏳ Spec write (Stage 3 — this document, self-review + user review gate)
4. ⏳ Plan (Stage 4 — `superpowers:writing-plans` skill, atomic per-commit decomposition + per-step AC)
5. ⏳ Implementation (Stage 5 — `superpowers:test-driven-development` per step, sequential discipline)
6. ⏳ Independent review (Stage 6 — `superpowers:code-reviewer` subagent + `superpowers:receiving-code-review`)
7. ⏳ Verification (Stage 7 — `superpowers:verification-before-completion`, 10 AC gates green)
8. ⏳ Ship (Stage 8 — SHIPPED commit + master spec §9.1 status markers + current-state.md update + merge → `fix/dev-launch-reliability` + direct-exec smoke per T7 proven workflow)
