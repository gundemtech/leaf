//
//  NotificationCategoryRegistryTests.swift
//  LeafCoreTests
//
//  Track 5 / S8 / T5 — APNs category configuration tests.
//
//  Validates the static `NotificationCategoryRegistry.all` array shape: 3
//  categories (handoff / task / ping), per-category action sets per spec
//  §3.5 and plan T5 description, and required action options (foreground
//  for `dm.reply`; no-foreground for `dm.markDone` — markDone must not
//  open the app, it's a background dismissal action).
//

import XCTest
import UserNotifications
@testable import LeafCore

final class NotificationCategoryRegistryTests: XCTestCase {

    // MARK: - Category set + identifiers

    func testAll_ContainsExactlyThreeCategories() {
        let cats = NotificationCategoryRegistry.all
        XCTAssertEqual(cats.count, 3)
    }

    func testAll_IdentifiersMatchLeafDmPrefix() {
        let ids = Set(NotificationCategoryRegistry.all.map { $0.identifier })
        XCTAssertEqual(ids, Set(["leaf.dm.handoff", "leaf.dm.task", "leaf.dm.ping"]))
    }

    func testCategoryID_ForKind_MatchesContract() {
        XCTAssertEqual(NotificationCategoryRegistry.Kind.handoff.categoryID, "leaf.dm.handoff")
        XCTAssertEqual(NotificationCategoryRegistry.Kind.task.categoryID, "leaf.dm.task")
        XCTAssertEqual(NotificationCategoryRegistry.Kind.ping.categoryID, "leaf.dm.ping")
    }

    // MARK: - Per-category action sets

    func testHandoffCategory_HasReplyActionOnly() {
        let handoff = NotificationCategoryRegistry.handoff
        let actionIDs = Set(handoff.actions.map { $0.identifier })
        XCTAssertEqual(
            actionIDs,
            Set([NotificationCategoryRegistry.replyActionID]),
            "Handoff has reply action only — no markDone per plan T5 description"
        )
    }

    func testTaskCategory_HasReplyAndMarkDoneActions() {
        let task = NotificationCategoryRegistry.task
        let actionIDs = Set(task.actions.map { $0.identifier })
        XCTAssertEqual(
            actionIDs,
            Set([
                NotificationCategoryRegistry.replyActionID,
                NotificationCategoryRegistry.markDoneActionID,
            ]),
            "Task gets both reply + markDone per spec §3.5"
        )
    }

    func testPingCategory_HasReplyActionOnly() {
        let ping = NotificationCategoryRegistry.ping
        let actionIDs = Set(ping.actions.map { $0.identifier })
        XCTAssertEqual(
            actionIDs,
            Set([NotificationCategoryRegistry.replyActionID]),
            "Ping is acknowledgement-only — reply action without markDone"
        )
    }

    // MARK: - Action options (foreground vs background)

    func testReplyAction_HasForegroundOption_AllCategories() {
        for cat in NotificationCategoryRegistry.all {
            guard let reply = cat.actions.first(where: {
                $0.identifier == NotificationCategoryRegistry.replyActionID
            }) else {
                XCTFail("Category \(cat.identifier) missing reply action")
                continue
            }
            XCTAssertTrue(
                reply.options.contains(.foreground),
                "Reply action on \(cat.identifier) must open the app (deep-link via WindowState)"
            )
        }
    }

    func testMarkDoneAction_NoForegroundOption() {
        let task = NotificationCategoryRegistry.task
        guard let markDone = task.actions.first(where: {
            $0.identifier == NotificationCategoryRegistry.markDoneActionID
        }) else {
            XCTFail("Task category missing markDone action")
            return
        }
        XCTAssertFalse(
            markDone.options.contains(.foreground),
            "markDone must NOT open the app — background-only action per plan T5"
        )
    }

    // MARK: - Action IDs are stable contract surface

    func testActionIdentifiers_StableContractValues() {
        // These string constants are read by AppDelegate action handlers in T6;
        // any rename here is a contract break.
        XCTAssertEqual(NotificationCategoryRegistry.replyActionID, "dm.reply")
        XCTAssertEqual(NotificationCategoryRegistry.markDoneActionID, "dm.markDone")
    }

    // MARK: - Kind.hasMarkDone helper

    func testHasMarkDone_OnlyTrueForTask() {
        XCTAssertFalse(NotificationCategoryRegistry.Kind.handoff.hasMarkDone)
        XCTAssertTrue(NotificationCategoryRegistry.Kind.task.hasMarkDone)
        XCTAssertFalse(NotificationCategoryRegistry.Kind.ping.hasMarkDone)
    }
}
