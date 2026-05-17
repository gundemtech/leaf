//
//  GitHubProjectsV2DiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D2 — Task 7. Pure-helper tests for
//  GitHubWarmCollector.projectsV2Diff(prior:current:).
//
//  The helper compares two arrays of GitHubProjectV2ItemSnapshot and returns
//  three categorized diff lists: card moves (status), iteration changes, and
//  field value updates. Bootstrap discipline (new items in `current` but not
//  `prior` produce zero rows) lives in the helper itself; the collector tier
//  (Task 8) handles emit-on-first-sight separately.
//

import XCTest

@testable import LeafCore

final class GitHubProjectsV2DiffTests: XCTestCase {

    // MARK: - Helpers

    private func item(
        id: String,
        project: String = "P1",
        title: String = "Item",
        status: String? = nil,
        iteration: String? = nil,
        fields: [String: String] = [:],
        ts: Int64 = 1_700_000_000_000
    ) -> GitHubProjectV2ItemSnapshot {
        GitHubProjectV2ItemSnapshot(
            itemID: id,
            projectID: project,
            title: title,
            status: status,
            iterationID: iteration,
            fieldValues: fields,
            updatedAtMs: ts
        )
    }

    // MARK: - Status change (card moved)

    func testStatusChange_emitsCardMovedRow() {
        let prior = [item(id: "I1", status: "todo")]
        let current = [item(id: "I1", status: "in_progress")]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 1)
        XCTAssertEqual(iter.count, 0)
        XCTAssertEqual(fields.count, 0)
        XCTAssertEqual(cardMoved[0].0, "I1")
        XCTAssertEqual(cardMoved[0].1, "P1")
        XCTAssertEqual(cardMoved[0].2, "todo")
        XCTAssertEqual(cardMoved[0].3, "in_progress")
    }

    // MARK: - Iteration change

    func testIterationChange_emitsIterationRow() {
        let prior = [item(id: "I1", iteration: "sprint-12")]
        let current = [item(id: "I1", iteration: "sprint-13")]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 0)
        XCTAssertEqual(iter.count, 1)
        XCTAssertEqual(fields.count, 0)
        XCTAssertEqual(iter[0].0, "I1")
        XCTAssertEqual(iter[0].1, "P1")
        XCTAssertEqual(iter[0].2, "sprint-12")
        XCTAssertEqual(iter[0].3, "sprint-13")
    }

    // MARK: - Field value swap

    func testFieldValueSwap_emitsFieldUpdatedRow() {
        let prior = [item(id: "I1", fields: ["priority": "P0"])]
        let current = [item(id: "I1", fields: ["priority": "P1"])]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 0)
        XCTAssertEqual(iter.count, 0)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].0, "I1")
        XCTAssertEqual(fields[0].1, "P1")
        XCTAssertEqual(fields[0].2, "priority")
        XCTAssertEqual(fields[0].3, "P0")
        XCTAssertEqual(fields[0].4, "P1")
    }

    // MARK: - No-op on identical input

    func testIdenticalInput_emitsNothing() {
        let snap = [
            item(id: "I1", status: "todo", iteration: "sprint-12", fields: ["priority": "P0", "size": "M"]),
            item(id: "I2", status: "in_progress", iteration: "sprint-12", fields: ["priority": "P1"]),
        ]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: snap, current: snap)

        XCTAssertEqual(cardMoved.count, 0)
        XCTAssertEqual(iter.count, 0)
        XCTAssertEqual(fields.count, 0)
    }

    // MARK: - Bootstrap discipline (all-new items)

    func testEmptyPrior_emitsNothing() {
        let prior: [GitHubProjectV2ItemSnapshot] = []
        let current = [
            item(id: "I1", status: "todo", iteration: "sprint-12", fields: ["priority": "P0"]),
            item(id: "I2", status: "in_progress"),
        ]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 0)
        XCTAssertEqual(iter.count, 0)
        XCTAssertEqual(fields.count, 0)
    }

    // MARK: - Combined: status + iteration + field all change at once

    func testCombinedChange_emitsOneRowInEachList() {
        let prior = [item(id: "I1", status: "todo", iteration: "sprint-12", fields: ["priority": "P0"])]
        let current = [item(id: "I1", status: "in_progress", iteration: "sprint-13", fields: ["priority": "P1"])]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 1)
        XCTAssertEqual(iter.count, 1)
        XCTAssertEqual(fields.count, 1)

        XCTAssertEqual(cardMoved[0].2, "todo")
        XCTAssertEqual(cardMoved[0].3, "in_progress")
        XCTAssertEqual(iter[0].2, "sprint-12")
        XCTAssertEqual(iter[0].3, "sprint-13")
        XCTAssertEqual(fields[0].2, "priority")
        XCTAssertEqual(fields[0].3, "P0")
        XCTAssertEqual(fields[0].4, "P1")
    }

    // MARK: - Field added (prior omits, current has)

    func testFieldAdded_emitsRowWithNilOld() {
        let prior = [item(id: "I1", fields: [:])]
        let current = [item(id: "I1", fields: ["priority": "P1"])]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 0)
        XCTAssertEqual(iter.count, 0)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].2, "priority")
        XCTAssertNil(fields[0].3)
        XCTAssertEqual(fields[0].4, "P1")
    }

    // MARK: - Field removed (prior has, current omits)

    func testFieldRemoved_emitsRowWithNilNew() {
        let prior = [item(id: "I1", fields: ["priority": "P0"])]
        let current = [item(id: "I1", fields: [:])]

        let (cardMoved, iter, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.count, 0)
        XCTAssertEqual(iter.count, 0)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].2, "priority")
        XCTAssertEqual(fields[0].3, "P0")
        XCTAssertNil(fields[0].4)
    }

    // MARK: - Sorted output (deterministic for assertions)

    func testOutputSortedByItemID() {
        let prior = [
            item(id: "I3", status: "todo"),
            item(id: "I1", status: "todo"),
            item(id: "I2", status: "todo"),
        ]
        let current = [
            item(id: "I3", status: "done"),
            item(id: "I1", status: "in_progress"),
            item(id: "I2", status: "in_review"),
        ]

        let (cardMoved, _, _) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(cardMoved.map { $0.0 }, ["I1", "I2", "I3"])
    }

    func testFieldsSortedByItemThenName() {
        let prior = [
            item(id: "I2", fields: ["zeta": "1", "alpha": "1"]),
            item(id: "I1", fields: ["zeta": "1", "alpha": "1"]),
        ]
        let current = [
            item(id: "I2", fields: ["zeta": "2", "alpha": "2"]),
            item(id: "I1", fields: ["zeta": "2", "alpha": "2"]),
        ]

        let (_, _, fields) = GitHubWarmCollector.projectsV2Diff(prior: prior, current: current)

        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0].0, "I1")
        XCTAssertEqual(fields[0].2, "alpha")
        XCTAssertEqual(fields[1].0, "I1")
        XCTAssertEqual(fields[1].2, "zeta")
        XCTAssertEqual(fields[2].0, "I2")
        XCTAssertEqual(fields[2].2, "alpha")
        XCTAssertEqual(fields[3].0, "I2")
        XCTAssertEqual(fields[3].2, "zeta")
    }
}
