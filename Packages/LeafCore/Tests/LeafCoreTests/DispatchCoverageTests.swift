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

    /// #16 — Track-6 P3 browser deep event_kinds (8) must all appear in
    /// `ActivityFeedMapper.trackFourLocalOSKinds` and produce a non-nil feed
    /// entry when routed through `ActivityFeedMapper.map`. Guards against
    /// accidentally dropping a kind from the whitelist set or the switch arms.
    func testTrackSixP3BrowserKindsHandledByActivityFeedMapper() {
        let p3EventKinds: [(kind: String, payload: [String: String])] = [
            ("safari_tab_navigated",  ["event_kind": "safari_tab_navigated",  "current_url": "https://example.com"]),
            ("chrome_tab_navigated",  ["event_kind": "chrome_tab_navigated",  "current_url": "https://example.com"]),
            ("arc_tab_navigated",     ["event_kind": "arc_tab_navigated",     "current_url": "https://example.com"]),
            ("safari_tab_activated",  ["event_kind": "safari_tab_activated",  "current_url": "https://example.com"]),
            ("chrome_tab_activated",  ["event_kind": "chrome_tab_activated",  "current_url": "https://example.com"]),
            ("arc_tab_activated",     ["event_kind": "arc_tab_activated",     "current_url": "https://example.com"]),
            ("chrome_bookmark_changed", ["event_kind": "chrome_bookmark_changed", "delta": "1", "total_count": "42"]),
            ("safari_bookmark_changed", ["event_kind": "safari_bookmark_changed", "delta": "-1", "total_count": "10"]),
        ]
        for (kind, payload) in p3EventKinds {
            // a) Membership in whitelist set.
            XCTAssertTrue(
                ActivityFeedMapper.trackFourLocalOSKinds.contains(kind),
                "trackFourLocalOSKinds must contain \(kind)"
            )
            // b) map() produces non-nil (switch arm exercised).
            let payloadJSON = encodePayload(payload)
            let entry = ActivityFeedMapper.map(
                id: 1,
                timestampMs: 1_000_000,
                signalType: "attention",
                bundleID: nil,
                payloadJSON: payloadJSON
            )
            XCTAssertNotNil(entry, "ActivityFeedMapper.map must return non-nil for \(kind)")
        }
    }

    /// Helper — encode a flat [String:String] dict as a compact JSON string
    /// suitable for `ActivityFeedMapper.map(payloadJSON:)`.
    private func encodePayload(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
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

    // MARK: - Track-6 P1 — Claude Code coverage

    /// #16 — every `ClaudeCodeEventKindKey` case has a `ShareEventTypeKey` entry.
    func testEveryClaudeCodeEventKindKeyAppearsInShareEventTypeRegistry() {
        let registry = Set(ShareEventTypeKey.allCases.map { $0.rawValue })
        for kind in ClaudeCodeEventKindKey.allCases {
            XCTAssertTrue(
                registry.contains(kind.rawValue),
                "ShareEventTypeKey missing entry for \(kind.rawValue)"
            )
        }
    }

    /// #17 — every `ClaudeCodeEventKindKey` case is either visible or skipped.
    func testEveryClaudeCodeEventKindKeyMappedOrSkipped() {
        let visible = ActivityFeedMapper.claudeCodeAIKinds
        let skipped = ActivityFeedMapper.skippedKinds
        for kind in ClaudeCodeEventKindKey.allCases {
            let rv = kind.rawValue
            XCTAssertTrue(
                visible.contains(rv) || skipped.contains(rv),
                "ClaudeCodeEventKindKey.\(kind) — neither in claudeCodeAIKinds nor skippedKinds"
            )
        }
    }

    /// #18 — every `ClaudeCodeEventKindKey` has a default-OFF entry.
    func testEveryClaudeCodeEventKindKeyHasDefaultEntryOff() {
        let defaults = Dictionary(
            uniqueKeysWithValues: ShareEventTypeDefaults.all.map { ($0.key.rawValue, $0.defaultEnabled) }
        )
        for kind in ClaudeCodeEventKindKey.allCases {
            XCTAssertNotNil(
                defaults[kind.rawValue],
                "ShareEventTypeDefaults missing entry for \(kind.rawValue)"
            )
            XCTAssertEqual(
                defaults[kind.rawValue], false,
                "\(kind.rawValue) must default OFF per Track-6 P1 contract §2.5"
            )
        }
    }

    // MARK: - Track-6 P4 — Google Calendar coverage

    /// #19 — Track-6 P4 Google Calendar parity fence. Every
    /// `GoogleCalendarEventKind.allCases.rawValue` is either handled by
    /// `ActivityFeedMapper.mapGoogleCalendar` or explicitly skipped.
    func testEveryGoogleCalendarEventKindKeyMappedOrSkipped() {
        for kind in GoogleCalendarEventKind.allCases {
            if ActivityFeedMapper.skippedKinds.contains(kind.rawValue) {
                continue
            }
            let payload = #"{"source":"google_calendar","event_kind":"\#(kind.rawValue)"}"#
            let entry = ActivityFeedMapper.map(
                id: 1,
                timestampMs: 1_700_000_000_000,
                signalType: "context",
                bundleID: nil,
                payloadJSON: payload
            )
            XCTAssertNotNil(
                entry,
                "ActivityFeedMapper.mapGoogleCalendar must handle \(kind.rawValue) or skippedKinds must include it"
            )
            XCTAssertEqual(
                entry?.provider,
                .googleCalendar,
                "ActivityFeedMapper.mapGoogleCalendar must return provider=.googleCalendar for \(kind.rawValue)"
            )
            XCTAssertEqual(
                entry?.eventKind,
                kind.rawValue,
                "ActivityFeedEntry.eventKind must round-trip for \(kind.rawValue)"
            )
        }
    }
}
