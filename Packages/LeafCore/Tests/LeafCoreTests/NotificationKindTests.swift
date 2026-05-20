// Track 5 / S8 / T1 — NotificationKind regression fence.
//
// Locks the 11-case shape per contract §10.2 + asserts default + locked invariants
// + non-empty display labels (cross-spec MIN-1 bridge: each kind must surface text
// in NotificationsSettingsSection — T9 consumer).

import XCTest
@testable import LeafCore

final class NotificationKindTests: XCTestCase {

    // MARK: - 13-case shape regression (11 S8 baseline + 2 M027 invite kinds)

    func testNotificationKind_HasExactly13Cases() {
        XCTAssertEqual(NotificationKind.allCases.count, 13)
    }

    func testNotificationKind_AllCasesPresent() {
        let raws = Set(NotificationKind.allCases.map { $0.rawValue })
        XCTAssertEqual(raws, Set([
            "handoff", "task", "ping",
            "decision", "blocker", "open_question", "where_stopped",
            "raw_activity",
            "respect_focus", "coalesce", "sound",
            // M027 invite-redesign
            "invite_request_received", "invite_request_approved",
        ]))
    }

    // MARK: - Default invariants

    func testNotificationKind_DefaultsMatchContractSection10_2() {
        // Default ON (S8 baseline)
        XCTAssertTrue(NotificationKind.handoff.defaultEnabled)
        XCTAssertTrue(NotificationKind.task.defaultEnabled)
        XCTAssertTrue(NotificationKind.ping.defaultEnabled)
        XCTAssertTrue(NotificationKind.decision.defaultEnabled)
        XCTAssertTrue(NotificationKind.blocker.defaultEnabled)
        XCTAssertTrue(NotificationKind.respectFocus.defaultEnabled)
        XCTAssertTrue(NotificationKind.coalesce.defaultEnabled)
        XCTAssertTrue(NotificationKind.sound.defaultEnabled)
        // Default ON (M027 invite-redesign per spec §6)
        XCTAssertTrue(NotificationKind.inviteRequestReceived.defaultEnabled)
        XCTAssertTrue(NotificationKind.inviteRequestApproved.defaultEnabled)
        // Default OFF
        XCTAssertFalse(NotificationKind.openQuestion.defaultEnabled)
        XCTAssertFalse(NotificationKind.whereStopped.defaultEnabled)
        XCTAssertFalse(NotificationKind.rawActivity.defaultEnabled)
    }

    // MARK: - Locked invariant

    func testNotificationKind_OnlyHandoffIsLocked() {
        for kind in NotificationKind.allCases {
            if kind == .handoff {
                XCTAssertTrue(kind.locked, "handoff must be locked")
            } else {
                XCTAssertFalse(kind.locked, "kind \(kind) must not be locked")
            }
        }
    }

    // MARK: - Display label invariant (cross-spec MIN-1 bridge)

    func testNotificationKind_EveryKindHasNonEmptyDisplayLabel() {
        for kind in NotificationKind.allCases {
            XCTAssertFalse(
                kind.displayLabel.isEmpty,
                "kind \(kind) missing display label"
            )
        }
    }

    func testNotificationKind_DisplayLabelsAreUnique() {
        let labels = NotificationKind.allCases.map { $0.displayLabel }
        XCTAssertEqual(Set(labels).count, labels.count, "display labels must be unique")
    }
}
