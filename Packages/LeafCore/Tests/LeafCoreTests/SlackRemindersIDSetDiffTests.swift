//
//  SlackRemindersIDSetDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for warm-tier
//  reminders diff (created / completed transitions).
//

import XCTest

@testable import LeafCore

final class SlackRemindersIDSetDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackRemindersSnapshot.empty
        let curr = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: nil)
        ])
        let (created, completed) = SlackWarmCollector.remindersDiff(prior: prior, current: curr)
        // Empty-prior bootstrap: no diff events emit on first observation.
        XCTAssertEqual(created, [])
        XCTAssertEqual(completed, [])
    }

    func testNewReminderCreated() {
        let prior = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: nil)
        ])
        let curr = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: nil),
            SlackReminder(id: "R2", dueTs: 200, completedTs: nil),
        ])
        let (created, completed) = SlackWarmCollector.remindersDiff(prior: prior, current: curr)
        XCTAssertEqual(created.map(\.id), ["R2"])
        XCTAssertEqual(completed, [])
    }

    func testReminderCompletedTransition() {
        let prior = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: nil)
        ])
        let curr = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: 150)
        ])
        let (created, completed) = SlackWarmCollector.remindersDiff(prior: prior, current: curr)
        XCTAssertEqual(created, [])
        XCTAssertEqual(completed.map(\.id), ["R1"])
        XCTAssertEqual(completed.first?.completedTs, 150)
    }

    func testAlreadyCompletedNoEvent() {
        let prior = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: 120)
        ])
        let curr = SlackRemindersSnapshot(reminders: [
            SlackReminder(id: "R1", dueTs: 100, completedTs: 120)
        ])
        let (created, completed) = SlackWarmCollector.remindersDiff(prior: prior, current: curr)
        XCTAssertEqual(created, [])
        XCTAssertEqual(completed, [])
    }
}
