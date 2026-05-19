//
//  QueryTeamPayloadFilterTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T7 — Tests for the second-layer per-source allowlist
//  filter that the `leaf_query_team` MCP tool (LeafMCP/Tools/QueryTeamTool.swift)
//  applies before returning a teammate timeline to the AI client.
//
//  These tests are the SPM-testable surface for QueryTeamTool's behavior —
//  the tool itself is in LeafMCP (Xcode target, outside `swift test`), so
//  per the precedent set by `D3ToolParams` / `D3ToolSchemas` (consumed by
//  `QueryActivityTool`), the heavy filter logic lives in LeafCore and is
//  covered here. xcodebuild covers the thin tool wrapper at build time;
//  this suite covers the privacy-load-bearing static helper at runtime.
//

import XCTest
@testable import LeafCore

final class QueryTeamPayloadFilterTests: XCTestCase {

    // MARK: - Allowlist parity per source

    func testFilter_GitCommits_KeepsAllowedKeys() {
        let payload: [String: AnyJSONValue] = [
            "commit_sha": .string("abc"),
            "repo_full_name": .string("foo/bar"),
            "branch": .string("main"),
            "commit_message_subject": .string("fix typo"),
            "files_changed_count": .int(3)
        ]
        let filtered = QueryTeamPayloadFilter.filter(
            payload, sourceKind: ShareSource.gitCommits.rawValue
        )
        XCTAssertEqual(filtered.count, 5)
        XCTAssertEqual(filtered["commit_sha"], .string("abc"))
        XCTAssertEqual(filtered["files_changed_count"], .int(3))
    }

    func testFilter_LinearIssues_KeepsAllowedKeys() {
        let payload: [String: AnyJSONValue] = [
            "issue_id": .string("123"),
            "issue_identifier": .string("LEAF-42"),
            "issue_title_excerpt": .string("Add feature"),
            "issue_state_type": .string("in_progress"),
            "team_key": .string("LEAF"),
            "priority": .int(2),
            "label_id": .string("l1"),
            "label_name": .string("bug"),
            "assignee_bucket": .string("self"),
            "cycle_id": .string("c1"),
            "estimate_points": .int(5)
        ]
        let filtered = QueryTeamPayloadFilter.filter(
            payload, sourceKind: ShareSource.linearIssues.rawValue
        )
        XCTAssertEqual(filtered.count, 11)
    }

    func testFilter_AllNineSources_MirrorsBuilderAllowlistExactly() {
        // For each ShareSource, take the entire allowlist from the broadcast
        // layer + a couple of banned keys; the filter must return exactly
        // the allowed keys (zero drift between layers).
        for source in ShareSource.allCases {
            let allowed = TeamEventPayloadBuilder.allowedKeys(for: source)
            var payload: [String: AnyJSONValue] = [:]
            for key in allowed {
                payload[key] = .string("VALUE-\(key)")
            }
            // Inject banned-key sentinels:
            for banned in TeamEventPayloadBuilder.bannedKeys {
                payload[banned] = .string("SECRET-\(banned)")
            }
            // Plus a couple of unknown keys (forward-compat from a future
            // sender allowlist that this filter version doesn't know about):
            payload["future_key_1"] = .string("SECRET-future-1")
            payload["future_key_2"] = .object(["nested": .string("SECRET-nested")])

            let filtered = QueryTeamPayloadFilter.filter(
                payload, sourceKind: source.rawValue
            )

            XCTAssertEqual(
                Set(filtered.keys), allowed,
                "Filter for \(source.rawValue) must return exactly the broadcast-layer allowlist; got \(Set(filtered.keys)) vs \(allowed)"
            )
            // None of the banned-key sentinels survive:
            for banned in TeamEventPayloadBuilder.bannedKeys {
                XCTAssertNil(filtered[banned], "Banned key \(banned) leaked through filter for \(source.rawValue)")
            }
            // Forward-compat unknown keys are dropped:
            XCTAssertNil(filtered["future_key_1"])
            XCTAssertNil(filtered["future_key_2"])
        }
    }

