# Track-9 T7 — WHERE STOPPED 4-line layout + anchor file:line + recentLastCommit + WIP chips

**Phase**: Track-9 T7  
**Status**: SHIPPED  
**Branch**: `feature/track-9-substrate` (off T6 wrap tip `d32486dd`)  
**Predecessors**: T1..T6 (substrate enrichment + TODAY hybrid pills)  
**Master spec**: `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` §3.3 / §T7 / §9.1 (C-20 / C-21)  
**Carry resolutions**: master spec §9.1 — **C-20 RESOLVED T7** (Line 2 last-commit subject deriver) / **C-21 RESOLVED T7** (anchorEventId → file path:line resolution + WIP chip styling)  
**Substrate purity**: zero new SQLCipher migrations / event_kinds / MCP tools. ShareEventTypeKey registry frozen at **198** post-T3 (unchanged through T4-T6).

---

## §1 Scope

T7 closes the WHERE STOPPED 4-line layout per master spec §3 mockup:

```
┌─ WHERE YOU STOPPED · 2h ago ▸ ──────────────────────────┐
│ Track-7 P5 polish · WorkStateCard.swift:142             │
│ Last commit: "wf: HIG sweep accessibilityLabel parity"  │
│ [commitWip] [midEdit]                                    │
└─────────────────────────────────────────────────────────┘
```

Three carry closes from Phase 8.7 / master spec §9.1:

1. **C-20 Line 2 last-commit subject** — `DerivedInsights.recentLastCommit(maxAgeMs:)` exists (Track-9 T1 ship); T7 wires `InsightsReader.refresh()` 20th sequential SQL call + plumbs through `InsightsSnapshot.recentLastCommit: RecentCommitSnapshot?` + renders as Line 3 when `commit.atMs >= now - 4h`.
2. **C-21 anchorEventId → file path:line resolution** — `WhereStoppedSnapshot` gains `anchorFilePath: String?` + `anchorLine: Int?` Optional fields populated by `ProdWhereStoppedDeriver` via **deriver-side LEFT JOIN** against `events.payload_json` (no schema migration — preserves Track-9 zero-mig invariant). Line 2 renders `<filename>:<line>` (Xcode), `<filename>` (path-only fallback), or excerpt (anchor missing).
3. **C-21 WIP chip styling** — wipSignals migrate from `Text` join to `LeafPill` chips with per-signal tone mapping.

### §1.1 Hard exclusion (out of scope)

- **No M028 SQLCipher migration.** Master spec §T7 offered `anchor_file_path TEXT NULL` + `anchor_line INTEGER NULL` column additions as one of two design routes; T7 picks deriver-side JOIN to preserve Track-9 zero-migration substrate-purity invariant (T1-T6 added zero migrations). M001-M018 + M024 + M026 + M027 preserved (30 tables).
- **No new event_kinds.** T7 reads existing substrate — `xcode_active_doc_changed.doc_path` + `.line` (T1 ship), `gh_commit_pushed` (Phase 4.7 baseline), M014 `where_stopped_log` rows.
- **No new MCP tools.** 15-tool inventory unchanged.
- **No new ShareEventTypeKey entries.** Registry frozen at 198.
- **VSCode/JetBrains line capture.** `vscode_active_doc_changed` ships workspace_root only (Track-6 P6); no per-file line capture. JetBrains same. T7 ships graceful path-only fallback for non-Xcode anchors; full per-file resolution = post-Track-9 IDE family enrichment track.
- **Line number from non-Xcode anchors.** When anchor event is `vscode_workspace_opened` / `jetbrains_recent_project_observed` / commit event / ticket event, `anchorLine` returns nil. Line 2 renders path-only (`filename`) or excerpt (commit / ticket anchors — no file context).
- **WIP signal tone polish iteration.** T7 ships a 3-tone mapping (commitWip→warning, midEdit→accent, unknown→neutral); per-signal palette refinement = post-Track-9 design iteration if needed.
- **Absolute path display.** Path basename only via `(path as NSString).lastPathComponent` — full absolute path is too long for Line 2 and leaks workspace structure unnecessarily. Users have IDE bookmarks to navigate.
- **Resume CTA on Line 2.** WHERE STOPPED is informational — tap routes to existing Track-7 P3 `WorkStateDetailScreen` (Phase 8.7 ship). No new tap targets in T7.
- **Stale-anchor warning.** If anchor event was deleted (D3 retention sweep), JOIN returns NULL → Line 2 falls back to excerpt silently. No UX nag.
- **Multi-file diff annotation.** Single anchor only. If a session touched 8 files, deriver picks the most-recent per existing heuristic.

