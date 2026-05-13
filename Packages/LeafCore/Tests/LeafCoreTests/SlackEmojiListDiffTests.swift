//
//  SlackEmojiListDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for cold-tier
//  custom emoji set diff (added only — removed is anti-feature per spec).
//

import XCTest
@testable import LeafCore

final class SlackEmojiListDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackEmojiSnapshot.empty
        let curr = SlackEmojiSnapshot(emojiNames: ["partyparrot"])
        let result = SlackColdCollector.emojiSetDiff(prior: prior, current: curr)
        XCTAssertEqual(result.added, [])
    }

    func testNewEmojiAdded() {
        let prior = SlackEmojiSnapshot(emojiNames: ["partyparrot"])
        let curr = SlackEmojiSnapshot(emojiNames: ["partyparrot", "shipit"])
        let result = SlackColdCollector.emojiSetDiff(prior: prior, current: curr)
        XCTAssertEqual(result.added, ["shipit"])
    }

    func testRemovedEmojiNotSurfaced() {
        // Per spec §2.8: emoji removal is intentionally NOT a derived event
        // (custom emoji can be re-added easily; removal not informative).
        let prior = SlackEmojiSnapshot(emojiNames: ["partyparrot", "shipit"])
        let curr = SlackEmojiSnapshot(emojiNames: ["partyparrot"])
        let result = SlackColdCollector.emojiSetDiff(prior: prior, current: curr)
        XCTAssertEqual(result.added, [])
    }

    func testNoChangeNoEvents() {
        let prior = SlackEmojiSnapshot(emojiNames: ["partyparrot"])
        let curr = SlackEmojiSnapshot(emojiNames: ["partyparrot"])
        let result = SlackColdCollector.emojiSetDiff(prior: prior, current: curr)
        XCTAssertEqual(result.added, [])
    }
}
