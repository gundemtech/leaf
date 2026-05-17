//
//  SlackUsergroupsDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for cold-tier
//  usergroups membership diff (added / removed userIDs per group).
//

import XCTest

@testable import LeafCore

final class SlackUsergroupsDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackUsergroupsSnapshot.empty
        let curr = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"])
        ])
        let diffs = SlackColdCollector.usergroupsDiff(prior: prior, current: curr)
        XCTAssertEqual(diffs.count, 0)
    }

    func testUserAddedToGroup() {
        let prior = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1"])
        ])
        let curr = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"])
        ])
        let diffs = SlackColdCollector.usergroupsDiff(prior: prior, current: curr)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].groupID, "G1")
        XCTAssertEqual(diffs[0].addedUserIDs, ["U2"])
        XCTAssertEqual(diffs[0].removedUserIDs, [])
    }

    func testUserRemovedFromGroup() {
        let prior = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"])
        ])
        let curr = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1"])
        ])
        let diffs = SlackColdCollector.usergroupsDiff(prior: prior, current: curr)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].groupID, "G1")
        XCTAssertEqual(diffs[0].addedUserIDs, [])
        XCTAssertEqual(diffs[0].removedUserIDs, ["U2"])
    }

    func testGroupDisappearsNoEvent() {
        // Groups that vanish from current (group deleted) — no per-user diff emitted
        // (would require synthesizing entire prior set as "removed"; out of scope here).
        let prior = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"]),
            SlackUsergroup(id: "G2", name: "ops", userIDs: ["U3"]),
        ])
        let curr = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"])
        ])
        let diffs = SlackColdCollector.usergroupsDiff(prior: prior, current: curr)
        XCTAssertEqual(diffs.count, 0)
    }

    func testNoChangeNoEvents() {
        let prior = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"])
        ])
        let curr = SlackUsergroupsSnapshot(groups: [
            SlackUsergroup(id: "G1", name: "eng", userIDs: ["U1", "U2"])
        ])
        let diffs = SlackColdCollector.usergroupsDiff(prior: prior, current: curr)
        XCTAssertEqual(diffs.count, 0)
    }
}
