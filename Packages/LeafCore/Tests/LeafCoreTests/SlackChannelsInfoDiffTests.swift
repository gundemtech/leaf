//
//  SlackChannelsInfoDiffTests.swift
//  LeafCoreTests
//
//  Phase Track-3 D3 Task 7 — pure diff helper tests for cold-tier
//  channels info diff (renamed / archived transitions).
//

import XCTest
@testable import LeafCore

final class SlackChannelsInfoDiffTests: XCTestCase {
    func testBootstrapEmptyPriorNoEvents() {
        let prior = SlackChannelsInfoSnapshot.empty
        let curr = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: false)
        ])
        let (renamed, archived) = SlackColdCollector.channelsInfoDiff(prior: prior, current: curr)
        XCTAssertEqual(renamed.count, 0)
        XCTAssertEqual(archived, [])
    }

    func testRenamedChannelDetected() {
        let prior = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: false)
        ])
        let curr = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general-old", isArchived: false)
        ])
        let (renamed, archived) = SlackColdCollector.channelsInfoDiff(prior: prior, current: curr)
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed[0].channelID, "C1")
        XCTAssertEqual(renamed[0].oldName, "general")
        XCTAssertEqual(renamed[0].newName, "general-old")
        XCTAssertEqual(archived, [])
    }

    func testArchivedChannelTransition() {
        let prior = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: false)
        ])
        let curr = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: true)
        ])
        let (renamed, archived) = SlackColdCollector.channelsInfoDiff(prior: prior, current: curr)
        XCTAssertEqual(renamed.count, 0)
        XCTAssertEqual(archived.map(\.channelID), ["C1"])
        XCTAssertEqual(archived.first?.isArchived, true)
    }

    func testAlreadyArchivedNoEvent() {
        let prior = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: true)
        ])
        let curr = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: true)
        ])
        let (renamed, archived) = SlackColdCollector.channelsInfoDiff(prior: prior, current: curr)
        XCTAssertEqual(renamed.count, 0)
        XCTAssertEqual(archived, [])
    }

    func testNoChangeNoEvents() {
        let prior = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: false)
        ])
        let curr = SlackChannelsInfoSnapshot(channels: [
            SlackChannelInfo(channelID: "C1", name: "general", isArchived: false)
        ])
        let (renamed, archived) = SlackColdCollector.channelsInfoDiff(prior: prior, current: curr)
        XCTAssertEqual(renamed.count, 0)
        XCTAssertEqual(archived, [])
    }
}