### §1.2 Deviations from master spec §T7

Master spec §T7 line 201: "M014 schema migration M028 — adds `anchor_file_path TEXT NULL` + `anchor_line INTEGER NULL` columns to `where_stopped_log` (**or stores in deriver-side join — design choice in T7 brainstorm**)."

T7 brainstorm resolved: **deriver-side JOIN**. Rationale documented in §3.2 below. Master spec amendment carry to Track-9 T10 wrap (no current-state.md or spec-side edit required this phase — §T7 line 201 already documents both routes as legal).

---

## §2 Substrate touches summary

| Layer | File | Touch |
|-------|------|-------|
| LeafCore types | `Packages/LeafCore/Sources/LeafCore/Home/WorkState/WhereStoppedSnapshot.swift` | Add 3 Optional fields (`anchorFilePath: String? = nil`, `anchorLine: Int? = nil`, `recentLastCommit: RecentCommitSnapshot? = nil`); all defaulted for backward-compat init at existing call sites |
| LeafCore moat | `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+RecentWhereStopped.swift` (or in-place in existing deriver — TBV at exec) | SQL refactor: existing `recentWhereStopped(limit:)` extended with `LEFT JOIN events ON w.anchor_event_id = events.id` + `json_extract(events.payload_json, '$.doc_path')` + `json_extract(..., '$.line')`; basename extraction in Swift post-fetch. Deriver returns snapshots with `anchorFilePath` + `anchorLine` populated, `recentLastCommit` always nil (composed Reader-side). |
| App | `Leaf/Models/InsightsReader.swift` | 20th sequential SQL call `try insights.recentLastCommit(maxAgeMs: 4 * 60 * 60 * 1000)` after the existing `recentWhereStopped(limit: 1).first` fetch (line 195 today). **Path B composition**: Reader splices the commit into a new `WhereStoppedSnapshot` via defaulted-init when both substrate calls return non-nil. No deriver signature change. |
| App | `Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift` | 2-line populated layout → 4-line populated layout (header / `<filename>:<line>` or `<filename>` or excerpt / `Last commit: "..."` if non-nil / WIP chips via `LeafPill`); add helpers `lineLabel(for:)` / `wipSignalTone(_:)` / `commitSubjectLine(_:)` |

**Public API additions (LeafCore)**:
- `WhereStoppedSnapshot.anchorFilePath: String?` defaulted nil
- `WhereStoppedSnapshot.anchorLine: Int?` defaulted nil
- `WhereStoppedSnapshot.recentLastCommit: RecentCommitSnapshot?` defaulted nil

**No `InsightsSnapshot` additions** (per §3.3 Path B / §9 H — composition lives in `InsightsReader` populating the single field on `WhereStoppedSnapshot`).

**No public API removals.** `RecentCommitSnapshot` already exists (T1 ship, `Packages/LeafCore/Sources/LeafCore/Insights/RecentCommitSnapshot.swift`).

---

## §3 SQL refactor — deriver-side LEFT JOIN + 4-line layout

### §3.1 ProdWhereStoppedDeriver extension (moat)

Existing impl reads M014 `where_stopped_log` rows and produces `WhereStoppedSnapshot` with `id / generatedAtMs / anchorEventId / excerpt / wipSignals`. T7 extends the fetch SQL with LEFT JOIN against events:

