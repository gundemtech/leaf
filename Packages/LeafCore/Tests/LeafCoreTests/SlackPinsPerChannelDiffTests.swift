//
//  SlackPinsPerChannelDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for warm-tier
//  per-channel pin id-set diff (added / removed).
//

import XCTest
@testable import LeafCore

final class SlackPinsPerChannelDiffTests: XCTestCase {
    func testBootstrapEmptyPriorEmitsAddedForAllCurrent() {
        // Empty prior (bootstrap signal) — no diff emitted; collector just writes snapshot.
        let prior: [SlackChannelPinsSnapshot] = []
        let curr = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:111.222"])
        ]
        let (added, removed) = SlackWarmCollector.pinsPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added.count, 0)
        XCTAssertEqual(removed.count, 0)
    }

    func testAddedPinDetected() {
        let prior = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:100.0"])
        ]
        let curr = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:100.0", "C1:200.0"])
        ]
        let (added, removed) = SlackWarmCollector.pinsPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.channelID, "C1")
        XCTAssertEqual(added.first?.itemRef, "C1:200.0")
        XCTAssertEqual(removed.count, 0)
    }

    func testRemovedPinDetected() {
        let prior = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:100.0", "C1:200.0"])
        ]
        let curr = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:100.0"])
        ]
        let (added, removed) = SlackWarmCollector.pinsPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added.count, 0)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.channelID, "C1")
        XCTAssertEqual(removed.first?.itemRef, "C1:200.0")
    }

    func testNoChangeNoEvents() {
        let prior = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:100.0"])
        ]
        let curr = [
            SlackChannelPinsSnapshot(channelID: "C1", pinItemRefs: ["C1:100.0"])
        ]
        let (added, removed) = SlackWarmCollector.pinsPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(added.count, 0)
        XCTAssertEqual(removed.count, 0)
    }
}
