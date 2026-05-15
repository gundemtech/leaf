// Phase Track-5 S5 — TeamEventPlaintext + TeamEventPayload JSON round-trip.

import XCTest
@testable import LeafCore

final class TeamEventPlaintextTests: XCTestCase {

    func testRoundTrip_EncodesAllFieldsWithSnakeCaseWireKeys() throws {
        let plaintext = TeamEventPlaintext(
            eventID: "evt-123",
            workspaceID: "wid-456",
            senderMemberID: "mid-789",
            senderPubkeyHex: String(repeating: "ab", count: 32),
            source: .gitCommits,
            kind: "gh_commit_pushed",
            payload: TeamEventPayload(fields: [
                "commit_sha": "deadbeef",
                "repo_full_name": "gundemtech/leaf"
            ]),
            eventTsMs: 1_000
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plaintext)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(jsonString.contains("\"event_id\":\"evt-123\""))
        XCTAssertTrue(jsonString.contains("\"workspace_id\":\"wid-456\""))
        XCTAssertTrue(jsonString.contains("\"sender_member_id\":\"mid-789\""))
        XCTAssertTrue(jsonString.contains("\"sender_pubkey_hex\":"))
        XCTAssertTrue(jsonString.contains("\"source\":\"git_commits\""))
        XCTAssertTrue(jsonString.contains("\"kind\":\"gh_commit_pushed\""))
        XCTAssertTrue(jsonString.contains("\"event_ts_ms\":1000"))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeamEventPlaintext.self, from: data)
        XCTAssertEqual(decoded, plaintext)
    }

    func testDeterministicEncoding_SortedKeysProducesIdenticalBytes() throws {
        let plaintext = TeamEventPlaintext(
            eventID: "evt-1",
            workspaceID: "wid-1",
            senderMemberID: "mid-1",
            senderPubkeyHex: "00",
            source: .linearIssues,
            kind: "issue_updated",
            payload: TeamEventPayload(fields: ["issue_identifier": "LEAF-99"]),
            eventTsMs: 2_000
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let d1 = try encoder.encode(plaintext)
        let d2 = try encoder.encode(plaintext)
        XCTAssertEqual(d1, d2)
    }

    func testPayloadFields_EmptyMapEncodesAsEmptyObject() throws {
        let payload = TeamEventPayload(fields: [:])
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("\"fields\":{}"))

        let decoded = try JSONDecoder().decode(TeamEventPayload.self, from: data)
        XCTAssertTrue(decoded.fields.isEmpty)
    }
}