```sql
SELECT
    w.id, w.generated_at_ms, w.anchor_event_id, w.excerpt, w.wip_signals_json,
    json_extract(e.payload_json, '$.doc_path')   AS anchor_doc_path,
    json_extract(e.payload_json, '$.line')       AS anchor_line
FROM where_stopped_log w
LEFT JOIN events e ON w.anchor_event_id = e.id
ORDER BY w.generated_at_ms DESC
LIMIT ?
```

**LEFT JOIN rationale**: anchor_event_id is nullable in M014 (Phase Track-1 D3 design). Anchors may also be commit / ticket events without doc_path. NULL `anchor_doc_path` → `anchorFilePath = nil` → Line 2 falls back to excerpt.

**JOIN cost**: events.id is PRIMARY KEY (implicit unique index). Per-row JOIN is O(log N) lookup. Typical `recentWhereStopped(limit: 1)` → 1 JOIN per refresh. Cost negligible (~5-50µs per indexed PK lookup on SQLCipher).

**Filename extraction**: `(anchor_doc_path as NSString).lastPathComponent` applied post-fetch in Swift. Empty / nil path → nil filename → Line 2 falls back to excerpt.

**Line number normalization**: `json_extract` returns Int64 directly when payload value is `String(Int)` per existing Xcode payload convention; tests cover both Int64 and String round-trip. Negative or zero → nil (defensive — substrate emits `>= 1` only per XcodeStateMachine T1 contract).

### §3.2 Why deriver-side JOIN, not M028 migration

Decision lock from §1.2:

**Cost analysis (per refresh)**:
- M028 path: 1 SQL read (denormalized columns); +1 SQL write at deriver time (extra JOIN against events); +1 schema migration; legacy rows have NULL until re-derived
- JOIN path: 1 SQL read (PK indexed JOIN against events); 0 schema migration; legacy rows JOIN cleanly (NULL anchor → NULL path)

**Tradeoff**: JOIN adds 1 PK lookup at READ time. For Home block refresh, 1 PK lookup per refresh ≈ 10-50µs amortized cost. M028 saves this at the cost of denormalization complexity + storage + ADR-010 surface expansion (path bytes flow to detection table). JOIN keeps path bytes in events table only (already walked through ADR-010 allowlist).

**Substrate-purity tradeoff**: T1-T6 maintained zero-migration invariant through 6 Track-9 phases. Breaking the invariant in T7 for marginal read-time optimization is over-engineering. **Decision: JOIN preserves invariant**.

**M028 reservation**: M028 number stays reserved for future SQLCipher migration if a real need surfaces (e.g., search-by-file-path use case across all where_stopped_log rows — not currently anticipated).

### §3.3 InsightsReader 20th SQL call — Path B composition

**Lock** (resolves brainstorm Path A vs Path B): commit fetch lives in `InsightsReader`, not in the deriver. Reader splices the result into a new `WhereStoppedSnapshot` via defaulted-init after both substrate calls return. No deriver signature change — preserves T1-T6 zero-signature-churn invariant.

`refresh()` body extended between current `whereStopped` fetch (Phase 8.7 ship — **line 195** today, after `inboxItems`) and `InsightsSnapshot` init:

```swift
// Phase 8.7 baseline (unchanged):
let whereStoppedBase = try insights.recentWhereStopped(limit: 1).first
try Task.checkCancellation()

// Track-9 T7 — 20th sequential call, 4h cutoff per §C lock.
let recentLastCommit = try insights.recentLastCommit(maxAgeMs: 4 * 60 * 60 * 1000)
try Task.checkCancellation()

// Path B composition — splice commit into the deriver's snapshot.
// Defaulted-init at WhereStoppedSnapshot keeps anchorFilePath /
// anchorLine populated by the deriver; recentLastCommit added here.
let whereStopped: WhereStoppedSnapshot? = whereStoppedBase.map { base in
    WhereStoppedSnapshot(
        id: base.id,
        generatedAtMs: base.generatedAtMs,
        anchorEventId: base.anchorEventId,
        excerpt: base.excerpt,
        wipSignals: base.wipSignals,
        anchorFilePath: base.anchorFilePath,
        anchorLine: base.anchorLine,
        recentLastCommit: recentLastCommit
    )
}
```

