import XCTest
@testable import LeafCore

/// Phase 5.3.D — `RotationOutboxRow` value type.
final class RotationOutboxRowTests: XCTestCase {

    func testEquatableHashableRoundTrip() {
        let row1 = RotationOutboxRow(
            peerPubkeyHex: String(repeating: "aa", count: 32),
            newKeyID: "00000000-0000-0000-0000-000000000001",
            workspaceID: "ws-1",
            priorKeyID: "00000000-0000-0000-0000-000000000000",
            kind: .rotation,
            peerMemberID: "11111111-1111-1111-1111-111111111111",
            blob: Data([0x03, 0x01, 0x02]),
            expiresAtMs: 1_700_000_000_000,
            createdAtMs: 1_700_000_000_000,
            postedAtMs: nil
        )
        let row2 = row1
        XCTAssertEqual(row1, row2)
        XCTAssertEqual(row1.hashValue, row2.hashValue)
    }

    func testPostedNilVsNonNilDistinguish() {
        let unposted = RotationOutboxRow(
            peerPubkeyHex: String(repeating: "aa", count: 32), newKeyID: "k1", workspaceID: "ws-1", priorKeyID: "k0",
            kind: .rotation, peerMemberID: "m1", blob: Data(),
            expiresAtMs: 0, createdAtMs: 0, postedAtMs: nil
        )
        let posted = RotationOutboxRow(
            peerPubkeyHex: String(repeating: "aa", count: 32), newKeyID: "k1", workspaceID: "ws-1", priorKeyID: "k0",
            kind: .rotation, peerMemberID: "m1", blob: Data(),
            expiresAtMs: 0, createdAtMs: 0, postedAtMs: 1
        )
        XCTAssertNotEqual(unposted, posted)
    }

    func testTombstoneKindPreserved() {
        let row = RotationOutboxRow(
            peerPubkeyHex: String(repeating: "aa", count: 32), newKeyID: "k0", workspaceID: "ws-1", priorKeyID: "k0",
            kind: .tombstone, peerMemberID: "m1", blob: Data(),
            expiresAtMs: 0, createdAtMs: 0, postedAtMs: nil
        )
        XCTAssertEqual(row.kind, .tombstone)
    }
}