    func testFilter_UnknownSource_DropsAllKeys() {
        let payload: [String: AnyJSONValue] = [
            "commit_sha": .string("abc"),
            "issue_id": .string("123")
        ]
        let filtered = QueryTeamPayloadFilter.filter(
            payload, sourceKind: "some_future_source_kind"
        )
        XCTAssertTrue(filtered.isEmpty, "Unknown source must DENY by default")
    }

    func testFilter_EmptyPayload_ReturnsEmpty() {
        let filtered = QueryTeamPayloadFilter.filter(
            [:], sourceKind: ShareSource.gitCommits.rawValue
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - Result-level filtering

    func testFilter_Result_ReplacesEventPayloadsAndPreservesMetadata() {
        let event1 = TeamTimelineQueryService.TeamTimelineResult.Event(
            eventID: "e1",
            kind: "gh_commit_pushed",
            sourceKind: ShareSource.gitCommits.rawValue,
            tsMs: 100,
            payload: [
                "commit_sha": .string("abc"),
                "body": .string("SECRET-LEAK-1"),   // banned
                "preview": .string("SECRET-LEAK-2") // banned
            ]
        )
        let event2 = TeamTimelineQueryService.TeamTimelineResult.Event(
            eventID: "e2",
            kind: "linear_issue_updated",
            sourceKind: ShareSource.linearIssues.rawValue,
            tsMs: 200,
            payload: [
                "issue_identifier": .string("LEAF-99"),
                "linear_comment_body": .string("SECRET-LEAK-3"),  // banned
                "issue_title_excerpt": .string("Fix bug")
            ]
        )
        let result = TeamTimelineQueryService.TeamTimelineResult(
            member: .init(pubkey: "pk", displayName: "Alice"),
            workspace: .init(id: "ws1", name: "WS"),
            window: .init(sinceMs: 0, untilMs: 1000),
            events: [event1, event2],
            totalCount: 2,
            truncated: false
        )

        let filtered = QueryTeamPayloadFilter.filter(result)

        // Metadata preserved
        XCTAssertEqual(filtered.member.pubkey, "pk")
        XCTAssertEqual(filtered.workspace.id, "ws1")
        XCTAssertEqual(filtered.window.sinceMs, 0)
        XCTAssertEqual(filtered.events.count, 2)
        XCTAssertEqual(filtered.totalCount, 2)

        // Event 1: only commit_sha survives.
        XCTAssertEqual(filtered.events[0].payload, ["commit_sha": .string("abc")])
        XCTAssertNil(filtered.events[0].payload["body"])
        XCTAssertNil(filtered.events[0].payload["preview"])

        // Event 2: identifier + excerpt survive.
        XCTAssertEqual(filtered.events[1].payload["issue_identifier"], .string("LEAF-99"))
        XCTAssertEqual(filtered.events[1].payload["issue_title_excerpt"], .string("Fix bug"))
        XCTAssertNil(filtered.events[1].payload["linear_comment_body"])
    }

    // MARK: - Banned-key parity check

    /// Regression fence — the filter MUST honor every banned key the broadcast
    /// builder declares. If broadcast layer adds a new banned key, this test
    /// fails until the filter (which lives below TeamEventPayloadBuilder in
    /// the dependency graph) is updated.
    func testFilter_AllBannedKeys_DroppedAcrossAllSources() {
        for source in ShareSource.allCases {
            var payload: [String: AnyJSONValue] = [:]
            for banned in TeamEventPayloadBuilder.bannedKeys {
                payload[banned] = .string("LEAK-SENTINEL-\(banned)")
            }
            let filtered = QueryTeamPayloadFilter.filter(payload, sourceKind: source.rawValue)
            for banned in TeamEventPayloadBuilder.bannedKeys {
                XCTAssertNil(
                    filtered[banned],
                    "banned key \(banned) leaked through filter for source \(source.rawValue)"
                )
            }
        }
    }
}
