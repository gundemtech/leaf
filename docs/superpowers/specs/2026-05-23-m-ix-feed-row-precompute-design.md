# M-IX — Precompute `LeafFeedRow` action text in the feed mapping layer

_Optimization Tier M, row M-IX. Branch `perf/m-ix-feed-row-precompute` off `feature/invite-redesign`. Contract: `.claude/plans/optimization-tier-m.md` row M-IX._

## Problem

`LeafFeedRow.body` (single-row variant) calls `actionText(for: row)` → `parsePayload(row.plaintextPayloadJSON)`, which runs `JSONSerialization.jsonObject` + dictionary allocation + a `switch` over `ShareSource` to build a display string. This happens on **every `body` re-evaluation**:

- every scroll-recycle of a row in the `LazyVStack`,
- every `@Observable` invalidation of `TeamFeedReader.state` (Realtime push churn re-renders the whole feed),
- once **per expanded grouped child** (each expanded child renders its own `LeafFeedRow`, each re-parsing its own payload).

The parse cost is pure waste: the payload JSON for a given event never changes after it is fetched, so the derived `actionText` is a deterministic function of `(row.source, row.plaintextPayloadJSON)`. It should be computed once when the feed item is built, not per render.

`actionText(for:)` and `parsePayload(_:)` are currently file-private functions in the app target (`Leaf/Theme/Layouts/LeafFeedRow.swift`). Their only inputs are `ShareSource` (LeafCore) and the payload JSON string — so the derivation can move down into LeafCore with zero new dependencies.

### Out of scope (deliberately)

- **Relative timestamps** (`relativeTimestamp`, `timelineSpan`) — these are relative to *now* ("5m ago") and must re-evaluate on each render; precomputing them would freeze stale strings. They already reuse a file-level hoisted `RelativeDateTimeFormatter` (Tier S). Left unchanged.
- **`groupedActionText(source:count:)`** — count-based, no JSON parse. Cheap. Left in the view.
- **`sourceKindSymbol` / `senderDisplayName`** — trivial switch / `prefix(8)`. No JSON. Left in the view.

## Constraint that shapes the design

`TeamEventMirrorRow` is constructed in ~21 sites (6 production: `TeamFeedQueryService`, `TeamTimelineQueryService`, `TeamEventMirrorService`, `TeamEventMirrorStore`, `LeafRealtimeService`; 1 preview; ~14 tests) and is shared by the timeline, mirror store, retention pruner, and Realtime ingest — not just the Team feed. Adding a presentation string field directly to it would (a) pollute a shared data model with a feed-only concern, (b) leave a dead/empty field on every non-feed consumer, and (c) churn all 21 constructors. **Rejected.**

Instead, a dedicated presentation carrier type holds the precomputed string, and the data model `TeamEventMirrorRow` is untouched.

## Design

### New LeafCore types (2 new files)

**`Packages/LeafCore/Sources/LeafCore/Team/TeamEventActionText.swift`** — the parse + derive logic, moved verbatim from the view:

```swift
public enum TeamEventActionText {
  /// Best-effort action text for a single team-event row.
  /// ADR-010 discipline: only allow-listed payload keys are read
  /// (title, *_excerpt). Never reads AI-related fields or PII.
  public static func make(for row: TeamEventMirrorRow) -> String { … }
}
```

The file-private `parsePayload(_ json: String) -> [String: Any]` helper moves into this file unchanged (best-effort `JSONSerialization`, returns `[:]` on failure). The `switch row.source` body is the exact 9-case logic currently in `actionText(for:)` — copied verbatim, no behavioral change.

**`Packages/LeafCore/Sources/LeafCore/Team/RenderedTeamEvent.swift`** — the presentation carrier:

```swift
public struct RenderedTeamEvent: Identifiable, Equatable, Sendable {
  public let row: TeamEventMirrorRow
  public let actionText: String

  public var id: String { row.eventID }

  /// Single designated init — precomputes `actionText` from `row`.
  /// There is no way to construct a RenderedTeamEvent without the derived
  /// string, so no stale/empty action-text path can exist.
  public init(row: TeamEventMirrorRow) {
    self.row = row
    self.actionText = TeamEventActionText.make(for: row)
  }
}
```

