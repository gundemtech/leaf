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
}