**Why Path B (not Path A — `recentWhereStopped(limit:maxAgeMs:)` deriver-side combined fetch)**:

- **Zero deriver signature change** — T1-T6 added 3 Optional fields to value types but never changed `DerivedInsights` protocol method signatures. Path B preserves invariant.
- **Single-responsibility deriver** — `ProdWhereStoppedDeriver` reads M014 `where_stopped_log` + (new) JOIN `events`. Adding commit fetch into it couples two distinct substrate sources. Reader is the natural composition site.
- **Cost identical** — same two `DerivedInsights` calls regardless of which layer composes. Path B = 1 SQL fetch from `recentWhereStopped` + 1 fetch from `recentLastCommit` (existing T1 method).
- **No two-snapshot duplication** — `InsightsSnapshot.recentLastCommit` field NOT added (per §9 H). Renderer reads `snapshot.whereStopped?.recentLastCommit` only.

**Stub path** — `StubInsights.recentLastCommit` already returns nil (T1 ship). Reader call yields nil → composition yields `WhereStoppedSnapshot` with `recentLastCommit = nil` → block renders 3-line layout (no commit row). Existing fixture sites continue passing nil where they passed nil before.

### §3.4 No presence_state writes, sentinel-injection test added

T7 reads `events.payload_json.doc_path` + `.line` — **new privacy surface** (T1-T6 derivers read aggregate counts / numbers / state enums; T7 is first to read structured payload field with potential PII/workspace info).

ADR-010 walkback: `doc_path` is allow-listed for the Xcode collector (T1 ship). Path bytes flow through M014 (anchor_event_id reference) and now Line 2 rendering. **Sentinel-injection regression test mandatory** — pattern parity with T1's `test_t1_walkback_xcodeActiveDocChanged_lineNeverLeaksContent`:

`RelayBodyLeakageTests.test_t7_walkback_anchorDocPathBasenameOnlyDoesNotLeakAbsolutePath`:
- Inject sentinel into anchor event's `payload_json.doc_path` (e.g., `/Users/LEAKED_SENTINEL_T7/Desktop/secret.swift`)
- Derive `WhereStoppedSnapshot` via ProdWhereStoppedDeriver
- Assert `anchorFilePath == "secret.swift"` (basename only — sentinel NOT in result)
- Assert `presence_state.state_json` (existing rows) does not contain sentinel
- Assert `events.payload_json` continues to contain sentinel (raw substrate unchanged — walked at read boundary only)

This pattern is critical for the new privacy surface. Spec §6.4 amendment vs T6 — T6 was exempt (aggregate counts); T7 reads structured field → sentinel test required.

---

## §4 UI changes — 4-line layout + WIP chips

### §4.1 WhereStoppedBlock body refactor

Current 2-line populated layout (Phase 8.7, lines 55-75):

```swift
private func populatedBody(_ snap: WhereStoppedSnapshot) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text(snap.excerpt)
            .font(LeafType.title.small)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(2)
        if !cleanWipSignals.isEmpty {
            Text(cleanWipSignals.joined(separator: " · "))
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
```

Refactored 4-line layout:

```swift
private func populatedBody(_ snap: WhereStoppedSnapshot) -> some View {
    let cleanWipSignals = snap.wipSignals.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return VStack(alignment: .leading, spacing: LeafSpace.xs) {
        // Line 2 — anchor file:line (if available) OR excerpt fallback.
        Text(lineLabel(for: snap))
            .font(LeafType.title.small)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
        // Line 3 — last commit subject (if ≤4h).
        if let commit = snap.recentLastCommit {
            Text(commitSubjectLine(commit))
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Line 4 — WIP signals as LeafPill chips.
        if !cleanWipSignals.isEmpty {
            HStack(spacing: LeafSpace.xs) {
                ForEach(cleanWipSignals, id: \.self) { signal in
                    LeafPill(title: signal, tone: wipSignalTone(signal))
                }
            }
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func lineLabel(for snap: WhereStoppedSnapshot) -> String {
    if let path = snap.anchorFilePath, !path.isEmpty {
        let basename = (path as NSString).lastPathComponent
        if let line = snap.anchorLine, line > 0 {
            return "\(basename):\(line)"
        }
        return basename
    }
    return snap.excerpt
}

private func commitSubjectLine(_ commit: RecentCommitSnapshot) -> String {
    let trimmed = commit.subject.trimmingCharacters(in: .whitespaces)
    let capped = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    return "Last commit: \"\(capped)\""
}

private func wipSignalTone(_ signal: String) -> LeafPillTokens.Tone {
    switch signal {
    case "commitWip": return .warning
    case "midEdit":   return .accent
    default:          return .neutral
    }
}
```

