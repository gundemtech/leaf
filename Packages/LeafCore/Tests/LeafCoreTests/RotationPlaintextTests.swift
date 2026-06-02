import XCTest
@testable import LeafCore

final class RotationPlaintextTests: XCTestCase {

    private func makeRotationPlaintext() -> RotationPlaintext {
        RotationPlaintext(
            kind: .rotation,
            newTeamKeyBase64: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
            newKeyID: "22222222-3333-4444-5555-666666666666",
            priorKeyID: "11111111-2222-3333-4444-555555555555",
            generatedAtMs: 1_730_000_000_000,
            removedMemberID: nil
        )
    }

    private func makeTombstonePlaintext() -> RotationPlaintext {
        let priorID = "11111111-2222-3333-4444-555555555555"
        return RotationPlaintext(
            kind: .tombstone,
            newTeamKeyBase64: "",
            newKeyID: priorID,                 // == priorKeyID for tombstone
            priorKeyID: priorID,
            generatedAtMs: 1_730_000_000_000,
            removedMemberID: "99999999-8888-7777-6666-555555555555"
        )
    }

    func testCodable_RoundTripRotation() throws {
        let original = makeRotationPlaintext()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RotationPlaintext.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testCodable_RoundTripTombstone() throws {
        let original = makeTombstonePlaintext()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RotationPlaintext.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .tombstone)
        XCTAssertEqual(decoded.newTeamKeyBase64, "")
        XCTAssertEqual(decoded.newKeyID, decoded.priorKeyID)
        XCTAssertNotNil(decoded.removedMemberID)
    }

    func testCodable_JSONKeysAreSnakeCase() throws {
        let plaintext = makeRotationPlaintext()
        let encoded = try JSONEncoder().encode(plaintext)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // JSONEncoder default omits nil optionals; "removed_member_id" only present for tombstone.
        let requiredKeys: Set<String> = [
            "kind", "new_team_key", "new_key_id", "prior_key_id", "generated_at_ms",
        ]
        XCTAssertTrue(requiredKeys.isSubset(of: Set(parsed.keys)))

        XCTAssertEqual(parsed["kind"] as? String, "rotation")
        XCTAssertEqual(parsed["new_team_key"] as? String, plaintext.newTeamKeyBase64)
        XCTAssertEqual(parsed["new_key_id"] as? String, plaintext.newKeyID)
        XCTAssertEqual(parsed["prior_key_id"] as? String, plaintext.priorKeyID)
        XCTAssertEqual(parsed["generated_at_ms"] as? Int64, 1_730_000_000_000)
    }

    func testCodable_TombstoneSerializesKindAsTombstone() throws {
        let plaintext = makeTombstonePlaintext()
        let encoded = try JSONEncoder().encode(plaintext)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(parsed["kind"] as? String, "tombstone")
        XCTAssertEqual(parsed["new_team_key"] as? String, "")
        XCTAssertEqual(parsed["removed_member_id"] as? String, "99999999-8888-7777-6666-555555555555")
    }

    func testRotationKind_RawValues() {
        XCTAssertEqual(RotationKind.rotation.rawValue, "rotation")
        XCTAssertEqual(RotationKind.tombstone.rawValue, "tombstone")
    }
}
