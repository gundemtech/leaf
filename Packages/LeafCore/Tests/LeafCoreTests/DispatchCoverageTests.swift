// Phase Track-3 D2 — §9 dispatcher coverage fence.
//
// Single anti-drift gate enforcing that every `GitHubEventKindKey` case is
// mirrored across the four downstream surfaces:
//
//   1. ShareEventTypeRegistry  (`ShareEventTypeKey.allCases`)
//   2. M016 rename map         (only the legacyRenamed subset)
//   3. EventsFullTextStore     (only the bodyBearing subset)
//   4. ShareEventTypeDefaults  (`ShareEventTypeDefaults.all`)
//
// When a future task adds a new GitHub event_kind it must be propagated to all
// four sites or this test breaks loudly. Discussion (`gh_discussion_*`) is
// intentionally excluded from `bodyBearing` per ADR-010 §6 — see comment on
// `GitHubEventKindKey.bodyBearing`.

import XCTest
@testable import LeafCore

final class DispatchCoverageTests: XCTestCase {

    /// #1 — every enum case has a matching ShareEventTypeRegistry entry by rawValue.
    func testEveryGitHubEventKindKeyAppearsInShareEventTypeRegistry() {
        let registry = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        for kind in GitHubEventKindKey.allCases {
            XCTAssertTrue(
                registry.contains(kind.rawValue),
                "ShareEventTypeKey missing entry for \(kind.rawValue)"
            )
        }
    }

    /// #2 — M016 rename map's `new` targets exactly equal `legacyRenamed` rawValues.
    /// Two-direction equality: every legacy entry has a rename target, every rename
    /// target maps to a current enum case in the legacyRenamed subset.
    func testLegacyRenamedMatchesM016RenameMap() {
        let renameMapNewKinds = Set(M016NormalizeGitHubEventKinds.renameMap.map { $0.new })
        let enumLegacyRawValues = Set(GitHubEventKindKey.legacyRenamed.map { $0.rawValue })
        XCTAssertEqual(
            renameMapNewKinds,
            enumLegacyRawValues,
            "M016 renameMap targets must exactly match GitHubEventKindKey.legacyRenamed rawValues"
        )
    }

    /// #3 — every body-bearing case has a body-kind dispatch entry in
    /// `EventsFullTextStore.topLevelBodyKind`. Test routes via the
    /// `bodyKindForTesting` shim (mirrors private logic).
    func testEveryBodyBearingKindHasFTSDispatchEntry() {
        for kind in GitHubEventKindKey.bodyBearing {
            let bodyKind = EventsFullTextStore.bodyKindForTesting(eventKind: kind.rawValue)
            XCTAssertNotNil(
                bodyKind,
                "Body-bearing event_kind \(kind.rawValue) must have a body-kind dispatch entry"
            )
        }
    }