### §4.2 Line 1 (header)

Header `"WHERE YOU STOPPED · <relative>"` already shipped Phase 8.7 via `HomeRelativeTimeFormatter.format(deltaMs:nowMs:)` (P9 unified). **No change needed** — Line 1 stays as-is.

### §4.3 Line 3 commit subject — 60-char cap rationale

Master spec §9.1 C-20 stated "last commit subject (60 char cap)". `commitSubjectLine` enforces:
- Trim leading/trailing whitespace
- If > 60 chars, truncate to 60 + ellipsis (`…`)
- Wrap in quotes per mockup `Last commit: "..."`
- `.lineLimit(1)` SwiftUI clamp catches any overflow if `prefix(60)` somehow exceeds rendered width (defensive)

### §4.4 Line 4 WIP chip tones

3-tone mapping aligns with semantic intent:
- `commitWip` → `.warning` (yellow/orange — work-in-progress, needs attention)
- `midEdit` → `.accent` (project accent — actively editing, neutral-positive)
- `unknown` → `.neutral` (safe fallback for future signal additions)

`ciFailing` was reserved by Track-1 D3 deriver (always false today). If T7 surfaces it via wipSignals (unlikely — deriver returns hardcoded false), tone `.danger` would apply via per-signal switch extension. YAGNI — current 3-tone enough.

**Target visibility**: `LeafPill` + `LeafPillTokens.Tone` live in the Leaf app target (`Leaf/Theme/...`), not LeafCore. `WhereStoppedBlock` is in the same target (`Leaf/Views/Window/Home/Blocks/`), so `wipSignalTone(_:) -> LeafPillTokens.Tone` is a valid private helper signature. No SwiftPM visibility changes required.

### §4.5 No size param on LeafPill — fixed-small acceptable

Per Discovery: `LeafPill` is single-size (11pt icon + body.small text). WIP chips fit naturally; no API change needed. If T7 ship reveals WIP chips visually too large in narrow-window scenarios, P9-style polish iteration adds size param (post-T7 carry).

### §4.6 A11y refactor

Existing `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Open work state details")` retained. New `.accessibilityHint` updates based on populated/empty branch + presence of Line 3:

```swift
private var accessibilityHint: String {
    guard hasUsableSnapshot, let snap = snapshot else {
        return "No recent stop-points captured."
    }
    var parts = ["Opens work state details with decisions, questions, blockers."]
    if let path = snap.anchorFilePath {
        let basename = (path as NSString).lastPathComponent
        if let line = snap.anchorLine, line > 0 {
            parts.append("Last touched \(basename) line \(line).")
        } else {
            parts.append("Last touched \(basename).")
        }
    }
    if let commit = snap.recentLastCommit {
        parts.append("Recent commit: \(commit.subject).")
    }
    return parts.joined(separator: " ")
}
```

### §4.7 Animation preserved

`.animation(.easeInOut(duration: 0.25), value: snapshot)` retained (Phase 8.7 pattern). New WIP chip transitions inherit; `LeafPill` is value-type-rendered via `ForEach(id: \.self)`, animation triggers correctly on `cleanWipSignals` change.

---

## §5 Testing

### §5.1 Public LeafCore tests

`WhereStoppedSnapshotTests.swift` (`Packages/LeafCore/Tests/LeafCoreTests/Home/`, NEW or extend existing):

