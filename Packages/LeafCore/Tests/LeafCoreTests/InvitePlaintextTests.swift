import XCTest

@testable import LeafCore

final class InvitePlaintextTests: XCTestCase {

    private func makePlaintext() -> InvitePlaintext {
        InvitePlaintext(
            teamKeyBase64: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
            teamKeyID: "11111111-2222-3333-4444-555555555555",
            orgID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            orgName: "Leaf",
            adminMemberID: "99999999-8888-7777-6666-555555555555",
            adminDisplayName: "Dmitrii",
            issuedAtMs: 1_730_000_000_000
        )
    }

    func testCodable_RoundTripPreservesAllFields() throws {
        let original = makePlaintext()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InvitePlaintext.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testCodable_JSONKeysAreSnakeCase() throws {
        let plaintext = makePlaintext()
        let encoded = try JSONEncoder().encode(plaintext)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        let expectedKeys: Set<String> = [
            "team_key", "team_key_id", "org_id", "org_name",
            "admin_member_id", "admin_display_name", "issued_at_ms",
        ]
        XCTAssertEqual(Set(parsed.keys), expectedKeys)

        XCTAssertEqual(parsed["team_key"] as? String, plaintext.teamKeyBase64)
        XCTAssertEqual(parsed["org_name"] as? String, "Leaf")
        XCTAssertEqual(parsed["issued_at_ms"] as? Int64, 1_730_000_000_000)
    }

    func testCodable_RejectsMissingField() throws {
        // org_id missing
        let json = """
            {
              "team_key": "AAAA",
              "team_key_id": "11111111-2222-3333-4444-555555555555",
              "org_name": "Leaf",
              "admin_member_id": "99999999-8888-7777-6666-555555555555",
              "admin_display_name": "Dmitrii",
              "issued_at_ms": 1730000000000
            }
            """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(InvitePlaintext.self, from: json) as InvitePlaintext)
    }

    func testHashable_DistinctValuesNotEqual() {
        let a = makePlaintext()
        let b = InvitePlaintext(
            teamKeyBase64: a.teamKeyBase64,
            teamKeyID: a.teamKeyID,
            orgID: "00000000-0000-0000-0000-000000000000",  // different
            orgName: a.orgName,
            adminMemberID: a.adminMemberID,
            adminDisplayName: a.adminDisplayName,
            issuedAtMs: a.issuedAtMs
        )
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.hashValue, b.hashValue)
    }
}
