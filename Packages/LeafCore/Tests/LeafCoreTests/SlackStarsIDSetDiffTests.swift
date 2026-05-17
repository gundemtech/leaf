//
//  SlackStarsIDSetDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for warm-tier
//  stars (saved items) diff (saved / unsaved).
//

import XCTest

@testable import LeafCore

final class SlackStarsIDSetDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackStarsSnapshot.empty
        let curr = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500)
        ])
        let (saved, unsaved) = SlackWarmCollector.starsDiff(prior: prior, current: curr)
        XCTAssertEqual(saved, [])
        XCTAssertEqual(unsaved, [])
    }

    func testSavedItemDetected() {
        let prior = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500)
        ])
        let curr = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500),
            SlackStarItem(itemRef: "C2:200.0", savedAtMs: 800),
        ])
        let (saved, unsaved) = SlackWarmCollector.starsDiff(prior: prior, current: curr)
        XCTAssertEqual(saved.map(\.itemRef), ["C2:200.0"])
        XCTAssertEqual(unsaved, [])
    }

    func testUnsavedItemDetected() {
        let prior = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500),
            SlackStarItem(itemRef: "C2:200.0", savedAtMs: 800),
        ])
        let curr = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500)
        ])
        let (saved, unsaved) = SlackWarmCollector.starsDiff(prior: prior, current: curr)
        XCTAssertEqual(saved, [])
        XCTAssertEqual(unsaved.map(\.itemRef), ["C2:200.0"])
    }

    func testNoChangeNoEvents() {
        let prior = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500)
        ])
        let curr = SlackStarsSnapshot(stars: [
            SlackStarItem(itemRef: "C1:100.0", savedAtMs: 500)
        ])
        let (saved, unsaved) = SlackWarmCollector.starsDiff(prior: prior, current: curr)
        XCTAssertEqual(saved, [])
        XCTAssertEqual(unsaved, [])
    }
}