- **PT-1** `whereStopped_backwardCompatInit_5arg` — existing 5-arg init still compiles (defaulted-init pattern). Renamed from `T1` to avoid visual collision with Track-9 phase IDs.
- **PT-2** `whereStopped_fullInit_roundtripsAllFields` — `WhereStoppedSnapshot(id:1, generatedAtMs:..., anchorEventId:nil, excerpt:"e", wipSignals:[], anchorFilePath:"foo.swift", anchorLine:42, recentLastCommit: snap)` round-trips through Equatable/Hashable/Sendable.
- **PT-3** `whereStopped_optionalFields_defaultNil` — 5-arg convenience init yields nil for all 3 new fields.

`InsightsSnapshotTests.swift` (extend existing): verify Phase 8.7 default `whereStopped: nil` still works. **No new `InsightsSnapshot` field added** (per §3.3 Path B / §9 H) — regression check only, no positive test for `recentLastCommit` at snapshot level.

### §5.2 Moat tests (LeafCorePrivate, gitignored, local-verified)

`ProdInsightsRecentWhereStoppedTests.swift` (extend existing — Phase 8.7 era):

- **MT-1** `recentWhereStopped_xcodeAnchor_yieldsPathAndLine` — seed `xcode_active_doc_changed` event with `doc_path="/Users/dev/Code/Foo.swift"` + `line="142"`; seed where_stopped_log row with `anchor_event_id = event.id`; assert `anchorFilePath == "Foo.swift"` (basename) + `anchorLine == 142`.
- **MT-2** `recentWhereStopped_vscodeAnchor_yieldsPathOnly` — seed `vscode_workspace_opened` event with `workspace_root` (no `doc_path`); assert `anchorFilePath == nil` (no doc_path on this event_kind).
- **MT-3** `recentWhereStopped_nullAnchor_yieldsNoPath` — seed where_stopped_log row with `anchor_event_id = NULL`; assert `anchorFilePath == nil` + `anchorLine == nil`.
- **MT-4** `recentWhereStopped_missingAnchorEvent_gracefulFallback` — seed row with `anchor_event_id = 9999` (no matching event); LEFT JOIN yields NULL; assert no crash, both fields nil.
- **MT-5** `recentWhereStopped_zeroLine_normalizedToNil` — seed event with `line="0"`; assert `anchorLine == nil` (defensive normalization).
- **MT-6** `recentWhereStopped_pathOnly_emptyBasenameSafe` — seed event with `doc_path=""`; assert `anchorFilePath == nil`.

`ProdInsightsLastCommitTests.swift` (existing T1 era — verify regression-free): no new tests needed (no impl change in `recentLastCommit`).

### §5.3 Sentinel-injection regression test (mandatory — new privacy surface)

`RelayBodyLeakageTests.swift` (existing — append):

```swift
func test_t7_walkback_anchorDocPathBasenameOnlyDoesNotLeakAbsolutePath() throws {
    let sentinel = "LEAKED_SENTINEL_T7_DOC_PATH"
    let fullPath = "/Users/\(sentinel)/Desktop/secret_workspace/Foo.swift"
    
    // Seed Xcode anchor event with sentinel in absolute path
    let eventId = try seedXcodeDocEvent(docPath: fullPath, line: 42, atMs: ...)
    try seedWhereStoppedRow(anchorEventId: eventId, ...)
    
    let insights = ProdInsights(database: db)
    let snapshots = try insights.recentWhereStopped(limit: 1)
    
    // 1. Public-facing snapshot field carries basename only — no sentinel
    let snap = try XCTUnwrap(snapshots.first)
    XCTAssertEqual(snap.anchorFilePath, "Foo.swift", "basename only, no path")
    XCTAssertEqual(snap.anchorLine, 42)
    XCTAssertFalse(
        (snap.anchorFilePath ?? "").contains(sentinel),
        "sentinel must not appear in anchorFilePath"
    )
    
    // 2. presence_state (existing rows) — sentinel must not have been written
    let presenceRows = try db.read { try Row.fetchAll($0, sql: "SELECT state_json FROM presence_state") }
    for row in presenceRows {
        let s: String = row["state_json"] ?? ""
        XCTAssertFalse(s.contains(sentinel), "sentinel leaked into presence_state")
    }
    
    // 3. Raw substrate preserved — events.payload_json still contains sentinel (walked at read boundary only)
    let raw = try db.read { try String.fetchOne($0, sql: "SELECT payload_json FROM events WHERE id = ?", arguments: [eventId]) }
    XCTAssertNotNil(raw)
    XCTAssertTrue(raw!.contains(sentinel), "raw events table preserves substrate (intentional — walked at deriver boundary)")
}
```