    /// #4 — every enum case has a `ShareEventTypeDefault` entry. Defaults table is
    /// the onboarding preset source; missing entry would silently default to OFF.
    func testEveryGitHubEventKindKeyHasShareDefaultEntry() {
        let defaults = Dictionary(
            uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key.rawValue, $0.defaultEnabled) }
        )
        for kind in GitHubEventKindKey.allCases {
            XCTAssertNotNil(
                defaults[kind.rawValue],
                "ShareEventTypeDefaults missing entry for \(kind.rawValue)"
            )
        }
    }

    // MARK: - Slack mirror (Phase Track-3 D3)
    //
    // Same four-corner fence applied to `SlackEventKindKey`. When a future
    // task adds a Slack event_kind it must be propagated to all four sites or
    // these tests break loudly. Body-bearing subset is intentionally narrow
    // per ADR-010 §6 — only user-named structured resources (canvas + bookmark
    // titles) are body-bearing; message text / file content / reminder text /
    // preview / scheduled-message text are dropped at provider boundary.

    /// #5 — every Slack enum case has a matching ShareEventTypeRegistry entry by rawValue.
    func testEverySlackEventKindKeyAppearsInShareEventTypeRegistry() {
        let registry = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        for kind in SlackEventKindKey.allCases {
            XCTAssertTrue(
                registry.contains(kind.rawValue),
                "ShareEventTypeKey missing entry for \(kind.rawValue)"
            )
        }
    }

    /// #6 — M017 rename map's `new` targets exactly equal `legacyRenamed` rawValues.
    /// Two-direction equality: every legacy entry has a rename target, every rename
    /// target maps to a current enum case in the legacyRenamed subset.
    func testSlackLegacyRenamedMatchesM017RenameMap() {
        let renameMapNewKinds = Set(M017NormalizeSlackEventKinds.renameMap.map { $0.new })
        let enumLegacyRawValues = Set(SlackEventKindKey.legacyRenamed.map { $0.rawValue })
        XCTAssertEqual(
            renameMapNewKinds,
            enumLegacyRawValues,
            "M017 renameMap targets must exactly match SlackEventKindKey.legacyRenamed rawValues"
        )
    }

    /// #7 — every Slack body-bearing case has a body-kind dispatch entry in
    /// `EventsFullTextStore.topLevelBodyKind`. Test routes via the
    /// `bodyKindForTesting` shim (mirrors private logic).
    func testEverySlackBodyBearingKindHasFTSDispatchEntry() {
        for kind in SlackEventKindKey.bodyBearing {
            let bodyKind = EventsFullTextStore.bodyKindForTesting(eventKind: kind.rawValue)
            XCTAssertNotNil(
                bodyKind,
                "Body-bearing Slack event_kind \(kind.rawValue) must have a body-kind dispatch entry"
            )
        }
    }

    /// #8 — every Slack enum case has a `ShareEventTypeDefault` entry. Defaults
    /// table is the onboarding preset source; missing entry would silently
    /// default to OFF.
    func testEverySlackEventKindKeyHasShareDefaultEntry() {
        let defaults = Dictionary(
            uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key.rawValue, $0.defaultEnabled) }
        )
        for kind in SlackEventKindKey.allCases {
            XCTAssertNotNil(
                defaults[kind.rawValue],
                "ShareEventTypeDefaults missing entry for \(kind.rawValue)"
            )
        }
    }

    /// #9 — every GitHub body-bearing case has a body-kind dispatch entry in
    /// `EventLinksStore.topLevelBodyKind`. Parallels test #3 (FTS). Test routes
    /// via the `bodyKindForTesting` shim (mirrors private logic).
    func testEveryGitHubBodyBearingKindHasEventLinksDispatchEntry() {
        for kind in GitHubEventKindKey.bodyBearing {
            let bodyKind = EventLinksStore.bodyKindForTesting(eventKind: kind.rawValue)
            XCTAssertNotNil(
                bodyKind,
                "Body-bearing GitHub event_kind \(kind.rawValue) must have an EventLinksStore dispatch entry"
            )
        }
    }

    /// #10 — every Slack body-bearing case has a body-kind dispatch entry in
    /// `EventLinksStore.topLevelBodyKind`. Parallels test #7 (FTS).
    func testEverySlackBodyBearingKindHasEventLinksDispatchEntry() {
        for kind in SlackEventKindKey.bodyBearing {
            let bodyKind = EventLinksStore.bodyKindForTesting(eventKind: kind.rawValue)
            XCTAssertNotNil(
                bodyKind,
                "Body-bearing Slack event_kind \(kind.rawValue) must have an EventLinksStore dispatch entry"
            )
        }
    }

    /// #11 — non-body-bearing `gh_pr_*` event_kinds must return nil from
    /// `EventLinksStore.topLevelBodyKind`. Guards against re-introduction of
    /// the `hasPrefix("gh_pr_")` catch-all that would route these through
    /// `Schema.BodyKinds.ghPR` and attempt body indexing on empty fields.
    func testNonBodyBearingGitHubPRKindsReturnNilFromEventLinks() {
        let nonBodyBearing = [
            GitHubEventKindKey.prReviewThreadResolved.rawValue,
            GitHubEventKindKey.prAwaitingReviewCount.rawValue
        ]
        for raw in nonBodyBearing {
            XCTAssertNil(
                EventLinksStore.bodyKindForTesting(eventKind: raw),
                "EventLinksStore must NOT dispatch a body-kind for non-body-bearing \(raw)"
            )
        }
    }

    /// #12 — every GitHub body-bearing case has a body-kind dispatch entry in
    /// `DetectorPipeline.topLevelBodyKind`. Parallels test #3 (FTS) + #9
    /// (EventLinks). Test routes via the `bodyKindForTesting` shim.
    func testEveryGitHubBodyBearingKindHasDetectorPipelineDispatchEntry() {
        for kind in GitHubEventKindKey.bodyBearing {
            let bodyKind = DetectorPipeline.bodyKindForTesting(eventKind: kind.rawValue)
            XCTAssertNotNil(
                bodyKind,
                "Body-bearing GitHub event_kind \(kind.rawValue) must have a DetectorPipeline dispatch entry"
            )
        }
    }

    /// #13 — every Slack body-bearing case has a body-kind dispatch entry in
    /// `DetectorPipeline.topLevelBodyKind`. Parallels test #7 (FTS) + #10
    /// (EventLinks). Defense-in-depth fence — currently passes since D3 wired
    /// canvas + bookmark dispatch into DetectorPipeline; this guards against
    /// future drift if a new Slack body-bearing case is added without updating
    /// the Detector dispatcher.
    func testEverySlackBodyBearingKindHasDetectorPipelineDispatchEntry() {
        for kind in SlackEventKindKey.bodyBearing {
            let bodyKind = DetectorPipeline.bodyKindForTesting(eventKind: kind.rawValue)
            XCTAssertNotNil(
                bodyKind,
                "Body-bearing Slack event_kind \(kind.rawValue) must have a DetectorPipeline dispatch entry"
            )
        }
    }

    /// #14 — non-body-bearing `gh_pr_*` event_kinds must return nil from
    /// `DetectorPipeline.topLevelBodyKind`. Parallels test #11 (EventLinks).
    /// Guards against re-introduction of the `hasPrefix("gh_pr_")` catch-all.
    func testNonBodyBearingGitHubPRKindsReturnNilFromDetectorPipeline() {
        let nonBodyBearing = [
            GitHubEventKindKey.prReviewThreadResolved.rawValue,
            GitHubEventKindKey.prAwaitingReviewCount.rawValue
        ]
        for raw in nonBodyBearing {
            XCTAssertNil(
                DetectorPipeline.bodyKindForTesting(eventKind: raw),
                "DetectorPipeline must NOT dispatch a body-kind for non-body-bearing \(raw)"
            )
        }
    }

    /// #15 — Track-4 S4 user-authored title/filename event_kinds must round-trip
    /// through `EventsFullTextStore.topLevelBodyKind` to their respective
    /// `Schema.BodyKinds` entries. These kinds carry searchable content in
    /// non-canonical payload keys (`note_title`, `meeting_topic`, `filename`);
    /// dispatcher is the single point of payload-key resolution.
    func testTrackFourBodyKindsRoutedViaDispatcher() {
        let trackFourBodyBearing: [(eventKind: String, expectedBodyKind: String)] = [
            ("notes_active_title_changed", Schema.BodyKinds.notesTitle),
            ("zoom_meeting_name_observed", Schema.BodyKinds.zoomMeetingName),
            ("screenshot_taken", Schema.BodyKinds.screenshotFilename),
            ("download_added", Schema.BodyKinds.downloadFilename),
        ]
        for (eventKind, expected) in trackFourBodyBearing {
            XCTAssertEqual(
                EventsFullTextStore.bodyKindForTesting(eventKind: eventKind),
                expected,
                "EventsFullTextStore must route \(eventKind) → \(expected)"
            )
        }
    }

    // MARK: - Track-6 P6 Activity-tab visibility fence
    //
    // `ActivityFeedMapper.trackFourLocalOSKinds` is the canonical whitelist of
    // local-OS event_kinds that render rows in the Activity tab. Every kind in
    // that set must have a matching `ShareEventTypeKey` entry so Share Controls
    // can gate its emission.
    //
    // `ide_window_title_observed` is registered in ShareEventTypeKey (Task 8)
    // but is intentionally excluded from `trackFourLocalOSKinds` — it is a
    // debug-only signal that never renders in the Activity tab.

    /// #16 — every kind in `ActivityFeedMapper.trackFourLocalOSKinds` must have
    /// a matching `ShareEventTypeKey` entry. Auto-derived from the whitelist, so
    /// additions to `trackFourLocalOSKinds` (e.g. Track-6 P6 vscode/jetbrains
    /// kinds) are automatically covered without updating this test.
    func testTrackFourLocalOSKindsAllRegisteredInShareEventTypeKey() {
        let registry = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        for kind in ActivityFeedMapper.trackFourLocalOSKinds {
            XCTAssertTrue(
                registry.contains(kind),
                "ShareEventTypeKey missing entry for Activity-tab-visible kind \(kind)"
            )
        }
    }
}