`Equatable` is auto-synthesized; `actionText` is redundant in equality (derived from `row`) but harmless. `Sendable` + `Equatable` are required because `FeedItem` is `Sendable` + `Equatable`.

### `FeedItem` reshape

`Packages/LeafCore/Sources/LeafCore/Team/TeamFeedItem.swift`:

```swift
case directMessage(DirectMessageMirrorRow)   // unchanged
case teamEvent(RenderedTeamEvent)            // was: TeamEventMirrorRow
case grouped(
  kind: String,
  sender: TeamMember,
  count: Int,
  spanStartMs: Int64,
  spanEndMs: Int64,
  items: [RenderedTeamEvent]                 // was: [TeamEventMirrorRow]
)
```

Accessor updates:
- `id`: `.teamEvent(let r)` → `r.row.eventID` (was `row.eventID`). `.grouped` unchanged (keys off `kind`/`sender`/`spanStartMs`).
- `timestamp`: `.teamEvent(let r)` → `r.row.serverCreatedAtMs`. `.grouped` unchanged (`spanEndMs`).

### Single precompute point

`Packages/LeafCore/Sources/LeafCore/Team/TeamFeedQueryService.swift:207`, in `mapRow`:

```swift
case "evt":
  return mapEventRow(row).map { .teamEvent(RenderedTeamEvent(row: $0)) }
```

This is the **only** site in production where `FeedItem.teamEvent` is constructed from DB data. All feed entry points — `loadInitial`, `refresh`, `loadOlder` — call `queryService.fetch` which routes through `mapRow`. Realtime push does not inject `FeedItem` directly; it writes to the mirror store and triggers a re-fetch through the same query path. So this one site covers every path.

### `TeamFeedReader.applyGrouping`

`Packages/LeafCore/Sources/LeafCore/State/TeamFeedReader.swift`. Public signature `applyGrouping(_ items: [FeedItem]) -> [FeedItem]` is **unchanged**. Internals:

- `burst: [TeamEventMirrorRow]` → `burst: [RenderedTeamEvent]`.
- Field paths gain `.row.`: `head.row.kind`, `head.row.senderPubkeyHex`, `row.row.eventTsMs` (the loop binding becomes `case .teamEvent(let rendered)`), `memberResolver(oldest.row.senderPubkeyHex)`.
- Flush emits `.teamEvent($0)` where `$0` is already a `RenderedTeamEvent` (no re-derivation), and `.grouped(kind: oldest.row.kind, …, items: burst)`.

Grouping only reorganizes already-rendered values; it never parses payload.

### View becomes a pure renderer

`Leaf/Theme/Layouts/LeafFeedRow.swift`:

- Stored property `row: TeamEventMirrorRow` → `event: RenderedTeamEvent`. Init parameter renamed `row:` → `event:`.
- `body` reads `event.actionText` directly (was `actionText(for: row)`). Cheap fields read through `.row`: `sourceKindSymbol(event.row.source)`, `senderDisplayName(event.row.senderPubkeyHex)`, `relativeTimestamp(event.row.eventTsMs)`.
- `actionText(for:)` and `parsePayload(_:)` are **deleted** (moved to `TeamEventActionText`).
- `groupedActionText`, `sourceKindSymbol`, `senderDisplayName`, `timelineSpan`, `relativeTimestamp`, `abbreviatedRelativeFormatter` **stay** unchanged.
- `static func grouped(… expandedItems: [TeamEventMirrorRow] …)` → `expandedItems: [RenderedTeamEvent]`. Expanded children render `LeafFeedRow(event: item, attachmentMetadata: nil, onTap: {})`; `ForEach(expandedItems, id: \.row.eventID)` (or `ForEach(expandedItems)` since `RenderedTeamEvent: Identifiable`).

`Leaf/Views/Window/Team/TeamView.swift`:

- `teamEventRow(row: TeamEventMirrorRow)` → `teamEventRow(event: RenderedTeamEvent)`, body `LeafFeedRow(event: event, …)`.
- `cardView` `.teamEvent(let row)` → `.teamEvent(let event)` → `teamEventRow(event: event)`.
- `cardView` `.grouped(… let expandedItems)` — `expandedItems` is now `[RenderedTeamEvent]`; threaded into `groupedRow(items: [RenderedTeamEvent])` → `LeafFeedRow.grouped(… expandedItems: items)`.

`Leaf/Views/Tokens/Components/LeafFeedRowPreview.swift` — preview-only; wrap sample `TeamEventMirrorRow` values in `RenderedTeamEvent(row:)` for both `LeafFeedRow(event:)` and `LeafFeedRow.grouped(expandedItems:)`.

## Behavior preservation

The derived strings are byte-identical to today's output: `TeamEventActionText.make` is the verbatim move of `actionText(for:)`, and `parsePayload` is unchanged. No user-visible string changes. The only difference is *when* the parse runs (once at fetch vs. per render).

## ADR-010 / privacy

The parse remains allow-list-only (reads `title`, `reasoning_excerpt`, `blocker_excerpt`, `question_excerpt`, `excerpt` — each capped at 50 chars for excerpts). Moving the function does not widen what is read. The precomputed `actionText` is a derived display string built from the same allow-listed keys; it is never persisted (lives only on the in-memory `RenderedTeamEvent`), never logged, and never written back to the DB or the relay.

## Testing

New tests (LeafCore):

- **`TeamEventActionTextTests`** — one assertion per `ShareSource` case with a populated payload (verifies the templated string), plus the empty-payload fallback for each case that has one. Plus an ADR-010 assertion: a payload carrying forbidden keys (`body`, `ai_prompt`, a large `file_size` sentinel) produces an action text containing none of those values.
- **`RenderedTeamEventTests`** — `init(row:)` populates `actionText` equal to `TeamEventActionText.make(for: row)`; `id == row.eventID`; `Equatable` holds for equal rows.

Updated tests (mechanical reshape to `.teamEvent(RenderedTeamEvent(row:))` and `.row.` field access where they pattern-match):

- `TeamFeedReaderBusinessTests` (applyGrouping inputs/assertions, grouped `items` element access).
- `TeamFeedItemTests` (id / timestamp / Equatable across cases).
- `TeamFeedPayloadLeakageTests` (FeedItem construction; the leakage walkbacks must also confirm `actionText` carries no forbidden values).
- `TeamFeedQueryServiceTests` (mapped `.teamEvent` element access).

## Acceptance criteria

1. `swift test --package-path Packages/LeafCore` green, 0 failures: capture the count on `perf/m-ix-feed-row-precompute` before any change as the baseline, then confirm the new `TeamEventActionTextTests` / `RenderedTeamEventTests` add to it with no pre-existing test lost.
2. `xcodebuild` 5/5 schemes build green (the app target consumes the reshaped `FeedItem`).
3. No production site other than `TeamFeedQueryService.mapRow:207` constructs `RenderedTeamEvent` from DB data (single precompute point).
4. `grep` confirms `parsePayload` / `JSONSerialization` no longer appear in `LeafFeedRow.swift`.
5. `TeamEventMirrorRow`'s definition and its 21 construction sites are unchanged (no field added).
6. Manual smoke: Team feed renders identical action text for single rows and expanded grouped children; scroll a long feed and expand a group — no visual diff vs. pre-change.
7. `/pre-push-leaf` clean before push.

## Files touched

New: `Team/TeamEventActionText.swift`, `Team/RenderedTeamEvent.swift` (+ 2 test files).
Modified: `Team/TeamFeedItem.swift`, `Team/TeamFeedQueryService.swift`, `State/TeamFeedReader.swift`, `Theme/Layouts/LeafFeedRow.swift`, `Views/Window/Team/TeamView.swift`, `Views/Tokens/Components/LeafFeedRowPreview.swift` (+ 4 test files updated).
Untouched: `Team/TeamEvent.swift` (`TeamEventMirrorRow`), all non-feed consumers.