Pattern parity with T1 `test_t1_walkback_xcodeActiveDocChanged_lineNeverLeaksContent` + T2 `test_t2_walkback_linearCommentToMe_urlIsStructurallyComposed`.

### §5.4 Test count delta

- LeafCore public: +3 tests (PT-1..PT-3)
- LeafCorePrivate moat: +6 tests (MT-1..MT-6 — formerly T4-T9, renamed for slug clarity)
- Sentinel test: +1 (`test_t7_walkback_anchorDocPathBasenameOnlyDoesNotLeakAbsolutePath`)
- **Total: +10 net new tests** vs T6 baseline 2984 → target **≈ 2994 SPM tests** post-T7.

---

## §6 Acceptance gates (Stage 7 verification)

**AC-1** All 5/5 xcodebuild schemes Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).

**AC-2** SPM tests: ≥ 2994 total, 0 failures, ≤ 4 skipped.

**AC-3** `just check-tokens` 3-tier clean.

**AC-4** Substrate purity: `git diff feature/track-9-substrate~N..HEAD -- Packages/LeafCore/Sources/LeafCore/DB/` empty (NO M028).

**AC-5** Registry frozen: `git diff feature/track-9-substrate~N..HEAD -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` empty.

**AC-6** No new MCP tools: `git diff feature/track-9-substrate~N..HEAD -- LeafMCP/` empty.

**AC-7** Privacy walkback narrow grep on T7 file scope — 0 hits forbidden fields:
```
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|prompt|tool_input|tool_response|response_body|email_subject|note_body|file_contents" \
  Packages/LeafCore/Sources/LeafCore/Home/WorkState/WhereStoppedSnapshot.swift \
  Leaf/Models/InsightsReader.swift \
  Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift
# Expected: 0 hits
# NOTE: InsightsSnapshot.swift NOT in scope — T7 does not touch that file
# per §3.3 Path B lock (composition stays in InsightsReader).
```

**AC-8** WhereStoppedBlock.swift LOC ≤ 160 (Phase 8.7 ship was 98, T7 adds ~50-60 LOC for 4-line layout + helpers). HomeView.swift LOC unchanged.

**AC-9** Sentinel-injection regression test passes (`test_t7_walkback_anchorDocPathBasenameOnlyDoesNotLeakAbsolutePath`).

**AC-10** Master spec §9.1 inline status markers updated at Stage 8 ship: C-20 / C-21 each annotated `[RESOLVED T7 — commit <sha>]`.

**AC-11** Manual UI smoke (per L decision lock — bundled with Stage 8 ship workflow):
- Switch to `fix/dev-launch-reliability`, merge T7 work, rebuild, launch via direct-exec
- WHERE STOPPED card shows 4 lines when anchor event is Xcode (path:line + commit + chips)
- Falls back to 3 lines when anchor is VSCode/JetBrains (path-only)
- Falls back to 2 lines when anchor is commit/ticket event (excerpt + chips)
- Falls back to empty state when no where_stopped_log rows
- WIP chips visually distinct from text-join — verify LeafPill capsule rendering
- Line 3 commit subject truncates at 60 chars with ellipsis

---

## §7 Master spec §9.1 carry-over status markers

T7 ship commit message + master spec inline edits:

```
docs(track-9-T7): SHIPPED — master spec §9.1 status markers

C-20 Line 2 last-commit subject deriver wired
  → [RESOLVED T7 — commit <C20-sha>]
C-21 anchorEventId → file path:line resolution + WIP chip styling
  → [RESOLVED T7 — commit <C21-sha>]
```

Per T6 precedent (§9.1 lines 389-391), markers placed inline at carry text.

---

