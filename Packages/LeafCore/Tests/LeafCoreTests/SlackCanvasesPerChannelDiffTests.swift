//
//  SlackCanvasesPerChannelDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for cold-tier
//  canvases diff (created / edited).
//

import XCTest

@testable import LeafCore

final class SlackCanvasesPerChannelDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackCanvasesSnapshot.empty
        let curr = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec", lastEditedMs: 1000)
        ])
        let (created, edited) = SlackColdCollector.canvasesPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(created, [])
        XCTAssertEqual(edited, [])
    }

    func testCreatedCanvas() {
        let prior = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec", lastEditedMs: 1000)
        ])
        let curr = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec", lastEditedMs: 1000),
            SlackCanvas(channelID: "C2", canvasID: "K2", title: "Roadmap", lastEditedMs: 2000),
        ])
        let (created, edited) = SlackColdCollector.canvasesPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(created.map(\.canvasID), ["K2"])
        XCTAssertEqual(edited, [])
    }

    func testEditedCanvasOnLastEditedIncrease() {
        let prior = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec", lastEditedMs: 1000)
        ])
        let curr = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec v2", lastEditedMs: 1500)
        ])
        let (created, edited) = SlackColdCollector.canvasesPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(created, [])
        XCTAssertEqual(edited.map(\.canvasID), ["K1"])
        XCTAssertEqual(edited.first?.lastEditedMs, 1500)
    }

    func testNoChangeNoEvents() {
        let prior = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec", lastEditedMs: 1000)
        ])
        let curr = SlackCanvasesSnapshot(canvases: [
            SlackCanvas(channelID: "C1", canvasID: "K1", title: "Spec", lastEditedMs: 1000)
        ])
        let (created, edited) = SlackColdCollector.canvasesPerChannelDiff(prior: prior, current: curr)
        XCTAssertEqual(created, [])
        XCTAssertEqual(edited, [])
    }
}
