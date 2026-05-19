//
//  QueryTeamToolJSONShapeTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T7 — JSON shape contract for `leaf_query_team` MCP tool.
//
//  These tests exercise the LeafCore-side surface that the MCP tool wires
//  through to JSONEncoder/Decoder. The tool itself (LeafMCP/Tools/QueryTeamTool.swift)
//  is an Xcode target outside `swift test` — its translation layer
//  (`encodeResult` Codable → dict) is structurally identical to the
//  JSONEncoder roundtrip exercised here, so this suite is the SPM-testable
//  proxy for the tool's wire format invariants.
//

import XCTest
@testable import LeafCore

final class QueryTeamToolJSONShapeTests: XCTestCase {

    // MARK: - 1. Result roundtrips via Codable

    func testResult_RoundtripsViaCodable() throws {
        let result = TeamTimelineQueryService.TeamTimelineResult(
            member: .init(pubkey: "aabb", displayName: "Alice"),
            workspace: .init(id: "ws1", name: "Engineering"),
            window: .init(sinceMs: 1_000, untilMs: 2_000),
            events: [
                .init(
                    eventID: "e1",
                    kind: "gh_commit_pushed",
                    sourceKind: ShareSource.gitCommits.rawValue,
                    tsMs: 1_500,
                    payload: [
                        "commit_sha": .string("deadbeef"),
                        "files_changed_count": .int(3),
                        "nested_arr": .array([.string("a"), .string("b")]),
                        "nested_obj": .object(["key": .string("value")]),
                        "is_merged": .bool(true)
                    ]
                )
            ],
            totalCount: 1,
            truncated: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)

        let decoded = try JSONDecoder().decode(
            TeamTimelineQueryService.TeamTimelineResult.self, from: data
        )

        XCTAssertEqual(decoded, result)
    }

    // MARK: - 2. Encoded output contains expected top-level keys

    func testEncodedOutput_TopLevelKeys() throws {
        let result = TeamTimelineQueryService.TeamTimelineResult(
            member: .init(pubkey: "aabb", displayName: "Alice"),
            workspace: .init(id: "ws1", name: "Engineering"),
            window: .init(sinceMs: 1_000, untilMs: 2_000),
            events: [],
            totalCount: 0,
            truncated: false
        )
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["member"])
        XCTAssertNotNil(json?["workspace"])
        XCTAssertNotNil(json?["window"])
        XCTAssertNotNil(json?["events"])
        XCTAssertNotNil(json?["totalCount"])
        XCTAssertNotNil(json?["truncated"])
    }

    // MARK: - 3. AnyJSONValue null/bool/int/double/string/array/object all roundtrip

    func testAnyJSONValue_AllCasesRoundtrip() throws {
        let values: [AnyJSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .int(42),
            .int(-1_000_000),
            .double(3.14),
            .string("hello"),
            .array([.int(1), .string("two"), .null]),
            .object(["k": .bool(true), "nested": .array([.double(1.5)])])
        ]
        for v in values {
            let data = try JSONEncoder().encode(v)
            let back = try JSONDecoder().decode(AnyJSONValue.self, from: data)
            XCTAssertEqual(back, v, "AnyJSONValue roundtrip failed for \(v)")
        }
    }

    // MARK: - 4. AnyJSONValue init from Foundation Any works

    func testAnyJSONValue_FromFoundationJSONObject() throws {
        let raw = """
        {
          "a_string": "hi",
          "an_int": 42,
          "a_bool": true,
          "a_null": null,
          "an_array": [1, 2, 3],
          "an_object": {"nested": "value"}
        }
        """.data(using: .utf8)!
        let any = try JSONSerialization.jsonObject(with: raw)
        let dict = any as? [String: Any]
        XCTAssertNotNil(dict)
        let mapped = dict!.mapValues(AnyJSONValue.init)

        XCTAssertEqual(mapped["a_string"], .string("hi"))
        XCTAssertEqual(mapped["a_bool"], .bool(true))
        XCTAssertEqual(mapped["a_null"], .null)
        // Foundation parses integers as Int (NSNumber) bridging — accept the
        // case where the int sticks to AnyJSONValue.int(42).
        XCTAssertEqual(mapped["an_int"], .int(42))
        // Arrays + objects flow through recursively.
        if case let .array(arr) = mapped["an_array"]! {
            XCTAssertEqual(arr.count, 3)
        } else {
            XCTFail("Expected array")
        }
        if case let .object(obj) = mapped["an_object"]! {
            XCTAssertEqual(obj["nested"], .string("value"))
        } else {
            XCTFail("Expected object")
        }
    }
}
