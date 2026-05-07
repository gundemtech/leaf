// Phase 5.5.A — PendingInviteStatus enum: 5 lowercase rawValues stored as TEXT
// in `pending_invites.status` column.

import XCTest
@testable import LeafCore

final class PendingInviteStatusTests: XCTestCase {
    func testRawValueStability() {
        XCTAssertEqual(PendingInviteStatus.pending.rawValue, "pending")
        XCTAssertEqual(PendingInviteStatus.consumed.rawValue, "consumed")
        XCTAssertEqual(PendingInviteStatus.expired.rawValue, "expired")
        XCTAssertEqual(PendingInviteStatus.revoked.rawValue, "revoked")
        XCTAssertEqual(PendingInviteStatus.failed.rawValue, "failed")
    }

    func testCaseIterableCovers5Cases() {
        XCTAssertEqual(PendingInviteStatus.allCases.count, 5)
        XCTAssertEqual(
            Set(PendingInviteStatus.allCases.map(\.rawValue)),
            ["pending", "consumed", "expired", "revoked", "failed"]
        )
    }
}