## §8 Out of scope / hard exclusion (formal contract anchor)

T7 **does not** add / change / touch:

- **Event_kinds** — registry frozen at 198. Existing kinds consumed only.
- **SQLCipher tables / migrations** — M001-M018 + M024 + M026 + M027 preserved. **No M028.**
- **MCP tools** — 15-tool inventory unchanged.
- **ShareEventTypeKey** — registry frozen; no new entries.
- **`presence_state` writes** — T7 is read-only.
- **VSCode/JetBrains line capture** — path-only fallback ships; per-file line = post-Track-9 IDE family enrichment.
- **Multi-anchor diff annotation** — single anchor only.
- **Stale-anchor UX nag** — silent fallback when LEFT JOIN yields NULL.
- **Resume CTA on Line 2** — informational only.
- **WIP signal tone iteration palette polish** — 3-tone mapping enough.
- **`InsightsSnapshot.recentLastCommit` field** — per §3.3 lock, dropped per YAGNI; stored only on `WhereStoppedSnapshot`.
- **Localization / i18n** — Track-9 carries this (master spec §9.1 C-19).
- **Per-row swipe actions / mark-as-read** — Phase 8.7 + Track-8 out-of-scope holds.

---

## §9 Open implementation calls (resolved at spec gate, locked for plan)

| # | Decision | Locked call |
|---|----------|-------------|
| A | WhereStoppedSnapshot field additions | 3 Optional fields (`anchorFilePath`, `anchorLine`, `recentLastCommit`), all defaulted-nil |
| B | Anchor resolution path | Deriver-side LEFT JOIN at recentWhereStopped read; basename extraction post-fetch in Swift; VSCode/JetBrains path-only fallback |
| C | recentLastCommit cutoff | 4 hours = `4 * 60 * 60 * 1000` ms (master spec §T7 lock) |
| D | Line 2 display format | `"\(filename):\(line)"` when both present; `filename` when path-only; excerpt fallback when no anchor |
| E | InsightsReader fetch | 20th sequential SQL call between Phase 8.7's whereStopped fetch and InsightsSnapshot init |
| F | WIP chip styling | LeafPill reuse with 3-tone mapping (commitWip→warning, midEdit→accent, unknown→neutral) |
| G | Filename extraction | Path basename only via NSString lastPathComponent |
| H | InsightsSnapshot.recentLastCommit field | DROPPED per YAGNI — stored only on WhereStoppedSnapshot |
| I | M028 migration | SKIP (substrate-purity invariant preserved) |
| J | Sentinel-injection regression test | REQUIRED (new privacy surface reading doc_path) |
| K | Line 3 60-char cap | Trim + truncate + ellipsis applied in `commitSubjectLine`; defensive `.lineLimit(1)` |
| L | Stage 8 testing workflow | Bake into plan — merge `feature/track-9-substrate` → `fix/dev-launch-reliability` + rebuild + direct-exec launch per T6 proven workflow |

12 implementation calls locked at this spec. Plan (Stage 4) consumes these; implementation (Stage 5) executes literally.

---

## §10 Phase summary

T7 closes Track-9 WHERE STOPPED scope:

- **C-20 Line 3 last-commit subject** — wired existing T1 `recentLastCommit` deriver into InsightsReader → WhereStoppedSnapshot → 4-line UI
- **C-21 anchor file:line resolution** — Optional fields populated via deriver-side LEFT JOIN; basename + line render on Line 2; graceful 3-line / 2-line / empty fallbacks
- **C-21 WIP chip styling** — LeafPill reuse with semantic tone mapping

Zero substrate (registry / migrations / event_kinds / MCP tools). Builds on T1-T6 patterns. First Track-9 phase to read structured payload field (doc_path) — sentinel-injection regression test mandatory.

Stage 8 testing workflow baked into plan per user explicit ask: merge into `fix/dev-launch-reliability` + rebuild + direct-exec launch from latest DerivedData (T6 proven workflow 2026-05-21).

Next phase: T8 (INBOX full feeder expansion + universal sourceURL synthesis) per master spec §T8 (line 207-213).
